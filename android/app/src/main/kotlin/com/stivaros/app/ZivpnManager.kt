package com.stivaros.app

import android.content.Context
import android.net.ConnectivityManager
import java.io.File
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.Executors

class ZivpnManager(private val context: Context) {

    companion object {
        const val TAG = "ZivpnManager"
        const val BASE_LB_PORT = 7777
        const val BASE_UZ_PORT_START = 7778
        const val PORT_SPACING = 100
        fun getFreePort(): Int = try {
            ServerSocket(0).use { it.localPort }
        } catch (_: Exception) { (10000..60000).random() }
    }

    private val LB_PORT: Int = BASE_LB_PORT
    private val BASE_UZ_PORT: Int = BASE_UZ_PORT_START

    private var socksPort: Int = 0
    @Volatile private var running = false
    private var uzProcesses: MutableList<Process> = mutableListOf()
    private var balancerThread: Thread? = null
    private var balancerServerSocket: java.net.ServerSocket? = null

    fun getSocksPort(): Int = socksPort
    fun isRunning(): Boolean = running

    fun start(
        serverAddress: String,
        serverPort: String,
        password: String,
        obfs: String = "hu``hqb`c"
    ) {
        stop()
        running = true
        socksPort = getFreePort()
        NativeLogger.i(TAG, "start: address=$serverAddress port=$serverPort socksPort=$socksPort")

        val nativeDir = context.applicationInfo.nativeLibraryDir
        val uzBin = File(nativeDir, "libuz_core.so")
        if (!uzBin.exists()) {
            NativeLogger.e(TAG, "libuz_core.so not found in $nativeDir")
            throw IllegalStateException("libuz_core.so introuvable")
        }

        val portRanges = serverPort.trim()
            .ifEmpty { "6000-19999" }
            .split(",").map { it.trim() }.filter { it.isNotEmpty() }

        uzProcesses.forEach { try { it.destroyForcibly() } catch (_: Exception) {} }
        uzProcesses.clear()

        val resolvedServerIp = try {
            java.net.InetAddress.getByName(serverAddress).hostAddress ?: serverAddress
        } catch (_: Exception) { serverAddress }

        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager

        portRanges.forEachIndexed { index, portRange ->
            val uzPort = BASE_UZ_PORT + index
            try {
                val uzJsonInline = buildUzConfig(resolvedServerIp, portRange, password, obfs, uzPort)
                val pb = ProcessBuilder(uzBin.absolutePath, "-s", obfs, "--config", uzJsonInline)
                    .directory(context.filesDir)
                    .apply {
                        environment()["LD_LIBRARY_PATH"] = nativeDir
                        environment()["HOME"] = "/data/local/tmp"
                        environment()["TMPDIR"] = "/data/local/tmp"
                        redirectErrorStream(true)
                    }
                val proc = pb.start()
                uzProcesses.add(proc)

                Thread {
                    try {
                        proc.inputStream.bufferedReader().forEachLine { line ->
                            NativeLogger.w(TAG, "uz_core[$index]: $line")
                        }
                    } catch (_: Exception) {}
                    val code = try { proc.exitValue() } catch (_: Exception) { null }
                    if (code != null) NativeLogger.w(TAG, "uz_core[$index] exited code=$code")
                }.apply { isDaemon = true }.start()

                var waited = 0
                while (waited < 3000) {
                    val alive = try { proc.isAlive } catch (_: Exception) { false }
                    if (!alive) break
                    val portUp = try { Socket("127.0.0.1", uzPort).also { it.close() }; true } catch (_: Exception) { false }
                    if (portUp) break
                    Thread.sleep(50); waited += 50
                }
                NativeLogger.i(TAG, "uz_core[$index] started on port $uzPort")
            } catch (e: Exception) {
                NativeLogger.e(TAG, "Failed to start uz_core[$index]: ${e.message}")
            }
        }

        startBalancer()
        val finalPort = LB_PORT
        socksPort = finalPort
        NativeLogger.i(TAG, "Zivpn ready on SOCKS port $finalPort (${uzProcesses.size} tunnels)")
    }

    private fun buildUzConfig(ip: String, portRange: String, password: String, obfs: String, uzPort: Int): String {
        return """{"server":"$ip:$portRange","obfs":"$obfs","auth":"$password","socks5":{"listen":"127.0.0.1:$uzPort"},"insecure":true,"recvwindowconn":65536,"recvwindow":262144,"disable_mtu_discovery":true,"down_mbps":50,"up_mbps":10}"""
    }

    private fun startBalancer() {
        try {
            Thread.sleep(200)
            stopBalancer()
            val upstreamCount = uzProcesses.size
            if (upstreamCount == 0) {
                NativeLogger.w(TAG, "No uz_core upstreams available")
                return
            }
            val upstreams = (0 until upstreamCount).map { i -> Pair("127.0.0.1", BASE_UZ_PORT + i) }
            val counter = AtomicInteger(0)
            val executor = Executors.newCachedThreadPool()
            val ss = ServerSocket(LB_PORT, 128, java.net.InetAddress.getByName("127.0.0.1"))
            ss.reuseAddress = true
            balancerServerSocket = ss
            balancerThread = Thread {
                NativeLogger.i(TAG, "Balancer on port $LB_PORT (${upstreams.size} upstreams)")
                while (!Thread.currentThread().isInterrupted && !ss.isClosed) {
                    try {
                        val client = ss.accept()
                        executor.submit {
                            val idx = counter.getAndIncrement() % upstreams.size
                            val (upHost, upPort) = upstreams[idx]
                            try {
                                val upstream = Socket(upHost, upPort)
                                upstream.tcpNoDelay = true; client.tcpNoDelay = true
                                val t1 = Thread {
                                    try { relay(client.inputStream, upstream.outputStream) } catch (_: Exception) {}
                                    try { upstream.close() } catch (_: Exception) {}
                                }.apply { isDaemon = true }
                                val t2 = Thread {
                                    try { relay(upstream.inputStream, client.outputStream) } catch (_: Exception) {}
                                    try { client.close() } catch (_: Exception) {}
                                }.apply { isDaemon = true }
                                t1.start(); t2.start()
                            } catch (_: Exception) { try { client.close() } catch (_: Exception) {} }
                        }
                    } catch (_: Exception) { break }
                }
                executor.shutdownNow()
            }.apply { isDaemon = true; name = "stivaros-zivpn-lb" }
            balancerThread!!.start()

            var waited = 0; var ok = false
            while (waited < 1000) {
                ok = try { Socket("127.0.0.1", LB_PORT).also { it.close() }; true } catch (_: Exception) { false }
                if (ok) break
                Thread.sleep(30); waited += 30
            }
            if (ok) NativeLogger.i(TAG, "Balancer ready in ${waited}ms")
            else NativeLogger.w(TAG, "Balancer not ready")
        } catch (e: Exception) {
            NativeLogger.e(TAG, "Balancer error: ${e.message}")
        }
    }

    private fun relay(input: java.io.InputStream, output: java.io.OutputStream) {
        val buf = ByteArray(8192); var n: Int
        while (input.read(buf).also { n = it } != -1) { output.write(buf, 0, n); output.flush() }
    }

    private fun stopBalancer() {
        try { balancerServerSocket?.close(); balancerServerSocket = null } catch (_: Exception) {}
        try { balancerThread?.interrupt(); balancerThread = null } catch (_: Exception) {}
    }

    fun stop() {
        NativeLogger.i(TAG, "stop() called")
        running = false
        stopBalancer()
        uzProcesses.forEach { try { it.destroyForcibly() } catch (_: Exception) {} }
        uzProcesses.clear()
        try {
            val killProc = Runtime.getRuntime().exec(arrayOf("sh", "-c",
                "killall -9 libuz_core.so 2>/dev/null; pkill -9 -f libuz_core 2>/dev/null"))
            killProc.waitFor(800, java.util.concurrent.TimeUnit.MILLISECONDS)
        } catch (_: Exception) {}
        socksPort = 0
        NativeLogger.i(TAG, "Zivpn stopped")
    }
}
