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
        publicKey: String = "",
        shortId: String = "",
        flow: String = ""
    ) {
        stop()
        socksPort = getFreePort()
        running = true

        val configFile = writeXrayConfig(
            serverAddress, serverPort, uuid, protocol,
            transport, tls, sni, publicKey, shortId, flow
        )
        val binary = extractXrayBinary() ?: throw Exception("Xray binary not found")
        startXrayProcess(binary, configFile)

        var ready = false
        for (i in 0 until 25) {
            if (!ready) {
                Thread.sleep(200)
                try {
                    Socket().use { s ->
                        s.connect(InetSocketAddress("127.0.0.1", socksPort), 200)
                        ready = true
                    }
                } catch (_: Exception) {}
            }
        }
        if (!ready) {
            running = false
            throw Exception("Xray failed to start within timeout")
        }
        Log.i(TAG, "Xray started on port $socksPort")
    }

    private fun writeXrayConfig(
        address: String, port: Int, uuid: String,
        protocol: String, transport: String,
        tls: Boolean, sni: String,
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
                sb.appendLine("""        "mode": "auto""")
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
            sb.appendLine("""        "allowInsecure": false,""")
            sb.appendLine("""        "fingerprint": "chrome"""")
            sb.appendLine("""      }""")
        } else {
            sb.appendLine("""      "security": "none""")
        }

        sb.appendLine("""    }""")
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
            Log.i(TAG, "Using cached Xray binary")
            return target
        }
        return try {
            Log.i(TAG, "Downloading Xray binary...")
            val url = URL("https://github.com/XTLS/Xray-core/releases/latest/download/Xray-linux-arm32-v7a.zip")
            val conn = url.openConnection() as HttpURLConnection
            conn.connectTimeout = 30000
            conn.readTimeout = 60000
            conn.inputStream.use { zipInput ->
                val zipBytes = zipInput.readBytes()
                val tempZip = File(context.cacheDir, "xray.zip")
                tempZip.writeBytes(zipBytes)

                val zis = java.util.zip.ZipInputStream(tempZip.inputStream())
                var entry = zis.nextEntry
                while (entry != null) {
                    if (entry.name == "xray") {
                        target.outputStream().use { out -> zis.copyTo(out) }
                        break
                    }
                    entry = zis.nextEntry
                }
                zis.closeEntry()
                zis.close()
                tempZip.delete()
            }
            target.setExecutable(true)
            Log.i(TAG, "Xray downloaded to ${target.absolutePath}")
            target
        } catch (e: Exception) {
            Log.e(TAG, "Xray download failed: ${e.message}")
            null
        }
    }

    private fun startXrayProcess(binary: File, configFile: File) {
        val cmd = arrayOf(binary.absolutePath, "run", "-c", configFile.absolutePath)
        xrayProcess = Runtime.getRuntime().exec(cmd)

        Thread {
            try {
                xrayProcess?.errorStream?.bufferedReader()?.forEachLine { line ->
                    if (line.isNotBlank() && line.length <= 500) {
                        val lower = line.lowercase()
                        when {
                            lower.contains("started") && lower.contains("xray") ->
                                Log.i(TAG, "Xray started")
                            (lower.contains("error") || lower.contains("fatal")) &&
                            !lower.contains("warning") && !lower.contains("deprecated") ->
                                errorCallback?.invoke("XRAY_ERROR")
                        }
                        Log.w(TAG, "Xray stderr: ${line.take(150)}")
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
                                Log.i(TAG, "Xray started")
                        }
                    }
                }
            } catch (_: Exception) {}
        }.also { it.isDaemon = true }.start()
    }

    fun stop() {
        running = false
        try {
            xrayProcess?.let { p ->
                p.inputStream?.close()
                p.errorStream?.close()
                p.outputStream?.close()
                p.destroyForcibly()
            }
        } catch (_: Exception) {}
        xrayProcess = null
        socksPort = 0
        Log.i(TAG, "Xray stopped")
    }
}
