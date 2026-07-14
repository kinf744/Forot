package hev.htproxy

import android.util.Log

class TProxyService {
    companion object {
        private var loaded = false
        const val TAG = "TProxyService"

        fun load() {
            if (!loaded) {
                try {
                    System.loadLibrary("hev-socks5-tunnel")
                    loaded = true
                    Log.i(TAG, "hev-socks5-tunnel loaded")
                } catch (e: Throwable) {
                    Log.e(TAG, "Load failed: ${e.message}")
                    try {
                        System.loadLibrary("tun2socks")
                        loaded = true
                        Log.i(TAG, "tun2socks loaded (fallback)")
                    } catch (e2: Throwable) {
                        Log.e(TAG, "Fallback load failed: ${e2.message}")
                    }
                }
            }
        }

        val isAvailable get() = loaded

        @JvmStatic external fun TProxyStartService(configPath: String, fd: Int)
        @JvmStatic external fun TProxyStopService()
        @JvmStatic external fun TProxyGetStats(): LongArray?
    }
}
