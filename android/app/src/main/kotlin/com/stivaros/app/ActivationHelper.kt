package com.stivaros.app

import android.content.Context
import android.provider.Settings
import java.security.MessageDigest

class ActivationHelper {

    companion object {
        private const val TAG = "ActivationHelper"

        fun getHardwareId(context: Context): String {
            val androidId = Settings.Secure.getString(
                context.contentResolver,
                Settings.Secure.ANDROID_ID
            ) ?: "unknown"
            val fingerprint = "${android.os.Build.FINGERPRINT}:${android.os.Build.SERIAL}"
            val combined = "$androidId:$fingerprint"
            return sha256(combined)
        }

        fun getDeviceInstallId(context: Context): String {
            val prefs = context.getSharedPreferences("stivaros_prefs", Context.MODE_PRIVATE)
            var installId = prefs.getString("device_install_id", null)
            if (installId == null) {
                installId = java.util.UUID.randomUUID().toString()
                prefs.edit().putString("device_install_id", installId).apply()
            }
            return installId
        }

        fun getAppVersion(context: Context): String {
            try {
                val pkg = context.packageManager.getPackageInfo(context.packageName, 0)
                return pkg.versionName ?: "1.0.0"
            } catch (e: Exception) {
                return "1.0.0"
            }
        }

        fun getDeviceInfo(): Map<String, String> {
            return mapOf(
                "manufacturer" to android.os.Build.MANUFACTURER,
                "model" to android.os.Build.MODEL,
                "androidVersion" to android.os.Build.VERSION.RELEASE,
                "sdkInt" to android.os.Build.VERSION.SDK_INT.toString(),
                "board" to android.os.Build.BOARD,
                "brand" to android.os.Build.BRAND,
                "device" to android.os.Build.DEVICE,
                "hardware" to android.os.Build.HARDWARE,
                "product" to android.os.Build.PRODUCT,
                "supportedAbis" to android.os.Build.SUPPORTED_ABIS.joinToString(",")
            )
        }

        private fun sha256(input: String): String {
            val digest = MessageDigest.getInstance("SHA-256")
            val bytes = digest.digest(input.toByteArray())
            return bytes.joinToString("") { "%02x".format(it) }
        }
    }
}
