package com.stivaros.app

import android.util.Log
import kotlinx.coroutines.*
import java.io.FileDescriptor
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap

class Tun2SocksRelay(
    private val tunFd: FileDescriptor,
    private val socksHost: String = "127.0.0.1",
    private val socksPort: Int = 10808
) {
    companion object { const val TAG = "Tun2SocksRelay" }

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
            catch (e: Exception) {
                if (isActive) {
                    NativeLogger.e(TAG, "readLoop: packet #$packetCount error: ${e.message}")
                }
            }
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
        val syn = flags and 0x02 != 0
        val fin = flags and 0x01 != 0
        val rst = flags and 0x04 != 0
        val dataOff = ihl + ((pkt[ihl + 12].toInt() and 0xF0) shr 4) * 4
        val srcIp = ipStr(pkt, 12)
        val dstIp = ipStr(pkt, 16)
        val key = "$srcIp:$srcPort-$dstIp:$dstPort"

        if (syn && !sessions.containsKey(key)) {
            NativeLogger.i(TAG, "handleTcp: NEW TCP $srcIp:$srcPort -> $dstIp:$dstPort (sessions=${sessions.size})")
            val session = Session(key, srcIp, srcPort, dstIp, dstPort)
            sessions[key] = session
            scope.launch {
                try {
                    session.connect(socksHost, socksPort)
                    session.startReading { data ->
                        writeIpPacket(dstIp, srcIp, dstPort, srcPort, data)
                    }
                } catch (e: Exception) {
                    NativeLogger.e(TAG, "Session coroutine: ${e.message}")
                    sessions.remove(key)
                    session.close()
                }
            }
        }

        if (fin || rst) {
            sessions.remove(key)?.close()
            return
        }

        if (dataOff < pkt.size) {
            val data = pkt.copyOfRange(dataOff, pkt.size)
            if (data.isNotEmpty()) sessions[key]?.write(data)
        }
    }

    private suspend fun handleUdp(pkt: ByteArray, ihl: Int) {
        if (pkt.size < ihl + 8) return
        val dstPort = port(pkt, ihl + 2)
        val dataOff = ihl + 8
        if (dataOff >= pkt.size) return
        val data = pkt.copyOfRange(dataOff, pkt.size)
        if (dstPort != 53) return

        scope.launch(Dispatchers.IO) {
            try {
                val sock = socks5Connect("129.0.183.251", 53) ?: return@launch
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
                Log.i(TAG, "DNS response ${resp.size} bytes")
            } catch (e: Exception) {
                Log.e(TAG, "DNS: ${e.message}")
            }
        }
    }

    private fun writeIpPacket(srcIp: String, dstIp: String, srcPort: Int, dstPort: Int, data: ByteArray) {
        try {
            val ipHeader = ByteArray(20)
            val tcpHeader = ByteArray(20)
            val total = 20 + 20 + data.size

            ipHeader[0] = 0x45.toByte()
            ipHeader[1] = 0
            ipHeader[2] = (total shr 8).toByte()
            ipHeader[3] = (total and 0xFF).toByte()
            ipHeader[8] = 64
            ipHeader[9] = 6
            val srcParts = srcIp.split(".").map { it.toInt() }
            val dstParts = dstIp.split(".").map { it.toInt() }
            for (i in 0..3) {
                ipHeader[12 + i] = srcParts[i].toByte()
                ipHeader[16 + i] = dstParts[i].toByte()
            }
            ipHeader[10] = 0; ipHeader[11] = 0
            val ipCsum = checksum(ipHeader)
            ipHeader[10] = (ipCsum shr 8).toByte()
            ipHeader[11] = (ipCsum and 0xFF).toByte()

            tcpHeader[0] = (srcPort shr 8).toByte()
            tcpHeader[1] = (srcPort and 0xFF).toByte()
            tcpHeader[2] = (dstPort shr 8).toByte()
            tcpHeader[3] = (dstPort and 0xFF).toByte()
            tcpHeader[12] = 0x50.toByte()
            tcpHeader[13] = 0x18.toByte()

            val pkt = ipHeader + tcpHeader + data
            synchronized(tunOut) { tunOut.write(pkt) }
        } catch (e: Exception) {
            Log.e(TAG, "writeIpPacket: ${e.message}")
        }
    }

    private fun socks5Connect(host: String, port: Int): Socket? {
        NativeLogger.i(TAG, "socks5Connect: connecting to $socksHost:$socksPort for $host:$port")
        return try {
            val sock = Socket()
            sock.soTimeout = 10000
            sock.connect(InetSocketAddress(socksHost, socksPort), 5000)
            NativeLogger.i(TAG, "socks5Connect: TCP to $socksHost:$socksPort established")
            val out = sock.getOutputStream()
            val inp = sock.getInputStream()
            out.write(byteArrayOf(0x05, 0x01, 0x00)); out.flush()
            val greetingResp = ByteArray(2)
            inp.read(greetingResp); inp.read(greetingResp)
            NativeLogger.i(TAG, "socks5Connect: greeting resp=${greetingResp[0]},${greetingResp[1]}")
            val hostBytes = host.toByteArray()
            out.write(byteArrayOf(0x05, 0x01, 0x00, 0x03, hostBytes.size.toByte()) +
                hostBytes + byteArrayOf((port shr 8).toByte(), (port and 0xFF).toByte()))
            out.flush()
            val resp = ByteArray(256); var total = 0
            while (total < 4) total += inp.read(resp, total, 4 - total)
            NativeLogger.i(TAG, "socks5Connect: connect resp ver=${resp[0]} rep=${resp[1]} atyp=${resp[3]}")
            if (resp[1] != 0x00.toByte()) {
                NativeLogger.e(TAG, "socks5Connect: SOCKS rejected $host:$port rep=${resp[1]}")
                sock.close(); return null
            }
            NativeLogger.i(TAG, "socks5Connect: SOCKS tunnel OK for $host:$port")
            sock
        } catch (e: Exception) {
            NativeLogger.e(TAG, "socks5Connect: EXCEPTION $host:$port -> ${e.message}")
            null
        }
    }

    private fun ipStr(pkt: ByteArray, off: Int) =
        "${pkt[off].toInt() and 0xFF}.${pkt[off+1].toInt() and 0xFF}.${pkt[off+2].toInt() and 0xFF}.${pkt[off+3].toInt() and 0xFF}"

    private fun port(pkt: ByteArray, off: Int) =
        ((pkt[off].toInt() and 0xFF) shl 8) or (pkt[off+1].toInt() and 0xFF)

    private fun checksum(buf: ByteArray): Int {
        var sum = 0
        for (i in 0 until buf.size - 1 step 2)
            sum += ((buf[i].toInt() and 0xFF) shl 8) or (buf[i+1].toInt() and 0xFF)
        if (buf.size % 2 != 0) sum += (buf.last().toInt() and 0xFF) shl 8
        while (sum shr 16 != 0) sum = (sum and 0xFFFF) + (sum shr 16)
        return sum.inv() and 0xFFFF
    }

    inner class Session(
        val key: String,
        val srcIp: String, val srcPort: Int,
        val dstIp: String, val dstPort: Int
    ) {
        private var socket: Socket? = null

        suspend fun connect(socksHost: String, socksPort: Int) {
            NativeLogger.i(TAG, "Session.connect: $dstIp:$dstPort via SOCKS5")
            socket = socks5Connect(dstIp, dstPort)
            if (socket == null) {
                sessions.remove(key)
                NativeLogger.e(TAG, "Session.connect: FAILED $dstIp:$dstPort")
            } else {
                NativeLogger.i(TAG, "Session.connect: OK $dstIp:$dstPort socket=${socket}")
            }
        }

        suspend fun startReading(onData: suspend (ByteArray) -> Unit) = withContext(Dispatchers.IO) {
            val sock = socket ?: return@withContext
            NativeLogger.i(TAG, "Session.startReading: begin for $dstIp:$dstPort")
            val buf = ByteArray(65536)
            var totalRead = 0L
            try {
                while (true) {
                    val n = sock.getInputStream().read(buf)
                    if (n <= 0) break
                    totalRead += n
                    onData(buf.copyOf(n))
                }
            } catch (_: Exception) { }
            finally {
                NativeLogger.i(TAG, "Session.startReading: end for $dstIp:$dstPort totalRead=$totalRead")
                sessions.remove(key); close()
            }
        }

        fun write(data: ByteArray) {
            NativeLogger.i(TAG, "Session.write: $dstIp:$dstPort ${data.size} bytes")
            try { socket?.getOutputStream()?.write(data); socket?.getOutputStream()?.flush() }
            catch (e: Exception) {
                NativeLogger.e(TAG, "Session.write: EXCEPTION $dstIp:$dstPort -> ${e.message}")
                sessions.remove(key); close()
            }
        }

        fun close() {
            try { socket?.close() } catch (_: Exception) {}
        }
    }
}
