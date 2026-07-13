package com.stivaros.app

import kotlinx.coroutines.*
import java.io.FileDescriptor
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import kotlin.random.Random

class Tun2SocksRelay(
    private val tunFd: FileDescriptor,
    private val socksHost: String = "127.0.0.1",
    private val socksPort: Int = 10808
) {
    companion object { const val TAG = "Tun2SocksRelay" }

    private val scope = CoroutineScope(Dispatchers.IO + SupervisorJob())
    private val sessions = ConcurrentHashMap<String, Session>()
    private val tunOut = FileOutputStream(tunFd)
    private var isnCounter = Random.nextInt(100000, 999999999)

    fun start() {
        NativeLogger.i(TAG, "start() launched readLoop coroutine")
        scope.launch { readLoop() }
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
                if (len < 0) {
                    NativeLogger.w(TAG, "readLoop: TUN fd EOF")
                    break
                }
                if (len < 20) continue
                packetCount++
                if (packetCount <= 5 || packetCount % 100 == 0)
                    NativeLogger.i(TAG, "readLoop: packet #$packetCount len=$len")
                handlePacket(buf.copyOf(len))
            } catch (e: java.io.InterruptedIOException) {
                if (!isActive) break
            } catch (e: java.io.IOException) {
                if (e.message?.contains("EBADF") == true || e.message?.contains("Bad file descriptor") == true) break
            } catch (e: Exception) {
                if (isActive) NativeLogger.e(TAG, "readLoop: packet #$packetCount error: ${e.message}")
            }
        }
        NativeLogger.i(TAG, "readLoop: terminated after $packetCount packets")
    }

    private fun handlePacket(pkt: ByteArray) {
        val ver = (pkt[0].toInt() and 0xFF) shr 4
        if (ver != 4) return
        val ihl = (pkt[0].toInt() and 0x0F) * 4
        if (pkt.size < ihl) return
        val proto = pkt[9].toInt() and 0xFF
        when (proto) {
            6 -> handleTcp(pkt, ihl)
            17 -> handleUdp(pkt, ihl)
        }
    }

    private fun handleTcp(pkt: ByteArray, ihl: Int) {
        if (pkt.size < ihl + 20) return
        val srcPort = port(pkt, ihl)
        val dstPort = port(pkt, ihl + 2)
        val seqNum = bytesToUInt(pkt, ihl + 4)
        val ackNum = bytesToUInt(pkt, ihl + 8)
        val flags = pkt[ihl + 13].toInt() and 0xFF
        val syn = flags and 0x02 != 0
        val fin = flags and 0x01 != 0
        val rst = flags and 0x04 != 0
        val ack = flags and 0x10 != 0
        val dataOff = ihl + ((pkt[ihl + 12].toInt() and 0xF0) shr 4) * 4
        val srcIp = ipStr(pkt, 12)
        val dstIp = ipStr(pkt, 16)
        val key = "$srcIp:$srcPort-$dstIp:$dstPort"

        if (rst) {
            sessions.remove(key)?.close()
            return
        }

        if (syn && !sessions.containsKey(key)) {
            val session = Session(key, srcIp, srcPort, dstIp, dstPort, seqNum, nextIsn())
            sessions[key] = session
            scope.launch {
                try {
                    val sock = socks5Connect(dstIp, dstPort)
                    if (sock != null) {
                        session.socket = sock
                        session.state = Session.State.ESTABLISHED
                        sendSynAck(session)
                        session.startReading { data ->
                            sendTcpData(session, data)
                        }
                    } else {
                        sendRst(session)
                        sessions.remove(key)
                    }
                } catch (e: Exception) {
                    NativeLogger.e(TAG, "Session $key error: ${e.message}")
                    sessions.remove(key)
                }
            }
            return
        }

        val session = sessions[key] ?: return

        if (session.state == Session.State.CLOSED) {
            sessions.remove(key)
            return
        }

        if (ack) {
            session.clientAck = ackNum
        }

        if (fin) {
            session.state = Session.State.CLOSING
            session.socket?.let { sock ->
                try { sock.shutdownOutput() } catch (_: Exception) {}
            }
            sendFinAck(session)
            return
        }

        if (dataOff < pkt.size) {
            val data = pkt.copyOfRange(dataOff, pkt.size)
            if (data.isNotEmpty()) {
                session.clientSeq = (session.clientSeq + data.size) and 0xFFFFFFFFL
                session.socket?.let { sock ->
                    try {
                        sock.getOutputStream().write(data)
                        sock.getOutputStream().flush()
                    } catch (e: Exception) {
                        NativeLogger.e(TAG, "Write error $key: ${e.message}")
                        sessions.remove(key)
                        session.close()
                    }
                }
                sendAck(session)
            }
        }
    }

    private fun nextIsn(): Long {
        isnCounter = (isnCounter + Random.nextInt(1000, 9999)).toInt()
        return (isnCounter.toLong() and 0xFFFFFFFFL)
    }

    private fun sendSynAck(session: Session) {
        val pkt = buildTcpPacket(
            session.dstIp, session.srcIp,
            session.dstPort, session.srcPort,
            session.serverSeq, (session.clientSeq + 1) and 0xFFFFFFFFL,
            0x12.toByte(), byteArrayOf()
        )
        writeToTun(pkt)
        session.serverSeq = (session.serverSeq + 1) and 0xFFFFFFFFL
        session.serverAck = (session.clientSeq + 1) and 0xFFFFFFFFL
        NativeLogger.i(TAG, "SYN-ACK sent to ${session.srcIp}:${session.srcPort}")
    }

    private fun sendAck(session: Session) {
        val pkt = buildTcpPacket(
            session.dstIp, session.srcIp,
            session.dstPort, session.srcPort,
            session.serverSeq, session.clientSeq,
            0x10.toByte(), byteArrayOf()
        )
        writeToTun(pkt)
        NativeLogger.i(TAG, "ACK sent to ${session.srcIp}:${session.srcPort} ack=${session.clientSeq}")
    }

    private fun sendFinAck(session: Session) {
        session.serverSeq = (session.serverSeq + 1) and 0xFFFFFFFFL
        val finSeq = session.serverSeq
        val pkt = buildTcpPacket(
            session.dstIp, session.srcIp,
            session.dstPort, session.srcPort,
            finSeq, session.clientSeq,
            0x11.toByte(), byteArrayOf()
        )
        writeToTun(pkt)
        session.state = Session.State.LAST_ACK
        NativeLogger.i(TAG, "FIN-ACK sent to ${session.srcIp}:${session.srcPort}")
    }

    private fun sendRst(session: Session) {
        val pkt = buildTcpPacket(
            session.dstIp, session.srcIp,
            session.dstPort, session.srcPort,
            0, 0,
            0x04.toByte(), byteArrayOf()
        )
        writeToTun(pkt)
        NativeLogger.w(TAG, "RST sent to ${session.srcIp}:${session.srcPort}")
    }

    fun sendTcpData(session: Session, data: ByteArray) {
        if (session.state == Session.State.CLOSED || session.state == Session.State.CLOSING) return
        session.serverSeq = (session.serverSeq + data.size) and 0xFFFFFFFFL
        val pkt = buildTcpPacket(
            session.dstIp, session.srcIp,
            session.dstPort, session.srcPort,
            session.serverSeq, session.clientSeq,
            0x18.toByte(), data
        )
        writeToTun(pkt)
        NativeLogger.i(TAG, "Data sent to ${session.srcIp}:${session.srcPort} ${data.size}b seq=${session.serverSeq}")
    }

    private fun buildTcpPacket(
        srcIp: String, dstIp: String,
        srcPort: Int, dstPort: Int,
        seqNum: Long, ackNum: Long,
        flags: Byte, data: ByteArray
    ): ByteArray {
        val tcpLen = 20
        val totalLen = 20 + tcpLen + data.size

        val ip = ByteArray(20)
        ip[0] = 0x45.toByte()
        ip[1] = 0
        ip[2] = (totalLen shr 8).toByte()
        ip[3] = (totalLen and 0xFF).toByte()
        ip[4] = 0; ip[5] = 0
        ip[6] = 0; ip[7] = 0
        ip[8] = 64
        ip[9] = 6
        ip[10] = 0; ip[11] = 0
        val sip = srcIp.split(".").map { it.toInt() and 0xFF }
        val dip = dstIp.split(".").map { it.toInt() and 0xFF }
        for (i in 0..3) {
            ip[12 + i] = sip[i].toByte()
            ip[16 + i] = dip[i].toByte()
        }
        val ipCsum = checksum(ip)
        ip[10] = (ipCsum shr 8).toByte()
        ip[11] = (ipCsum and 0xFF).toByte()

        val tcp = ByteArray(tcpLen)
        tcp[0] = (srcPort shr 8).toByte()
        tcp[1] = (srcPort and 0xFF).toByte()
        tcp[2] = (dstPort shr 8).toByte()
        tcp[3] = (dstPort and 0xFF).toByte()
        tcp[4] = ((seqNum shr 24) and 0xFF).toByte()
        tcp[5] = ((seqNum shr 16) and 0xFF).toByte()
        tcp[6] = ((seqNum shr 8) and 0xFF).toByte()
        tcp[7] = (seqNum and 0xFF).toByte()
        tcp[8] = ((ackNum shr 24) and 0xFF).toByte()
        tcp[9] = ((ackNum shr 16) and 0xFF).toByte()
        tcp[10] = ((ackNum shr 8) and 0xFF).toByte()
        tcp[11] = (ackNum and 0xFF).toByte()
        tcp[12] = 0x50.toByte()
        tcp[13] = flags
        tcp[14] = (0xFFFF shr 8).toByte()
        tcp[15] = (0xFFFF and 0xFF).toByte()
        tcp[16] = 0; tcp[17] = 0
        tcp[18] = 0; tcp[19] = 0

        val tcpCsum = tcpChecksum(sip, dip, 6, tcpLen + data.size, tcp, data)
        tcp[16] = ((tcpCsum shr 8) and 0xFF).toByte()
        tcp[17] = (tcpCsum and 0xFF).toByte()

        return ip + tcp + data
    }

    private fun tcpChecksum(srcIp: List<Int>, dstIp: List<Int>, protocol: Int, tcpLen: Int, tcp: ByteArray, data: ByteArray): Int {
        var sum = 0
        sum += (srcIp[0] shl 8) + srcIp[1]
        sum += (srcIp[2] shl 8) + srcIp[3]
        sum += (dstIp[0] shl 8) + dstIp[1]
        sum += (dstIp[2] shl 8) + dstIp[3]
        sum += protocol
        sum += tcpLen
        for (i in tcp.indices step 2) {
            val b1 = tcp[i].toInt() and 0xFF
            val b2 = if (i + 1 < tcp.size) (tcp[i + 1].toInt() and 0xFF) else 0
            sum += (b1 shl 8) + b2
        }
        for (i in data.indices step 2) {
            val b1 = data[i].toInt() and 0xFF
            val b2 = if (i + 1 < data.size) (data[i + 1].toInt() and 0xFF) else 0
            sum += (b1 shl 8) + b2
        }
        while (sum shr 16 != 0) sum = (sum and 0xFFFF) + (sum shr 16)
        return sum.inv() and 0xFFFF
    }

    private fun writeToTun(pkt: ByteArray) {
        try {
            synchronized(tunOut) { tunOut.write(pkt); tunOut.flush() }
        } catch (e: Exception) {
            NativeLogger.e(TAG, "writeToTun: ${e.message}")
        }
    }

    private fun handleUdp(pkt: ByteArray, ihl: Int) {
        if (pkt.size < ihl + 8) return
        val dstPort = port(pkt, ihl + 2)
        if (dstPort != 53) return
        val srcPort = port(pkt, ihl)
        val dataOff = ihl + 8
        if (dataOff >= pkt.size) return
        val data = pkt.copyOfRange(dataOff, pkt.size)
        val srcIp = ipStr(pkt, 12)
        val dstIp = ipStr(pkt, 16)

        scope.launch(Dispatchers.IO) {
            try {
                val sock = socks5Connect(dstIp, dstPort) ?: return@launch
                val out = sock.getOutputStream()
                out.write(byteArrayOf((data.size shr 8).toByte(), (data.size and 0xFF).toByte()))
                out.write(data)
                out.flush()
                val lenBuf = ByteArray(2)
                val inp = sock.getInputStream()
                var r = 0; while (r < 2) r += inp.read(lenBuf, r, 2 - r)
                val len = ((lenBuf[0].toInt() and 0xFF) shl 8) or (lenBuf[1].toInt() and 0xFF)
                val resp = ByteArray(len)
                r = 0; while (r < len) r += inp.read(resp, r, len - r)
                sock.close()
                writeUdpResponse(srcIp, dstIp, srcPort, dstPort, resp)
            } catch (e: Exception) {
                NativeLogger.e(TAG, "DNS error: ${e.message}")
            }
        }
    }

    private fun writeUdpResponse(clientIp: String, serverIp: String, clientPort: Int, serverPort: Int, data: ByteArray) {
        try {
            val total = 20 + 8 + data.size
            val ip = ByteArray(20)
            ip[0] = 0x45.toByte()
            ip[1] = 0
            ip[2] = (total shr 8).toByte()
            ip[3] = (total and 0xFF).toByte()
            ip[8] = 64
            ip[9] = 17
            val srcParts = serverIp.split(".").map { it.toInt() }
            val dstParts = clientIp.split(".").map { it.toInt() }
            for (i in 0..3) {
                ip[12 + i] = srcParts[i].toByte()
                ip[16 + i] = dstParts[i].toByte()
            }
            ip[10] = 0; ip[11] = 0
            val ipCsum = checksum(ip)
            ip[10] = (ipCsum shr 8).toByte()
            ip[11] = (ipCsum and 0xFF).toByte()

            val udpLen = 8 + data.size
            val udp = ByteArray(8)
            udp[0] = (serverPort shr 8).toByte()
            udp[1] = (serverPort and 0xFF).toByte()
            udp[2] = (clientPort shr 8).toByte()
            udp[3] = (clientPort and 0xFF).toByte()
            udp[4] = (udpLen shr 8).toByte()
            udp[5] = (udpLen and 0xFF).toByte()
            udp[6] = 0; udp[7] = 0

            synchronized(tunOut) { tunOut.write(ip + udp + data) }
        } catch (e: Exception) {
            NativeLogger.e(TAG, "writeUdpResponse: ${e.message}")
        }
    }

    private fun socks5Connect(host: String, port: Int): Socket? {
        return try {
            val sock = Socket()
            sock.soTimeout = 30000
            sock.connect(InetSocketAddress(socksHost, socksPort), 5000)
            val out = sock.getOutputStream()
            val inp = sock.getInputStream()
            out.write(byteArrayOf(0x05, 0x01, 0x00)); out.flush()
            val greetingResp = ByteArray(2)
            var gr = 0; while (gr < 2) gr += inp.read(greetingResp, gr, 2 - gr)
            val hostBytes = host.toByteArray()
            out.write(byteArrayOf(0x05, 0x01, 0x00, 0x03, hostBytes.size.toByte()) +
                hostBytes + byteArrayOf((port shr 8).toByte(), (port and 0xFF).toByte()))
            out.flush()
            val resp = ByteArray(4); var total = 0
            while (total < 4) total += inp.read(resp, total, 4 - total)
            if (resp[1] != 0x00.toByte()) {
                NativeLogger.e(TAG, "SOCKS rejected $host:$port rep=${resp[1]}")
                sock.close(); return null
            }
            val atyp = resp[3].toInt() and 0xFF
            val extraLen = when (atyp) {
                1 -> 4 + 2
                3 -> { val dlen = inp.read(); if (dlen < 0) throw Exception("SOCKS addr len EOF"); dlen + 2 }
                4 -> 16 + 2
                else -> throw Exception("SOCKS unknown atyp=$atyp")
            }
            var skipped = 0; while (skipped < extraLen) skipped += inp.read(ByteArray(extraLen - skipped))
            sock
        } catch (e: Exception) {
            NativeLogger.e(TAG, "SOCKS FAIL $host:$port ${e.message}")
            null
        }
    }

    private fun ipStr(pkt: ByteArray, off: Int) =
        "${pkt[off].toInt() and 0xFF}.${pkt[off+1].toInt() and 0xFF}.${pkt[off+2].toInt() and 0xFF}.${pkt[off+3].toInt() and 0xFF}"

    private fun port(pkt: ByteArray, off: Int) =
        ((pkt[off].toInt() and 0xFF) shl 8) or (pkt[off+1].toInt() and 0xFF)

    private fun bytesToUInt(pkt: ByteArray, off: Int): Long =
        (((pkt[off].toInt() and 0xFF).toLong() shl 24) or
         ((pkt[off+1].toInt() and 0xFF).toLong() shl 16) or
         ((pkt[off+2].toInt() and 0xFF).toLong() shl 8) or
         (pkt[off+3].toInt() and 0xFF).toLong()) and 0xFFFFFFFFL

    private fun checksum(buf: ByteArray): Int {
        var sum = 0
        for (i in buf.indices step 2) {
            val b1 = buf[i].toInt() and 0xFF
            val b2 = if (i + 1 < buf.size) (buf[i + 1].toInt() and 0xFF) else 0
            sum += (b1 shl 8) + b2
        }
        while (sum shr 16 != 0) sum = (sum and 0xFFFF) + (sum shr 16)
        return sum.inv() and 0xFFFF
    }

    inner class Session(
        val key: String,
        val srcIp: String, val srcPort: Int,
        val dstIp: String, val dstPort: Int,
        seqNum: Long,
        var serverSeq: Long
    ) {
        enum class State { ESTABLISHED, CLOSING, LAST_ACK, CLOSED }
        var state: State = State.ESTABLISHED
        var rcvNxt: Long = (seqNum + 1) and 0xFFFFFFFFL
        var socket: Socket? = null

        suspend fun startReading(onData: suspend (ByteArray) -> Unit) = withContext(Dispatchers.IO) {
            val sock = socket ?: return@withContext
            val buf = ByteArray(65536)
            var totalRead = 0L
            var reason = "EOF"
            try {
                while (true) {
                    val n = sock.getInputStream().read(buf)
                    if (n <= 0) break
                    totalRead += n
                    onData(buf.copyOf(n))
                }
            } catch (e: java.net.SocketTimeoutException) { reason = "timeout"
            } catch (e: Exception) { reason = e.message ?: "err" }
            finally {
                NativeLogger.i(TAG, "DONE $dstIp:$dstPort ${totalRead}b reason=$reason")
                if (state == State.CLOSING) {
                    sendFinAck(this@Session)
                }
                state = State.CLOSED
                sessions.remove(key)
                close()
            }
        }

        fun close() {
            state = State.CLOSED
            try { socket?.close() } catch (_: Exception) {}
            socket = null
        }
    }
}
