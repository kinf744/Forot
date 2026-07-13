package com.stivaros.app

import android.content.Context
import android.util.Log
import java.io.File
import java.io.FileOutputStream
import java.net.HttpURLConnection
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.net.URL

class XrayManager(private val context: Context) {

    companion object {
        const val TAG = "XrayManager"
        fun getFreePort(): Int = try {
            ServerSocket(0).use { it.localPort }
        } catch (_: Exception) { 10808 }
    }

    private var socksPort: Int = 0
    private var xrayProcess: Process? = null
    private var running = false
    var errorCallback: ((String) -> Unit)? = null

    fun getSocksPort(): Int = socksPort
    fun isRunning(): Boolean = running

    fun start(
        serverAddress: String,
        serverPort: Int,
        uuid: String,
        protocol: String = "vless",
        transport: String = "xhttp",
        tls: Boolean = true,
        sni: String = serverAddress,
        host: String = sni,
        publicKey: String = "",
        shortId: String = "",
        flow: String = ""
    ) {
        stop()
        socksPort = getFreePort()
        running = true

        NativeLogger.i("XrayManager", "start: address=$serverAddress port=$serverPort uuid=$uuid transport=$transport sni=$sni host=$host socksPort=$socksPort")
        NativeLogger.i("XrayManager", "Writing Xray config...")

        // Resolve server address to IP to avoid DNS loop through the tunnel
        var serverIp = ""
        if (!serverAddress.matches(Regex("^\\d+\\.\\d+\\.\\d+\\.\\d+$"))) {
            try {
                val resolved = java.net.InetAddress.getByName(serverAddress).hostAddress
                if (resolved != null && resolved != serverAddress) {
                    serverIp = resolved
                    NativeLogger.i("XrayManager", "Resolved $serverAddress -> $serverIp")
                }
            } catch (e: Exception) {
                NativeLogger.w("XrayManager", "DNS resolve failed for $serverAddress: ${e.message}")
            }
        }
        val configFile = writeXrayConfig(
            serverAddress, serverPort, uuid, protocol,
            transport, tls, sni, host, publicKey, shortId, flow, serverIp
        )
        NativeLogger.i("XrayManager", "Config written to: ${configFile.absolutePath}")

        NativeLogger.i("XrayManager", "Extracting/downloading Xray binary...")
        val binary = extractXrayBinary() ?: throw Exception("Xray binary not found")
        NativeLogger.i("XrayManager", "Binary ready at: ${binary.absolutePath}")

        NativeLogger.i("XrayManager", "Starting Xray process...")
        startXrayProcess(binary, configFile)

        NativeLogger.i("XrayManager", "Waiting for SOCKS port $socksPort to be ready...")
        var ready = false
        for (i in 0 until 25) {
            if (!ready) {
                Thread.sleep(200)
                try {
                    Socket().use { s ->
                        s.connect(InetSocketAddress("127.0.0.1", socksPort), 200)
                        ready = true
                        NativeLogger.i("XrayManager", "SOCKS ready after ${(i+1)*200}ms (attempt ${i+1}/25)")
                    }
                } catch (e: Exception) {
                    NativeLogger.w("XrayManager", "SOCKS attempt ${i+1}/25 failed: ${e.message}")
                }
            }
        }
        if (!ready) {
            running = false
            NativeLogger.e("XrayManager", "Xray failed to start within timeout (5s)")
            throw Exception("Xray failed to start within timeout")
        }
        NativeLogger.i("XrayManager", "Xray started successfully on port $socksPort")
        Log.i(TAG, "Xray started on port $socksPort")
    }

    private fun writeXrayConfig(
        address: String, port: Int, uuid: String,
        protocol: String, transport: String,
        tls: Boolean, sni: String, host: String,
        publicKey: String, shortId: String, flow: String,
        serverIp: String = ""
    ): File {
        val sb = StringBuilder()
        sb.appendLine("{")
        sb.appendLine("""  "log": { "loglevel": "warning" },""")
        sb.appendLine("""  "inbounds": [{""")
        sb.appendLine("""    "port": $socksPort,""")
        sb.appendLine("""    "listen": "127.0.0.1",""")
        sb.appendLine("""    "protocol": "socks",""")
        sb.appendLine("""    "settings": { "udp": true }""")
        sb.appendLine("""  }],""")
        sb.appendLine("""  "outbounds": [{""")
        sb.appendLine("""    "protocol": "$protocol",""")

        when (protocol) {
            "vless" -> {
                sb.appendLine("""    "settings": {""")
                sb.appendLine("""      "vnext": [{""")
                sb.appendLine("""        "address": "${if (serverIp.isNotEmpty()) serverIp else address}",""")
                sb.appendLine("""        "port": $port,""")
                sb.appendLine("""        "users": [{""")
                sb.appendLine("""          "id": "$uuid",""")
                sb.appendLine("""          "encryption": "none",""")
                sb.appendLine("""          "flow": "$flow"""")
                sb.appendLine("""        }]""")
                sb.appendLine("""      }]""")
                sb.appendLine("""    },""")
            }
            "vmess" -> {
                sb.appendLine("""    "settings": {""")
                sb.appendLine("""      "vnext": [{""")
                sb.appendLine("""        "address": "${if (serverIp.isNotEmpty()) serverIp else address}",""")
                sb.appendLine("""        "port": $port,""")
                sb.appendLine("""        "users": [{""")
                sb.appendLine("""          "id": "$uuid",""")
                sb.appendLine("""          "alterId": 0,""")
                sb.appendLine("""          "security": "auto"""")
                sb.appendLine("""        }]""")
                sb.appendLine("""      }]""")
                sb.appendLine("""    },""")
            }
            "trojan" -> {
                sb.appendLine("""    "settings": {""")
                sb.appendLine("""      "servers": [{""")
                sb.appendLine("""        "address": "${if (serverIp.isNotEmpty()) serverIp else address}",""")
                sb.appendLine("""        "port": $port,""")
                sb.appendLine("""        "password": "$uuid"""")
                sb.appendLine("""      }]""")
                sb.appendLine("""    },""")
            }
        }

        // Stream settings
        sb.appendLine("""    "streamSettings": {""")
        sb.appendLine("""      "network": "$transport",""")

        when (transport) {
            "xhttp" -> {
                sb.appendLine("""      "xhttpSettings": {""")
                sb.appendLine("""        "path": "/vless-xhttp",""")
                sb.appendLine("""        "mode": "stream-up",""")
                sb.appendLine("""        "host": "$host",""")
                sb.appendLine("""        "scMaxConcurrentPosts": 16,""")
                sb.appendLine("""        "scMinPostsIntervalMs": 10,""")
                sb.appendLine("""        "scMaxEachPostBytes": 1000000,""")
                sb.appendLine("""        "noSSEHeader": true,""")
                sb.appendLine("""        "xPaddingBytes": "100-1000"""")
                sb.appendLine("""      },""")
            }
            "ws" -> {
                sb.appendLine("""      "wsSettings": {""")
                sb.appendLine("""        "path": "/",""")
                sb.appendLine("""        "headers": { "Host": "$sni" }""")
                sb.appendLine("""      },""")
            }
            "grpc" -> {
                sb.appendLine("""      "grpcSettings": {""")
                sb.appendLine("""        "serviceName": "/",""")
                sb.appendLine("""        "multiMode": false""")
                sb.appendLine("""      },""")
            }
            "kcp" -> {
                sb.appendLine("""      "kcpSettings": {""")
                sb.appendLine("""        "mtu": 1350, "tti": 20,""")
                sb.appendLine("""        "header": { "type": "none" }""")
                sb.appendLine("""      },""")
            }
        }

        if (publicKey.isNotBlank()) {
            sb.appendLine("""      "security": "reality",""")
            sb.appendLine("""      "realitySettings": {""")
            sb.appendLine("""        "serverName": "$sni",""")
            sb.appendLine("""        "fingerprint": "chrome",""")
            sb.appendLine("""        "publicKey": "$publicKey",""")
            sb.appendLine("""        "shortId": "$shortId"""")
            sb.appendLine("""      }""")
        } else if (tls) {
            sb.appendLine("""      "security": "tls",""")
            sb.appendLine("""      "tlsSettings": {""")
            sb.appendLine("""        "serverName": "$sni",""")
            sb.appendLine("""        "allowInsecure": true,""")
            sb.appendLine("""        "fingerprint": "chrome"""")
            sb.appendLine("""      }""")
        } else {
            sb.appendLine("""      "security": "none""")
        }

        sb.appendLine("""    },""")
        sb.appendLine("""    "mux": { "enabled": true, "concurrency": 8 }""")
        sb.appendLine("""  }],""")
        sb.appendLine("""  "routing": { "rules": [] }""")
        sb.appendLine("}")

        val file = File(context.filesDir, "xray_config.json")
        file.writeText(sb.toString())
        Log.i(TAG, "Config written: ${file.absolutePath}")
        return file
    }

    private fun extractXrayBinary(): File? {
        val target = File(context.filesDir, "xray")

        // PRIORITY 1: Use directly from nativeLibraryDir (Android extrait avec bonnes permissions)
        try {
            val nativeFile = File(context.applicationInfo.nativeLibraryDir, "libxray.so")
            if (nativeFile.exists()) {
                NativeLogger.i("XrayManager", "Using nativeLib directly: ${nativeFile.absolutePath} (size=${nativeFile.length()})")
                // Delete stale cached copy so we never accidentally use it
                if (target.exists()) target.delete()
                return nativeFile
            }
        } catch (e: Exception) {
            NativeLogger.w("XrayManager", "nativeLib error: ${e.message}")
        }

        // PRIORITY 2: Cached copy (may also be from nativeLib on older launches)
        if (target.exists()) {
            // On Android 14+, filesDir is noexec, so this will fail — but try anyway for older devices
            if (!target.setExecutable(true)) {
                try { Runtime.getRuntime().exec(arrayOf("chmod", "755", target.absolutePath)).waitFor() } catch (_: Exception) {}
            }
            NativeLogger.w("XrayManager", "Using cached Xray (may fail on Android 14+): ${target.absolutePath} (size=${target.length()})")
            return target
        }

        // PRIORITY 3: Download from GitHub
        return try {
            NativeLogger.i("XrayManager", "Downloading Xray v25.12.8 from GitHub Releases...")
            Log.i(TAG, "Downloading Xray from GitHub Releases...")
            val url = URL("https://github.com/XTLS/Xray-core/releases/download/v25.12.8/Xray-linux-arm32-v7a.zip")
            val conn = url.openConnection() as HttpURLConnection
            conn.connectTimeout = 30000
            conn.readTimeout = 300000
            conn.setRequestProperty("User-Agent", "Stivaros/1.0")
            NativeLogger.i("XrayManager", "Connected to GitHub CDN, reading zip for $arch...")
            conn.inputStream.use { zipInput ->
                val zipBytes = zipInput.readBytes()
                NativeLogger.i("XrayManager", "Downloaded ${zipBytes.size} bytes")
                val tempZip = File(context.cacheDir, "xray.zip")
                tempZip.writeBytes(zipBytes)
                val zis = java.util.zip.ZipInputStream(tempZip.inputStream())
                var entry = zis.nextEntry
                var found = false
                while (entry != null) {
                    if (entry.name == "xray") {
                        target.outputStream().use { out -> zis.copyTo(out) }
                        found = true
                        break
                    }
                    entry = zis.nextEntry
                }
                if (!found) NativeLogger.e("XrayManager", "xray binary not found in zip!")
                zis.closeEntry()
                zis.close()
                tempZip.delete()
            }
            if (!target.setExecutable(true)) {
                Runtime.getRuntime().exec(arrayOf("chmod", "755", target.absolutePath)).waitFor()
            }
            NativeLogger.i("XrayManager", "Xray ready: ${target.absolutePath} (size=${target.length()})")
            target
        } catch (e: Exception) {
            NativeLogger.e("XrayManager", "Xray download/extract failed: ${e.message}")
            Log.e(TAG, "Xray download failed: ${e.message}")
            null
        }
    }

    private fun startXrayProcess(binary: File, configFile: File) {
        val cmd = arrayOf(binary.absolutePath, "run", "-c", configFile.absolutePath)
        NativeLogger.i("XrayManager", "Exec: ${cmd.joinToString(" ")}")
        xrayProcess = Runtime.getRuntime().exec(cmd)
        NativeLogger.i("XrayManager", "Xray process alive=${xrayProcess?.isAlive}")

        Thread {
            try {
                xrayProcess?.errorStream?.bufferedReader()?.forEachLine { line ->
                    if (line.isNotBlank()) {
                        val truncated = if (line.length > 500) line.take(500) + "..." else line
                        val lower = truncated.lowercase()
                        if (lower.contains("started")) NativeLogger.i("XrayManager", "Xray stdout: $truncated")
                        else if (lower.contains("error") || lower.contains("fatal")) {
                            NativeLogger.e("XrayManager", "Xray stderr: $truncated")
                            errorCallback?.invoke("XRAY_ERROR")
                        }
                        else NativeLogger.w("XrayManager", "Xray stderr: $truncated")
                    }
                }
            } catch (e: Exception) {
                NativeLogger.w("XrayManager", "stderr reader ended: ${e.message}")
            }
        }.also { it.isDaemon = true }.start()

        Thread {
            try {
                xrayProcess?.inputStream?.bufferedReader()?.forEachLine { line ->
                    if (line.isNotBlank()) {
                        val truncated = if (line.length > 500) line.take(500) + "..." else line
                        NativeLogger.i("XrayManager", "Xray stdout: $truncated")
                    }
                }
            } catch (e: Exception) {
                NativeLogger.w("XrayManager", "stdout reader ended: ${e.message}")
            }
        }.also { it.isDaemon = true }.start()

        // Monitor process exit
        Thread {
            try {
                val exitCode = xrayProcess?.waitFor()
                NativeLogger.w("XrayManager", "Xray process exited code=$exitCode running=$running")
                if (running) errorCallback?.invoke("XRAY_DIED")
            } catch (_: Exception) {}
        }.also { it.isDaemon = true }.start()
    }

    fun stop() {
        NativeLogger.i("XrayManager", "stop() called, running=$running")
        running = false
        try {
            xrayProcess?.let { p ->
                p.inputStream?.close()
                p.errorStream?.close()
                p.outputStream?.close()
                p.destroyForcibly()
                NativeLogger.i("XrayManager", "Xray process destroyed")
            }
        } catch (_: Exception) {}
        xrayProcess = null
        socksPort = 0
        Log.i(TAG, "Xray stopped")
    }
}
