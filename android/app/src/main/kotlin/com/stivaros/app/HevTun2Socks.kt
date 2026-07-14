package com.stivaros.app

import android.content.Context
import android.util.Log
import java.io.File
import java.util.concurrent.locks.ReentrantLock

object HevTun2Socks {
    const val TAG = "HevTun2Socks"
    private var loaded = false
    private val lock = ReentrantLock()
    @Volatile private var running = false

    fun init() {
        if (!loaded) {
            try {
                Class.forName("hev.htproxy.TProxyService")
                hev.htproxy.TProxyService.load()
                loaded = hev.htproxy.TProxyService.isAvailable
                Log.i(TAG, "Init OK loaded=$loaded")
            } catch (e: Throwable) {
                Log.e(TAG, "Init failed: ${e.message}")
                try {
                    System.loadLibrary("hev-socks5-tunnel")
                    loaded = true
                    Log.i(TAG, "Direct load succeeded")
                } catch (e2: Throwable) {
                    Log.e(TAG, "Direct load failed: ${e2.message}")
                }
            }
        }
    }

    val isAvailable get() = loaded

    fun start(context: Context, fd: Int, socksPort: Int, mtu: Int = 1500) {
        lock.lock()
        try {
            if (running) {
                Log.i(TAG, "Stop previous before restart")
                hev.htproxy.TProxyService.TProxyStopService()
                running = false
            }
            val config = buildConfig(socksPort, mtu)
            val configFile = File(context.cacheDir, "hev_config.yaml")
            configFile.writeText(config)
            Log.i(TAG, "Starting hev fd=$fd port=$socksPort")
            hev.htproxy.TProxyService.TProxyStartService(configFile.absolutePath, fd)
            running = true
        } finally {
            lock.unlock()
        }
    }

    fun stop() {
        lock.lock()
        try {
            if (loaded && running) {
                running = false
                hev.htproxy.TProxyService.TProxyStopService()
                Log.i(TAG, "HevTun2Socks stopped")
            }
        } finally {
            lock.unlock()
        }
    }

    private fun buildConfig(socksPort: Int, mtu: Int): String {
        return """
tunnel:
  mtu: $mtu
  ipv4: 198.18.0.1

socks5:
  port: $socksPort
  address: 127.0.0.1
  udp: udp

misc:
  log-level: warn
""".trimIndent()
    }
}
