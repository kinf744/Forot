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
        val configFile = writeXrayConfig(
            serverAddress, serverPort, uuid, protocol,
            transport, tls, sni, host, publicKey, shortId, flow
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
                        NativeLogger.i("XrayManager", "SOCKS ready after ${(i+1)*200}ms")
                    }
                } catch (e: Exception) {
                    if (i == 24) NativeLogger.e("XrayManager", "SOCKS not ready after 5s: ${e.message}")
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
        publicKey: String, shortId: String, flow: String
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
                sb.appendLine("""        "address": "$address",""")
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
                sb.appendLine("""        "address": "$address",""")
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
                sb.appendLine("""        "address": "$address",""")
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
                sb.appendLine("""        "mode": "auto",""")
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
        sb.appendLine("""    "mux": { "enabled": false }""")
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
        if (target.exists()) {
            target.setExecutable(true)
            NativeLogger.i("XrayManager", "Using cached Xray binary: ${target.absolutePath} (size=${target.length()})")
            Log.i(TAG, "Using cached Xray binary")
            return target
        }

        return try {
            NativeLogger.i("XrayManager", "Downloading Xray v25.12.8 from GitHub Releases...")
            Log.i(TAG, "Downloading Xray from GitHub Releases...")
            val url = URL("https://github.com/XTLS/Xray-core/releases/download/v25.12.8/Xray-linux-arm32-v7a.zip")
            val conn = url.openConnection() as HttpURLConnection
            conn.connectTimeout = 30000
            conn.readTimeout = 300000
            conn.setRequestProperty("User-Agent", "Stivaros/1.0")
            NativeLogger.i("XrayManager", "Connected to GitHub CDN, reading zip...")
            conn.inputStream.use { zipInput ->
                val zipBytes = zipInput.readBytes()
                NativeLogger.i("XrayManager", "Downloaded ${zipBytes.size} bytes")
                val tempZip = File(context.cacheDir, "xray.zip")
                tempZip.writeBytes(zipBytes)

                val zis = java.util.zip.ZipInputStream(tempZip.inputStream())
                var entry = zis.nextEntry
                var found = false
                while (entry != null) {
                    NativeLogger.i("XrayManager", "Zip entry: ${entry.name} (${entry.size} bytes)")
                    if (entry.name == "xray") {
                        target.outputStream().use { out -> zis.copyTo(out) }
                        found = true
                        NativeLogger.i("XrayManager", "Extracted xray binary to ${target.absolutePath}")
                        break
                    }
                    entry = zis.nextEntry
                }
                if (!found) NativeLogger.e("XrayManager", "xray binary not found in zip!")
                zis.closeEntry()
                zis.close()
                tempZip.delete()
            }
            target.setExecutable(true)
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
        NativeLogger.i("XrayManager", "Xray PID: ${if (xrayProcess != null) "process started" else "null"}")

        Thread {
            try {
                xrayProcess?.errorStream?.bufferedReader()?.forEachLine { line ->
                    if (line.isNotBlank() && line.length <= 500) {
                        val lower = line.lowercase()
                        when {
                            lower.contains("started") && lower.contains("xray") ->
                                NativeLogger.i("XrayManager", "Xray reports started: $line")
                            (lower.contains("error") || lower.contains("fatal")) &&
                            !lower.contains("warning") && !lower.contains("deprecated") ->
                                errorCallback?.invoke("XRAY_ERROR")
                        }
                        NativeLogger.w("XrayManager", "Xray stderr: $line")
                    }
                }
            } catch (_: Exception) {}
        }.also { it.isDaemon = true }.start()

        Thread {
            try {
                xrayProcess?.inputStream?.bufferedReader()?.forEachLine { line ->
                    if (line.isNotBlank() && line.length <= 500) {
                        val lower = line.lowercase()
                        when {
                            lower.contains("started") && lower.contains("xray") ->
                                NativeLogger.i("XrayManager", "Xray reports started: $line")
                        }
                    }
                }
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
