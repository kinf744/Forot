package com.stivaros.app

import android.os.ParcelFileDescriptor
import android.util.Log
import kotlinx.coroutines.*
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ConcurrentLinkedQueue
import kotlin.random.Random

class Tun2SocksRelay(
    private val parcelFd: ParcelFileDescriptor,
    private val socksHost: String = "127.0.0.1",
    private val socksPort: Int = 10808
) {
    companion object {
        const val TAG = "Tun2SocksRelay"
        const val TCP_FIN = 0x01
        const val TCP_SYN = 0x02
        const val TCP_RST = 0x04
        const val TCP_PSH = 0x08
        const val TCP_ACK = 0x10
    }

    private val tunFd = parcelFd.fileDescriptor
    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val sessions = ConcurrentHashMap<String, Session>()
    private val tunOut = FileOutputStream(tunFd)

    fun start() {
        NativeLogger.i(TAG, "start() launched readLoop coroutine")
        scope.launch { readLoop() }
        Log.i(TAG, "Relay started -> SOCKS5 $socksHost:$socksPort")
    }

    fun stop() {
        scope.cancel()
        sessions.values.forEach { it.close() }
        sessions.clear()
    }

    private suspend fun readLoop() = withContext(Dispatchers.IO) {
        val inp = FileInputStream(tunFd)
        val buf = ByteArray(131072)
        NativeLogger.i(TAG, "readLoop: started reading from TUN fd")
        var packetCount = 0
        while (isActive) {
            try {
                val len = inp.read(buf)
                if (len < 0) break
                if (len < 20) continue
                packetCount++
                if (packetCount <= 5 || packetCount % 100 == 0)
                    NativeLogger.i(TAG, "readLoop: packet #$packetCount len=$len")
                handlePacket(buf.copyOf(len))
            } catch (_: java.io.InterruptedIOException) { break }
            catch (e: Exception) { if (isActive) Log.e(TAG, "readLoop: ${e.message}"); break }
        }
        NativeLogger.i(TAG, "readLoop: terminated after $packetCount packets")
    }

    private suspend fun handlePacket(pkt: ByteArray) {
        val ver = (pkt[0].toInt() and 0xFF) shr 4
        if (ver != 4) return
        val ihl = (pkt[0].toInt() and 0x0F) * 4
        val proto = pkt[9].toInt() and 0xFF
        when (proto) {
            6 -> handleTcp(pkt, ihl)
            17 -> handleUdp(pkt, ihl)
        }
    }

    private suspend fun handleTcp(pkt: ByteArray, ihl: Int) {
        if (pkt.size < ihl + 20) return
        val srcPort = port(pkt, ihl)
        val dstPort = port(pkt, ihl + 2)
        val flags = pkt[ihl + 13].toInt() and 0xFF
        val syn = flags and TCP_SYN != 0
        val fin = flags and TCP_FIN != 0
        val rst = flags and TCP_RST != 0
        val dataOff = ihl + ((pkt[ihl + 12].toInt() and 0xF0) shr 4) * 4
        val srcIp = ipStr(pkt, 12)
        val dstIp = ipStr(pkt, 16)
        val key = "$srcIp:$srcPort-$dstIp:$dstPort"
        val seq = get32(pkt, ihl + 4)

        if (rst) {
            sessions.remove(key)?.close()
            return
        }

        if (syn && !sessions.containsKey(key)) {
            val appSeq = seq
            val serverSeq = Random.nextInt()
            NativeLogger.i(TAG, "handleTcp: NEW TCP $srcIp:$srcPort -> $dstIp:$dstPort appSeq=$appSeq serverSeq=$serverSeq")
            val session = Session(key, srcIp, srcPort, dstIp, dstPort, appSeq, serverSeq)
            sessions[key] = session

            sendTcpPacket(dstIp, srcIp, dstPort, srcPort, serverSeq, appSeq + 1, TCP_SYN or TCP_ACK, ByteArray(0))
            NativeLogger.i(TAG, "handleTcp: SYN-ACK sent for $key")

            scope.launch {
                val sock = socks5Connect(dstIp, dstPort)
                if (sock == null) {
                    NativeLogger.e(TAG, "handleTcp: SOCKS connect FAILED for $key, sending RST")
                    sendTcpPacket(dstIp, srcIp, dstPort, srcPort, serverSeq, appSeq + 1, TCP_RST or TCP_ACK, ByteArray(0))
                    sessions.remove(key)
                } else {
                    session.onSocksConnected(sock)
                }
            }
            return
        }

        val session = sessions[key] ?: return

        if (fin) {
            session.sendFin()
            sessions.remove(key)?.close()
            return
        }

        if (dataOff < pkt.size) {
            val payload = pkt.copyOfRange(dataOff, pkt.size)
            if (payload.isNotEmpty()) {
                session.onAppData(seq, payload)
            }
        } else {
            session.onAppAck(seq)
        }
    }

    private suspend fun handleUdp(pkt: ByteArray, ihl: Int) {
        if (pkt.size < ihl + 8) return
        val srcPort = port(pkt, ihl)
        val dstPort = port(pkt, ihl + 2)
        if (dstPort != 53) return
        val dataOff = ihl + 8
        if (dataOff >= pkt.size) return
        val payload = pkt.copyOfRange(dataOff, pkt.size)
        val srcIp = ipStr(pkt, 12)
        val dstIp = ipStr(pkt, 16)

        scope.launch(Dispatchers.IO) {
            try {
                val sock = socks5Connect(dstIp, dstPort) ?: return@launch
                val out = sock.getOutputStream()
                val inp = sock.getInputStream()
                out.write(byteArrayOf((payload.size shr 8).toByte(), (payload.size and 0xFF).toByte()))
                out.write(payload)
                out.flush()
                val lenBuf = ByteArray(2)
                var r = 0
                while (r < 2) { val n = inp.read(lenBuf, r, 2 - r); if (n < 0) throw Exception("DNS len EOF"); r += n }
                val len = ((lenBuf[0].toInt() and 0xFF) shl 8) or (lenBuf[1].toInt() and 0xFF)
                if (len > 4096) { sock.close(); return@launch }
                val resp = ByteArray(len)
                r = 0
                while (r < len) { val n = inp.read(resp, r, len - r); if (n < 0) throw Exception("DNS data EOF"); r += n }
                sock.close()
                writeUdpPacket(dstIp, srcIp, dstPort, srcPort, resp)
                NativeLogger.i(TAG, "DNS response ${resp.size} bytes -> TUN")
            } catch (e: Exception) {
                Log.e(TAG, "DNS: ${e.message}")
            }
        }
    }

    private fun writeUdpPacket(srcIp: String, dstIp: String, srcPort: Int, dstPort: Int, data: ByteArray) {
        try {
            val total = 20 + 8 + data.size
            val ipHdr = ipHeader(srcIp, dstIp, total, 17)
            val udpHdr = ByteArray(8)
            udpHdr[0] = (srcPort shr 8).toByte(); udpHdr[1] = (srcPort and 0xFF).toByte()
            udpHdr[2] = (dstPort shr 8).toByte(); udpHdr[3] = (dstPort and 0xFF).toByte()
            val len = 8 + data.size
            udpHdr[4] = (len shr 8).toByte(); udpHdr[5] = (len and 0xFF).toByte()
            udpHdr[6] = 0; udpHdr[7] = 0
            synchronized(tunOut) { tunOut.write(ipHdr + udpHdr + data) }
        } catch (e: Exception) {
            Log.e(TAG, "writeUdpPacket: ${e.message}")
        }
    }

    private fun ipHeader(srcIp: String, dstIp: String, totalLen: Int, proto: Int): ByteArray {
        val hdr = ByteArray(20)
        hdr[0] = 0x45.toByte()
        hdr[2] = (totalLen shr 8).toByte(); hdr[3] = (totalLen and 0xFF).toByte()
        hdr[8] = 64
        hdr[9] = proto.toByte()
        val srcParts = srcIp.split(".").map { it.toInt() }
        val dstParts = dstIp.split(".").map { it.toInt() }
        for (i in 0..3) { hdr[12 + i] = srcParts[i].toByte(); hdr[16 + i] = dstParts[i].toByte() }
        val csum = ipChecksum(hdr)
        hdr[10] = (csum shr 8).toByte(); hdr[11] = (csum and 0xFF).toByte()
        return hdr
    }

    private fun sendTcpPacket(
        srcIp: String, dstIp: String, srcPort: Int, dstPort: Int,
        seq: Int, ack: Int, flags: Int, data: ByteArray
    ) {
        try {
            val tcpOff = 20
            val total = 20 + tcpOff + data.size
            val ipHdr = ipHeader(srcIp, dstIp, total, 6)

            val tcpHdr = ByteArray(tcpOff)
            tcpHdr[0] = (srcPort shr 8).toByte(); tcpHdr[1] = (srcPort and 0xFF).toByte()
            tcpHdr[2] = (dstPort shr 8).toByte(); tcpHdr[3] = (dstPort and 0xFF).toByte()
            put32(tcpHdr, 4, seq)
            put32(tcpHdr, 8, ack)
            tcpHdr[12] = (5 shl 4).toByte()
            tcpHdr[13] = flags.toByte()
            tcpHdr[14] = (65535 shr 8).toByte(); tcpHdr[15] = (65535 and 0xFF).toByte()

            val csum = tcpChecksum(srcIp, dstIp, tcpHdr, data)
            tcpHdr[16] = (csum shr 8).toByte(); tcpHdr[17] = (csum and 0xFF).toByte()

            synchronized(tunOut) { tunOut.write(ipHdr + tcpHdr + data) }
        } catch (e: Exception) {
            Log.e(TAG, "sendTcpPacket: ${e.message}")
        }
    }

    private fun tcpChecksum(srcIp: String, dstIp: String, tcpHdr: ByteArray, data: ByteArray): Int {
        val src = srcIp.split(".").map { it.toByte() }
        val dst = dstIp.split(".").map { it.toByte() }
        val tcpLen = tcpHdr.size + data.size
        val totalLen = 12 + ((tcpLen + 1) / 2) * 2
        val buf = ByteArray(totalLen)
        var off = 0
        for (b in src) buf[off++] = b
        for (b in dst) buf[off++] = b
        buf[off++] = 0; buf[off++] = 6
        buf[off++] = (tcpLen shr 8).toByte(); buf[off++] = (tcpLen and 0xFF).toByte()
        for (b in tcpHdr) buf[off++] = b
        for (b in data) buf[off++] = b
        if ((tcpLen and 1) != 0) buf[off] = 0

        var sum = 0
        for (i in 0 until totalLen - 1 step 2)
            sum += ((buf[i].toInt() and 0xFF) shl 8) or (buf[i + 1].toInt() and 0xFF)
        while (sum shr 16 != 0) sum = (sum and 0xFFFF) + (sum shr 16)
        return sum.inv() and 0xFFFF
    }

    private fun ipChecksum(buf: ByteArray): Int {
        var sum = 0
        for (i in 0 until buf.size - 1 step 2)
            sum += ((buf[i].toInt() and 0xFF) shl 8) or (buf[i + 1].toInt() and 0xFF)
        while (sum shr 16 != 0) sum = (sum and 0xFFFF) + (sum shr 16)
        return sum.inv() and 0xFFFF
    }

    private fun socks5Connect(host: String, port: Int): Socket? {
        NativeLogger.i(TAG, "socks5Connect: $socksHost:$socksPort -> $host:$port")
        return try {
            val sock = Socket()
            sock.soTimeout = 30000
            sock.connect(InetSocketAddress(socksHost, socksPort), 5000)
            val out = sock.getOutputStream()
            val inp = sock.getInputStream()
            out.write(byteArrayOf(0x05, 0x01, 0x00)); out.flush()
            val gresp = ByteArray(2)
            var r = 0; while (r < 2) { val n = inp.read(gresp, r, 2 - r); if (n < 0) throw Exception("SOCKS greeting EOF"); r += n }
            val hb = host.toByteArray()
            out.write(byteArrayOf(0x05, 0x01, 0x00, 0x03, hb.size.toByte()) + hb + byteArrayOf((port shr 8).toByte(), (port and 0xFF).toByte()))
            out.flush()
            val resp = ByteArray(256); var total = 0
            while (total < 4) total += inp.read(resp, total, 4 - total)
            val atyp = resp[3].toInt() and 0xFF
            if (atyp == 1) while (total < 10) total += inp.read(resp, total, 10 - total)
            else if (atyp == 3) { while (total < 5) total += inp.read(resp, total, 5 - total); val dl = resp[4].toInt() and 0xFF; while (total < 5 + dl + 2) total += inp.read(resp, total, 5 + dl + 2 - total) }
            else if (atyp == 4) while (total < 22) total += inp.read(resp, total, 22 - total)
            if (resp[1] != 0x00.toByte()) { sock.close(); return null }
            sock
        } catch (e: Exception) {
            NativeLogger.e(TAG, "socks5Connect: $host:$port -> ${e.message}")
            null
        }
    }

    private fun ipStr(pkt: ByteArray, off: Int) =
        "${pkt[off].toInt() and 0xFF}.${pkt[off + 1].toInt() and 0xFF}.${pkt[off + 2].toInt() and 0xFF}.${pkt[off + 3].toInt() and 0xFF}"

    private fun port(pkt: ByteArray, off: Int) =
        ((pkt[off].toInt() and 0xFF) shl 8) or (pkt[off + 1].toInt() and 0xFF)

    private fun get32(pkt: ByteArray, off: Int) =
        ((pkt[off].toInt() and 0xFF) shl 24) or ((pkt[off + 1].toInt() and 0xFF) shl 16) or
        ((pkt[off + 2].toInt() and 0xFF) shl 8) or (pkt[off + 3].toInt() and 0xFF)

    private fun put32(buf: ByteArray, off: Int, v: Int) {
        buf[off] = (v shr 24).toByte(); buf[off + 1] = (v shr 16).toByte()
        buf[off + 2] = (v shr 8).toByte(); buf[off + 3] = (v and 0xFF).toByte()
    }

    inner class Session(
        val key: String,
        val srcIp: String, val srcPort: Int,
        val dstIp: String, val dstPort: Int,
        val appSeq: Int,
        val serverSeq: Int
    ) {
        private var socket: Socket? = null
        private var appAckedBytes = 0
        private var serverTotalRead = 0L
        private var socksReady = false
        private val pendingData = ConcurrentLinkedQueue<ByteArray>()
        @Volatile private var closed = false

        fun onSocksConnected(sock: Socket) {
            if (closed) { try { sock.close() } catch (_: Exception) {}; return }
            socket = sock
            socksReady = true
            NativeLogger.i(TAG, "Session.onSocksConnected: $dstIp:$dstPort (pending=${pendingData.size})")
            while (true) {
                val d = pendingData.poll() ?: break
                writeRaw(d)
            }
            scope.launch { readThread() }
        }

        fun onAppData(pktSeq: Int, data: ByteArray) {
            if (closed) return
            val relEnd = (pktSeq - appSeq) + data.size
            if (relEnd > appAckedBytes) appAckedBytes = relEnd
            if (socksReady) {
                writeRaw(data)
            } else {
                pendingData.add(data)
            }
            sendTcpPacket(dstIp, srcIp, dstPort, srcPort, serverSeq, pktSeq + data.size, TCP_ACK, ByteArray(0))
        }

        fun onAppAck(pktSeq: Int) {}

        fun sendFin() {
            if (closed) return
            sendTcpPacket(dstIp, srcIp, dstPort, srcPort, serverSeq, 0, TCP_FIN or TCP_ACK, ByteArray(0))
        }

        private suspend fun readThread() = withContext(Dispatchers.IO) {
            val sock = socket ?: return@withContext
            NativeLogger.i(TAG, "Session.readThread: begin $dstIp:$dstPort")
            val buf = ByteArray(65536)
            try {
                while (true) {
                    val n = sock.getInputStream().read(buf)
                    if (n <= 0) break
                    serverTotalRead += n
                    val seq = serverSeq + 1 + (serverTotalRead - n).toInt()
                    val ack = appSeq + appAckedBytes
                    sendTcpPacket(dstIp, srcIp, dstPort, srcPort, seq, ack, TCP_PSH or TCP_ACK, buf.copyOf(n))
                }
                NativeLogger.i(TAG, "DONE $key $serverTotalRead b reason=EOF")
            } catch (e: java.net.SocketTimeoutException) {
                NativeLogger.i(TAG, "DONE $key $serverTotalRead b reason=timeout")
            } catch (e: Exception) {
                NativeLogger.i(TAG, "DONE $key $serverTotalRead b reason=${e.message}")
            }
            finally {
                NativeLogger.i(TAG, "Session.readThread: end $dstIp:$dstPort totalRead=$serverTotalRead")
                if (!closed) {
                    val seq = serverSeq + 1 + serverTotalRead.toInt()
                    sendTcpPacket(dstIp, srcIp, dstPort, srcPort, seq, appSeq + appAckedBytes, TCP_FIN or TCP_ACK, ByteArray(0))
                }
                sessions.remove(key)
                close()
            }
        }

        private fun writeRaw(data: ByteArray) {
            try {
                socket?.getOutputStream()?.write(data)
                socket?.getOutputStream()?.flush()
            } catch (e: Exception) {
                NativeLogger.e(TAG, "Session.writeRaw: $dstIp:$dstPort -> ${e.message}")
                close()
            }
        }

        fun close() {
            closed = true
            try { socket?.close() } catch (_: Exception) {}
        }
    }
}
