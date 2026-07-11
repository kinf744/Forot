package com.stivaros.app

import android.util.Log
import java.io.FileDescriptor
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder

class Tun2SocksRelay(
    private var tunFd: FileDescriptor,
    private val socksHost: String,
    private val socksPort: Int
) {
    companion object {
        const val TAG = "Tun2SocksRelay"
        const val MTU = 1500
        const val TCP = 6
        const val UDP = 17
    }

    private var running = false
    private var thread: Thread? = null

    fun start() {
        running = true
        thread = Thread {
            val inputStream = FileInputStream(tunFd)
            val outputStream = FileOutputStream(tunFd)
            val buffer = ByteArray(MTU)
            val connections = mutableMapOf<Long, Socket>()

            while (running) {
                try {
                    val len = inputStream.read(buffer)
                    if (len <= 0) continue

                    val packet = ByteBuffer.wrap(buffer, 0, len).order(ByteOrder.BIG_ENDIAN)
                    val version = packet.get().toInt() and 0xFF
                    if (version != 0x45 && version != 0x65) continue

                    val protocol = packet.get(packet.position() + 8).toInt() and 0xFF
                    if (protocol != TCP) continue

                    val srcIp = ByteBuffer.allocate(4).put(buffer, 12, 4).getInt(0)
                    val dstIp = ByteBuffer.allocate(4).put(buffer, 16, 4).getInt(0)

                    val headerLen = (version and 0x0F) * 4
                    val srcPort = ((buffer[headerLen + 0].toInt() and 0xFF) shl 8) or
                                  (buffer[headerLen + 1].toInt() and 0xFF)
                    val dstPort = ((buffer[headerLen + 2].toInt() and 0xFF) shl 8) or
                                  (buffer[headerLen + 3].toInt() and 0xFF)

                    val seqNum = ByteBuffer.allocate(4).put(buffer, headerLen + 4, 4).getInt(0)
                    val ackNum = ByteBuffer.allocate(4).put(buffer, headerLen + 8, 4).getInt(0)
                    val flags = buffer[headerLen + 13].toInt() and 0xFF
                    val dataOffset = headerLen + ((buffer[headerLen + 12].toInt() and 0xF0) shr 2)
                    val dataLen = len - dataOffset

                    if (dataLen <= 0) continue

                    val connKey = (srcIp.toLong() shl 32) or (dstIp.toLong() and 0xFFFFFFFFL)

                    if ((flags and 0x02) != 0) {
                        // SYN - open new connection
                        try {
                            val socket = Socket()
                            socket.connect(InetSocketAddress(socksHost, socksPort), 5000)
                            connections[connKey] = socket
                            Log.d(TAG, "TCP connection opened to $socksHost:$socksPort")
                        } catch (e: Exception) {
                            Log.e(TAG, "Failed to connect SOCKS: ${e.message}")
                        }
                    }

                    val socket = connections[connKey]
                    if (socket != null && socket.isConnected && dataLen > 0) {
                        try {
                            val data = ByteArray(dataLen)
                            System.arraycopy(buffer, dataOffset, data, 0, dataLen)
                            socket.getOutputStream().write(data)
                            socket.getOutputStream().flush()
                        } catch (e: Exception) {
                            Log.e(TAG, "Write error: ${e.message}")
                            try { socket.close() } catch (_: Exception) {}
                            connections.remove(connKey)
                        }
                    }

                    if ((flags and 0x01) != 0 || (flags and 0x04) != 0) {
                        // FIN or RST - close connection
                        try { socket?.close() } catch (_: Exception) {}
                        connections.remove(connKey)
                    }

                } catch (e: Exception) {
                    if (running) Log.e(TAG, "Read error: ${e.message}")
                }
            }

            connections.values.forEach { try { it.close() } catch (_: Exception) {} }
        }.also { it.isDaemon = true }
        thread?.start()
    }

    fun stop() {
        running = false
        thread?.interrupt()
    }
}
