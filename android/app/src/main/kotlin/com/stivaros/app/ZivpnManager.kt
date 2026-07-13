package com.stivaros.app

import android.content.Context
import android.net.ConnectivityManager
import java.io.File
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.TimeUnit

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

    var errorCallback: ((String) -> Unit)? = null

    private val LB_PORT: Int = BASE_LB_PORT
    private val BASE_UZ_PORT: Int = BASE_UZ_PORT_START

    private var socksPort: Int = 0
    @Volatile private var running = false
    private var uzProcesses: MutableList<Process> = mutableListOf()
    private var balancerThread: Thread? = null
    private var balancerServerSocket: java.net.ServerSocket? = null
    private var healthChecker: ScheduledExecutorService? = null

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
        NativeLogger.i(TAG, "start: address=$serverAddress port=$serverPort socksPort=$socksPort obfs=$obfs password=$password")

        val nativeDir = context.applicationInfo.nativeLibraryDir
        NativeLogger.i(TAG, "nativeLibraryDir=$nativeDir")

        val uzBin = File(nativeDir, "libuz_core.so")
        NativeLogger.i(TAG, "uzBin path=${uzBin.absolutePath} exists=${uzBin.exists()} size=${uzBin.length()}")

        if (!uzBin.exists()) {
            NativeLogger.e(TAG, "libuz_core.so not found in $nativeDir")
            errorCallback?.invoke("LIBUZ_NOT_FOUND")
            throw IllegalStateException("libuz_core.so introuvable")
        }

        if (!uzBin.canExecute()) {
            NativeLogger.w(TAG, "libuz_core.so not executable, attempting chmod")
            try { Runtime.getRuntime().exec(arrayOf("chmod", "755", uzBin.absolutePath)).waitFor() } catch (_: Exception) {}
        }

        val portRanges = serverPort.trim()
            .ifEmpty { "6000-19999" }
            .split(",").map { it.trim() }.filter { it.isNotEmpty() }

        NativeLogger.i(TAG, "portRanges=$portRanges count=${portRanges.size}")

        uzProcesses.forEach { try { it.destroyForcibly() } catch (_: Exception) {} }
        uzProcesses.clear()

        val resolvedServerIp = try {
            java.net.InetAddress.getByName(serverAddress).hostAddress ?: serverAddress
        } catch (e: Exception) {
            NativeLogger.e(TAG, "DNS resolution failed for $serverAddress: ${e.message}")
            errorCallback?.invoke("DNS_FAILED:$serverAddress")
            serverAddress
        }
        NativeLogger.i(TAG, "resolvedServerIp=$resolvedServerIp (original=$serverAddress)")

        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val activeNetwork = cm.activeNetwork
        NativeLogger.i(TAG, "activeNetwork=$activeNetwork")

        portRanges.forEachIndexed { index, portRange ->
            val uzPort = BASE_UZ_PORT + index
            NativeLogger.i(TAG, "Starting uz_core[$index]: portRange=$portRange uzPort=$uzPort")
            try {
                val uzJsonInline = buildUzConfig(resolvedServerIp, portRange, password, obfs, uzPort)
                NativeLogger.i(TAG, "uz_core[$index] config: $uzJsonInline")

                val pb = ProcessBuilder(uzBin.absolutePath, "-s", obfs, "--config", uzJsonInline)
                    .directory(context.filesDir)
                    .apply {
                        environment()["LD_LIBRARY_PATH"] = nativeDir
                        environment()["HOME"] = "/data/local/tmp"
                        environment()["TMPDIR"] = "/data/local/tmp"
                        redirectErrorStream(true)
                    }
                NativeLogger.i(TAG, "uz_core[$index] cmd: ${pb.command()}")

                val proc = pb.start()
                uzProcesses.add(proc)
                NativeLogger.i(TAG, "uz_core[$index] started")

                Thread {
                    try {
                        proc.inputStream.bufferedReader().forEachLine { line ->
                            val lower = line.lowercase()
                            if (lower.contains("error") || lower.contains("fail") || lower.contains("exception") || lower.contains("refused")) {
                                NativeLogger.e(TAG, "uz_core[$index] ERROR: $line")
                                errorCallback?.invoke("UZ_CORE_ERROR:$index:$line")
                            } else {
                                NativeLogger.i(TAG, "uz_core[$index]: $line")
                            }
                        }
                    } catch (_: Exception) {}
                    val code = try { proc.exitValue() } catch (_: Exception) { null }
                    if (code != null) {
                        NativeLogger.w(TAG, "uz_core[$index] exited code=$code")
                        if (running && code != 0) {
                            errorCallback?.invoke("UZ_CORE_DIED:$index:exit=$code")
                        }
                    }
                }.apply { isDaemon = true }.start()

                var waited = 0
                var started = false
                while (waited < 5000) {
                    val alive = try { proc.isAlive } catch (_: Exception) { false }
                    if (!alive) {
                        NativeLogger.e(TAG, "uz_core[$index] died during startup after ${waited}ms")
                        break
                    }
                    val portUp = try { Socket("127.0.0.1", uzPort).also { it.close() }; true } catch (_: Exception) { false }
                    if (portUp) {
                        started = true
                        break
                    }
                    Thread.sleep(50); waited += 50
                }

                if (started) {
                    NativeLogger.i(TAG, "uz_core[$index] ready on port $uzPort (${waited}ms)")
                } else {
                    NativeLogger.e(TAG, "uz_core[$index] failed to start within ${waited}ms")
                    errorCallback?.invoke("UZ_CORE_TIMEOUT:$index")
                }
            } catch (e: Exception) {
                NativeLogger.e(TAG, "Failed to start uz_core[$index]: ${e.message}")
                errorCallback?.invoke("UZ_CORE_LAUNCH_FAILED:$index:${e.message}")
            }
        }

        if (uzProcesses.size != portRanges.size) {
            NativeLogger.w(TAG, "Only ${uzProcesses.size}/${portRanges.size} uz_core processes started")
        }

        startBalancer()
        startHealthCheck()
        val finalPort = LB_PORT
        socksPort = finalPort

        if (uzProcesses.isEmpty()) {
            NativeLogger.e(TAG, "No uz_core tunnels available!")
            errorCallback?.invoke("NO_TUNNELS_AVAILABLE")
        } else {
            NativeLogger.i(TAG, "Zivpn ready on SOCKS port $finalPort (${uzProcesses.size}/${portRanges.size} tunnels)")
        }
    }

    private fun buildUzConfig(ip: String, portRange: String, password: String, obfs: String, uzPort: Int): String {
        val json = """{"server":"$ip:$portRange","obfs":"$obfs","auth":"$password","socks5":{"listen":"127.0.0.1:$uzPort"},"insecure":true,"recvwindowconn":65536,"recvwindow":262144,"disable_mtu_discovery":true,"down_mbps":50,"up_mbps":10}"""
        NativeLogger.i(TAG, "Config JSON: server=$ip:$portRange uzPort=$uzPort")
        return json
    }

    private fun startBalancer() {
        try {
            Thread.sleep(200)
            stopBalancer()
            val upstreamCount = uzProcesses.size
            if (upstreamCount == 0) {
                NativeLogger.w(TAG, "No uz_core upstreams available for balancer")
                errorCallback?.invoke("BALANCER_NO_UPSTREAMS")
                return
            }
            val upstreams = (0 until upstreamCount).map { i -> Pair("127.0.0.1", BASE_UZ_PORT + i) }
            NativeLogger.i(TAG, "Balancer upstreams: $upstreams")
            val counter = AtomicInteger(0)
            val executor = Executors.newCachedThreadPool()
            val ss = ServerSocket(LB_PORT, 128, java.net.InetAddress.getByName("127.0.0.1"))
            ss.reuseAddress = true
            balancerServerSocket = ss
            balancerThread = Thread {
                NativeLogger.i(TAG, "Balancer listening on port $LB_PORT (${upstreams.size} upstreams)")
                while (!Thread.currentThread().isInterrupted && !ss.isClosed) {
                    try {
                        val client = ss.accept()
                        NativeLogger.i(TAG, "Balancer accepted connection from ${client.remoteSocketAddress}")
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
                            } catch (e: Exception) {
                                NativeLogger.w(TAG, "Balancer relay error: ${e.message}")
                                try { client.close() } catch (_: Exception) {}
                            }
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
            else {
                NativeLogger.w(TAG, "Balancer not ready after ${waited}ms")
                errorCallback?.invoke("BALANCER_NOT_READY")
            }
        } catch (e: Exception) {
            NativeLogger.e(TAG, "Balancer error: ${e.message}")
            errorCallback?.invoke("BALANCER_ERROR:${e.message}")
        }
    }

    private fun startHealthCheck() {
        stopHealthCheck()
        healthChecker = Executors.newSingleThreadScheduledExecutor()
        healthChecker?.scheduleAtFixedRate({
            if (!running) return@scheduleAtFixedRate
            val aliveCount = uzProcesses.count { proc ->
                try { proc.isAlive } catch (_: Exception) { false }
            }
            val totalCount = uzProcesses.size
            if (aliveCount != totalCount) {
                NativeLogger.w(TAG, "Health: $aliveCount/$totalCount tunnels alive")
                if (aliveCount == 0 && running) {
                    errorCallback?.invoke("ALL_TUNNELS_DIED")
                }
            } else {
                NativeLogger.i(TAG, "Health: $aliveCount/$totalCount tunnels OK")
            }
        }, 5, 15, TimeUnit.SECONDS)
    }

    private fun stopHealthCheck() {
        try { healthChecker?.shutdownNow(); healthChecker = null } catch (_: Exception) {}
    }

    private fun relay(input: java.io.InputStream, output: java.io.OutputStream) {
        val buf = ByteArray(8192); var n: Int
        var total = 0L
        while (input.read(buf).also { n = it } != -1) {
            output.write(buf, 0, n); output.flush()
            total += n
        }
        NativeLogger.i(TAG, "Relay finished: $total bytes transferred")
    }

    private fun stopBalancer() {
        try { balancerServerSocket?.close(); balancerServerSocket = null } catch (_: Exception) {}
        try { balancerThread?.interrupt(); balancerThread = null } catch (_: Exception) {}
    }

    fun stop() {
        NativeLogger.i(TAG, "stop() called, running=$running")
        running = false
        stopHealthCheck()
        stopBalancer()
        val count = uzProcesses.size
        uzProcesses.forEachIndexed { i, proc ->
            try {
                NativeLogger.i(TAG, "Destroying uz_core[$i]")
                proc.destroyForcibly()
            } catch (_: Exception) {}
        }
        uzProcesses.clear()
        try {
            NativeLogger.i(TAG, "Killing remaining libuz_core processes...")
            val killProc = Runtime.getRuntime().exec(arrayOf("sh", "-c",
                "killall -9 libuz_core.so 2>/dev/null; pkill -9 -f libuz_core 2>/dev/null"))
            killProc.waitFor(800, java.util.concurrent.TimeUnit.MILLISECONDS)
        } catch (_: Exception) {}
        socksPort = 0
        NativeLogger.i(TAG, "Zivpn stopped (${count} tunnels cleaned)")
    }

    fun getStatus(): Map<String, Any> {
        val aliveCount = uzProcesses.count { proc ->
            try { proc.isAlive } catch (_: Exception) { false }
        }
        return mapOf(
            "running" to running,
            "socksPort" to socksPort,
            "tunnelsAlive" to aliveCount,
            "tunnelsTotal" to uzProcesses.size
        )
    }
}
