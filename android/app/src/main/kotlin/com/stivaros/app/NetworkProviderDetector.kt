package com.stivaros.app

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.telephony.TelephonyManager
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ConcurrentHashMap

data class NetworkProvider(
    val connectionType: String,
    val providerName: String,
    val country: String,
    val mcc: String?,
    val mnc: String?,
    val isp: String?,
    val isDetected: Boolean,
    val isVpnConnected: Boolean
)

object NetworkProviderDetector {

    private val cache = ConcurrentHashMap<String, NetworkProvider>()
    private val asnCache = ConcurrentHashMap<String, String>() // ip -> isp name

    private val OPERATORS = mapOf(
        // Cameroun (MCC 624)
        "62401" to Operator("MTN Cameroon", "MTN", "Cameroon", "624"),
        "62402" to Operator("Orange Cameroun", "Orange", "Cameroon", "624"),
        "62404" to Operator("CAMTEL", "CAMTEL", "Cameroon", "624"),
        // Autres pays à ajouter ici
    )

    private data class Operator(
        val name: String,
        val shortName: String,
        val country: String,
        val mcc: String
    )

    fun detect(context: Context): NetworkProvider {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
        if (cm == null) {
            NativeLogger.w("NetDetect", "ConnectivityManager unavailable")
            return unknown("no_connectivity")
        }

        val activeNetwork = cm.activeNetwork ?: return unknown("no_network")
        val caps = cm.getNetworkCapabilities(activeNetwork) ?: return unknown("no_capabilities")
        val tm = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager

        val isVpn = caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)

        when {
            caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> {
                return detectCellular(tm, context)
            }
            caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> {
                return detectWifi(context)
            }
            else -> {
                return unknown("transport_${caps.transport}")
            }
        }.also {
            NativeLogger.i("NetDetect", "detect: type=${it.connectionType} provider=${it.providerName} isp=${it.isp} vpn=$isVpn")
        }
    }

    private fun detectCellular(tm: TelephonyManager?, context: Context): NetworkProvider {
        try {
            val networkOperator = tm?.networkOperator ?: ""
            val networkOperatorName = tm?.networkOperatorName ?: ""
            val simOperator = tm?.simOperator ?: ""
            val simOperatorName = tm?.simOperatorName ?: ""
            val countryIso = tm?.networkCountryIso ?: ""
            val isRoaming = tm?.isNetworkRoaming ?: false

            NativeLogger.i("NetDetect", "cellular: networkOp=$networkOperator name=$networkOperatorName simOp=$simOperator simName=$simOperatorName country=$countryIso roaming=$isRoaming")

            // Try MCC/MNC lookup
            val mccMnc = networkOperator.ifBlank { simOperator }
            if (mccMnc.isNotBlank()) {
                val op = OPERATORS[mccMnc]
                if (op != null) {
                    return NetworkProvider(
                        connectionType = "cellular",
                        providerName = op.shortName,
                        country = op.country,
                        mcc = op.mcc,
                        mnc = mccMnc.substring(3).take(3),
                        isp = op.name,
                        isDetected = true,
                        isVpnConnected = false
                    )
                }
                // Unrecognized MCC/MNC but we have the data
                val mcc = mccMnc.take(3)
                val mnc = mccMnc.substring(3).take(3)
                return NetworkProvider(
                    connectionType = "cellular",
                    providerName = networkOperatorName.ifBlank { "Unknown ($mccMnc)" },
                    country = countryIso,
                    mcc = mcc,
                    mnc = mnc,
                    isp = networkOperatorName.ifBlank { null },
                    isDetected = networkOperatorName.isNotBlank(),
                    isVpnConnected = false
                )
            }

            // Fallback: use operator name
            if (networkOperatorName.isNotBlank()) {
                val provider = normalizeCellularName(networkOperatorName)
                return NetworkProvider(
                    connectionType = "cellular",
                    providerName = provider,
                    country = countryIso,
                    mcc = null,
                    mnc = null,
                    isp = provider,
                    isDetected = true,
                    isVpnConnected = false
                )
            }
        } catch (e: SecurityException) {
            NativeLogger.w("NetDetect", "cellular: missing permission: ${e.message}")
        } catch (e: Exception) {
            NativeLogger.e("NetDetect", "cellular error: ${e.message}")
        }
        return unknown("cellular")
    }

    private fun detectWifi(context: Context): NetworkProvider {
        // Check cache first
        val cached = getPublicIp()?.let { asnCache[it] }
        if (cached != null) {
            NativeLogger.i("NetDetect", "wifi: cache hit -> $cached")
            return NetworkProvider(
                connectionType = "wifi",
                providerName = cached.take(20),
                country = "",
                mcc = null,
                mnc = null,
                isp = cached,
                isDetected = true,
                isVpnConnected = false
            )
        }

        try {
            val ip = getPublicIp() ?: return unknown("wifi_no_ip")
            val isp = lookupASN(ip)
            if (isp != null) {
                asnCache[ip] = isp
                return NetworkProvider(
                    connectionType = "wifi",
                    providerName = isp.take(20),
                    country = "",
                    mcc = null,
                    mnc = null,
                    isp = isp,
                    isDetected = true,
                    isVpnConnected = false
                )
            }
        } catch (e: Exception) {
            NativeLogger.e("NetDetect", "wifi error: ${e.message}")
        }
        return unknown("wifi")
    }

    private fun getPublicIp(): String? {
        val urls = listOf(
            "https://api.ipify.org",
            "https://icanhazip.com",
            "https://checkip.amazonaws.com"
        )
        for (urlStr in urls) {
            try {
                val url = URL(urlStr)
                val conn = url.openConnection() as HttpURLConnection
                conn.connectTimeout = 5000
                conn.readTimeout = 5000
                val ip = BufferedReader(InputStreamReader(conn.inputStream)).readLine()?.trim()
                if (!ip.isNullOrBlank()) return ip
            } catch (_: Exception) {}
        }
        return null
    }

    private fun lookupASN(ip: String): String? {
        try {
            val url = URL("http://ip-api.com/json/$ip?fields=isp,org")
            val conn = url.openConnection() as HttpURLConnection
            conn.connectTimeout = 5000
            conn.readTimeout = 5000
            conn.setRequestProperty("User-Agent", "Stivaros/1.0")
            val reader = BufferedReader(InputStreamReader(conn.inputStream))
            val json = reader.readText()
            reader.close()

            // Parse JSON manually to avoid dependency
            val isp = extractJsonString(json, "isp")
            val org = extractJsonString(json, "org")
            return (isp ?: org)?.takeIf { it.isNotBlank() }
        } catch (e: Exception) {
            NativeLogger.e("NetDetect", "lookupASN error: ${e.message}")
            return null
        }
    }

    private fun extractJsonString(json: String, key: String): String? {
        val search = "\"$key\": \""
        val start = json.indexOf(search)
        if (start < 0) return null
        val valueStart = start + search.length
        val valueEnd = json.indexOf("\"", valueStart)
        if (valueEnd < 0) return null
        return json.substring(valueStart, valueEnd)
    }

    private fun normalizeCellularName(name: String): String {
        val lower = name.lowercase()
        return when {
            "mtn" in lower -> "MTN"
            "orange" in lower -> "Orange"
            "camtel" in lower -> "CAMTEL"
            else -> name
        }
    }

    private fun unknown(reason: String): NetworkProvider {
        NativeLogger.w("NetDetect", "unknown detection: $reason")
        return NetworkProvider(
            connectionType = "unknown",
            providerName = "Unknown",
            country = "",
            mcc = null,
            mnc = null,
            isp = null,
            isDetected = false,
            isVpnConnected = false
        )
    }

    fun clearCache() {
        cache.clear()
        asnCache.clear()
        NativeLogger.i("NetDetect", "cache cleared")
    }
}
