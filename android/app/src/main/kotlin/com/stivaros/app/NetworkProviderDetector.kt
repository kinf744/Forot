package com.stivaros.app

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Build
import android.telephony.SubscriptionManager
import android.telephony.TelephonyManager
import kotlinx.coroutines.async
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.withTimeout
import org.json.JSONObject
import java.io.BufferedReader
import java.io.InputStreamReader
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.ConcurrentHashMap

// ──────────────────────────────────────────────────────────────────────────────
// Data classes
// ──────────────────────────────────────────────────────────────────────────────

data class NetworkProvider(
    val connectionType: String,          // "wifi", "cellular", "ethernet", "unknown"
    val providerName: String,            // display name (e.g. "MTN")
    val fullProviderName: String,        // full name (e.g. "MTN Cameroon")
    val confidence: Confidence,
    val country: String,
    val countryIso: String,
    val mccMnc: String?,
    val mcc: String?,
    val mnc: String?,
    val isp: String?,                    // raw ISP from ASN lookup
    val isRoaming: Boolean,
    val homeOperator: OperatorInfo?,     // SIM operator (roaming source)
    val visitedOperator: OperatorInfo?,  // network operator (roaming target)
    val wifiSources: List<IspSource>?,   // raw ISP sources for WiFi
    val isVpnConnected: Boolean
)

enum class Confidence { HIGH, MEDIUM, LOW, NONE }

data class OperatorInfo(
    val name: String,
    val shortName: String,
    val mccMnc: String,
    val mcc: String,
    val mnc: String,
    val country: String,
    val countryIso: String
)

data class IspSource(
    val source: String,   // e.g. "ip-api.com", "ipapi.co"
    val isp: String,
    val org: String?,
    val ip: String
)

// ──────────────────────────────────────────────────────────────────────────────
// Operator database
// ──────────────────────────────────────────────────────────────────────────────

private data class OperatorEntry(
    val name: String,
    val shortName: String,
    val country: String,
    val countryIso: String
)

private val BUILTIN_OPERATORS = mapOf(
    // ▸ Cameroon (MCC 624)
    "62401" to OperatorEntry("MTN Cameroon", "MTN", "Cameroon", "CM"),
    "62402" to OperatorEntry("Orange Cameroun", "Orange", "Cameroon", "CM"),
    "62403" to OperatorEntry("NEXTTEL", "NEXTTEL", "Cameroon", "CM"),
    "62404" to OperatorEntry("CAMTEL", "CAMTEL", "Cameroon", "CM"),
    // ▸ France (MCC 208)
    "20801" to OperatorEntry("Orange France", "Orange", "France", "FR"),
    "20802" to OperatorEntry("SFR", "SFR", "France", "FR"),
    "20810" to OperatorEntry("SFR", "SFR", "France", "FR"),
    "20815" to OperatorEntry("Free Mobile", "Free", "France", "FR"),
    "20820" to OperatorEntry("Bouygues Telecom", "Bouygues", "France", "FR"),
    // ▸ USA (MCC 310)
    "310410" to OperatorEntry("AT&T", "AT&T", "United States", "US"),
    "310260" to OperatorEntry("T-Mobile", "T-Mobile", "United States", "US"),
    "310030" to OperatorEntry("Verizon", "Verizon", "United States", "US"),
    // ▸ UK (MCC 234)
    "23430" to OperatorEntry("EE", "EE", "United Kingdom", "GB"),
    "23410" to OperatorEntry("O2", "O2", "United Kingdom", "GB"),
    "23415" to OperatorEntry("Vodafone UK", "Vodafone", "United Kingdom", "GB"),
    "23420" to OperatorEntry("Three", "Three", "United Kingdom", "GB"),
)

// ──────────────────────────────────────────────────────────────────────────────
// Main detector
// ──────────────────────────────────────────────────────────────────────────────

object NetworkProviderDetector {

    private val asnCache = ConcurrentHashMap<String, CachedIsp>()
    private val remoteTable = mutableMapOf<String, OperatorEntry>()
    private var remoteTableLoaded = false

    private data class CachedIsp(
        val isp: String,
        val org: String?,
        val ip: String,
        val timestamp: Long
    ) {
        fun isValid(): Boolean = (System.currentTimeMillis() - timestamp) < 3600_000L // 1h
    }

    // ── Public API ──────────────────────────────────────────────────────────

    suspend fun detectAsync(context: Context): NetworkProvider {
        val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as? ConnectivityManager
            ?: return noNetwork("no_connectivity_manager")

        val activeNetwork = cm.activeNetwork ?: return noNetwork("no_active_network")
        val caps = cm.getNetworkCapabilities(activeNetwork) ?: return noNetwork("no_capabilities")

        val isVpn = caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)
        NativeLogger.i("NetDetect", "detect: activeNetwork=$activeNetwork vpn=$isVpn")

        // ── Anti-bias VPN: extract the underlying non-VPN network ──────────
        val realNetwork = findRealNetwork(cm, activeNetwork)
        val realCaps = realNetwork?.let { cm.getNetworkCapabilities(it) }

        val transport = realCaps ?: caps
        val networkForHttp = realNetwork ?: activeNetwork

        return when {
            transport.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) ->
                detectCellular(context, networkForHttp)
            transport.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ->
                detectWifi(context, networkForHttp)
            transport.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) ->
                detectWifi(context, networkForHttp).copy(connectionType = "ethernet")
            else -> noNetwork("transport_unsupported")
        }
    }

    fun detect(context: Context): NetworkProvider {
        return runBlockingSafe { detectAsync(context) }
    }

    // ── Cellular detection ─────────────────────────────────────────────────

    private suspend fun detectCellular(context: Context, network: Network): NetworkProvider {
        val tm = context.getSystemService(Context.TELEPHONY_SERVICE) as? TelephonyManager

        // ── Dual SIM / eSIM support ────────────────────────────────────────
        val subs = getActiveSubscriptions(context)
        NativeLogger.i("NetDetect", "cellular: ${subs.size} active subscription(s)")

        // Prefer default data SIM, then first active
        val subId = findDefaultDataSubId(context) ?: subs.firstOrNull()?.subscriptionId
        val subTm = if (subId != null && Build.VERSION.SDK_INT >= 24) {
            context.getSystemService(Context.TELEPHONY_SERVICE)?.let {
                (it as TelephonyManager).createForSubscriptionId(subId)
            } ?: tm
        } else tm

        val networkOp = safeGet(subTm) { tm -> tm.networkOperator } ?: ""
        val networkOpName = safeGet(subTm) { tm -> tm.networkOperatorName } ?: ""
        val simOp = safeGet(subTm) { tm -> tm.simOperator } ?: ""
        val simOpName = safeGet(subTm) { tm -> tm.simOperatorName } ?: ""
        val countryIso = safeGet(subTm) { tm -> tm.networkCountryIso } ?: ""
        val isRoaming = safeGet(subTm) { tm -> tm.isNetworkRoaming } ?: false

        NativeLogger.i("NetDetect",
            "cellular: netOp=$networkOp netName=$networkOpName simOp=$simOp simName=$simOpName " +
            "country=$countryIso roaming=$isRoaming subId=$subId")

        val visitedOp = lookupOperator(networkOp, networkOpName)
        val homeOp = lookupOperator(simOp, simOpName)

        val effectiveMccMnc = networkOp.ifBlank { simOp }
        val entry = remoteTable[effectiveMccMnc] ?: BUILTIN_OPERATORS[effectiveMccMnc]

        if (entry != null) {
            return NetworkProvider(
                connectionType = "cellular",
                providerName = entry.shortName,
                fullProviderName = entry.name,
                confidence = Confidence.HIGH,
                country = entry.country,
                countryIso = entry.countryIso,
                mccMnc = effectiveMccMnc,
                mcc = effectiveMccMnc.take(3),
                mnc = effectiveMccMnc.drop(3).take(3),
                isp = entry.name,
                isRoaming = isRoaming,
                homeOperator = homeOp,
                visitedOperator = visitedOp,
                wifiSources = null,
                isVpnConnected = false
            )
        }

        // MEDIUM: fallback to network operator name
        val name = normalizeProviderName(networkOpName.ifBlank { simOpName })
        if (name.isNotBlank()) {
            return NetworkProvider(
                connectionType = "cellular",
                providerName = name,
                fullProviderName = networkOpName.ifBlank { simOpName },
                confidence = Confidence.MEDIUM,
                country = countryIso,
                countryIso = countryIso,
                mccMnc = effectiveMccMnc.ifBlank { null },
                mcc = effectiveMccMnc.take(3).ifBlank { null },
                mnc = effectiveMccMnc.drop(3).take(3).ifBlank { null },
                isp = name,
                isRoaming = isRoaming,
                homeOperator = homeOp,
                visitedOperator = visitedOp,
                wifiSources = null,
                isVpnConnected = false
            )
        }

        return noNetwork("cellular_unidentified")
    }

    // ── WiFi detection ─────────────────────────────────────────────────────

    private suspend fun detectWifi(context: Context, network: Network): NetworkProvider {
        // Cache check
        val cached = findCachedIsp()
        if (cached != null) {
            NativeLogger.i("NetDetect", "wifi: ASN cache hit -> ${cached.isp}")
            return providerFromIsp(cached.isp, cached.org, cached.ip, listOf(
                IspSource("cache", cached.isp, cached.org, cached.ip)
            ), Confidence.MEDIUM)
        }

        return try {
            val ispResults = lookupIspDual(network)
            val primary = ispResults.firstOrNull { it.isp.isNotBlank() } ?: return noNetwork("wifi_no_isp")

            // Cache result
            asnCache[primary.ip] = CachedIsp(primary.isp, primary.org, primary.ip, System.currentTimeMillis())

            val confidence = when {
                ispResults.size >= 2 && ispResults.map { it.isp.lowercase() }.distinct().size == 1 ->
                    Confidence.HIGH
                ispResults.size >= 2 -> Confidence.MEDIUM
                else -> Confidence.LOW
            }

            providerFromIsp(primary.isp, primary.org, primary.ip, ispResults, confidence)
        } catch (e: Exception) {
            NativeLogger.e("NetDetect", "wifi detection error: ${e.message}")
            noNetwork("wifi_error")
        }
    }

    // ── Dual ISP lookup (parallel) ─────────────────────────────────────────

    private suspend fun lookupIspDual(network: Network): List<IspSource> = coroutineScope {
        val results = mutableListOf<IspSource>()

        // Get public IP first (bound to the real network)
        val ip = getPublicIpBound(network) ?: return@coroutineScope results

        // Query both APIs in parallel
        val deferred1 = async {
            try {
                withTimeout(5000L) { queryIpApiCom(ip, network) }
            } catch (e: Exception) {
                NativeLogger.w("NetDetect", "ip-api.com failed: ${e.message}")
                null
            }
        }
        val deferred2 = async {
            try {
                withTimeout(5000L) { queryIpapiCo(ip, network) }
            } catch (e: Exception) {
                NativeLogger.w("NetDetect", "ipapi.co failed: ${e.message}")
                null
            }
        }

        listOfNotNull(deferred1.await(), deferred2.await()).forEach { results.add(it) }
        results
    }

    private fun queryIpApiCom(ip: String, network: Network): IspSource? {
        val url = URL("http://ip-api.com/json/$ip?fields=isp,org")
        val conn = network.openConnection(url) as HttpURLConnection
        return httpGetJson(conn) { obj ->
            IspSource("ip-api.com",
                obj.optString("isp", "").ifBlank { return@httpGetJson null },
                obj.optString("org", null),
                ip)
        }
    }

    private fun queryIpapiCo(ip: String, network: Network): IspSource? {
        val url = URL("https://ipapi.co/$ip/json/")
        val conn = network.openConnection(url) as HttpURLConnection
        return httpGetJson(conn) { obj ->
            IspSource("ipapi.co",
                obj.optString("org", "").ifBlank {
                    obj.optString("isp", "").ifBlank { return@httpGetJson null }
                },
                obj.optString("asn", null)?.let { "AS$it" },
                ip)
        }
    }

    // ── Network-bound HTTP helpers ─────────────────────────────────────────

    private fun getPublicIpBound(network: Network): String? {
        val services = listOf(
            "https://api.ipify.org",
            "https://icanhazip.com",
            "https://checkip.amazonaws.com"
        )
        for (urlStr in services) {
            try {
                val url = URL(urlStr)
                val conn = network.openConnection(url) as HttpURLConnection
                conn.connectTimeout = 5000
                conn.readTimeout = 5000
                val ip = BufferedReader(InputStreamReader(conn.inputStream)).readLine()?.trim()
                if (!ip.isNullOrBlank() && ip.matches(Regex("^[\\d.]+$"))) return ip
            } catch (_: Exception) {}
        }
        return null
    }

    private fun <T> httpGetJson(conn: HttpURLConnection, parser: (JSONObject) -> T?): T? {
        return try {
            conn.connectTimeout = 5000
            conn.readTimeout = 5000
            conn.setRequestProperty("User-Agent", "Stivaros/1.0")
            val reader = BufferedReader(InputStreamReader(conn.inputStream))
            val text = reader.readText()
            reader.close()
            parser(JSONObject(text))
        } catch (e: Exception) {
            NativeLogger.w("NetDetect", "HTTP JSON error: ${e.message}")
            null
        }
    }

    // ── VPN anti-bias: find the underlying real network ────────────────────

    private fun findRealNetwork(cm: ConnectivityManager, activeNetwork: Network): Network? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M) return activeNetwork

        val caps = cm.getNetworkCapabilities(activeNetwork) ?: return activeNetwork
        if (!caps.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) return activeNetwork

        // VPN is active: iterate all networks to find the underlying one
        for (network in cm.allNetworks ?: return activeNetwork) {
            if (network == activeNetwork) continue
            val nc = cm.getNetworkCapabilities(network) ?: continue
            if (nc.hasTransport(NetworkCapabilities.TRANSPORT_VPN)) continue
            if (nc.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) ||
                nc.hasTransport(NetworkCapabilities.TRANSPORT_WIFI)) {
                val trans = when {
                    nc.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
                    nc.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
                    else -> "other"
                }
                NativeLogger.i("NetDetect", "findRealNetwork: VPN bypass -> $network ($trans)")
                return network
            }
        }
        return activeNetwork
    }

    // ── Dual SIM / SubscriptionManager ─────────────────────────────────────

    private data class SimInfo(val subscriptionId: Int, val mccMnc: String?)

    private fun getActiveSubscriptions(context: Context): List<SimInfo> {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP_MR1) return emptyList()
        return try {
            val sm = context.getSystemService(Context.TELEPHONY_SUBSCRIPTION_SERVICE) as? SubscriptionManager
            sm?.activeSubscriptionInfoList?.mapNotNull { info ->
                SimInfo(info.subscriptionId, info.mccString?.let { mcc ->
                    info.mncString?.let { mnc -> "$mcc$mnc" }
                })
            } ?: emptyList()
        } catch (e: SecurityException) {
            NativeLogger.w("NetDetect", "getActiveSubscriptions: permission denied")
            emptyList()
        }
    }

    private fun findDefaultDataSubId(context: Context): Int? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.N) return null
        return try {
            val sm = context.getSystemService(Context.TELEPHONY_SUBSCRIPTION_SERVICE) as SubscriptionManager?
            if (sm != null) {
                val method = sm::class.java.getMethod("getDefaultDataSubscriptionId")
                val subId = method.invoke(sm) as Int
                if (subId != -1) subId else null
            } else null
        } catch (_: Exception) { null }
    }

    // ── Operator lookup ────────────────────────────────────────────────────

    private fun lookupOperator(mccMnc: String, name: String): OperatorInfo? {
        if (mccMnc.isBlank()) return null
        val entry = remoteTable[mccMnc] ?: BUILTIN_OPERATORS[mccMnc]
        if (entry != null) {
            return OperatorInfo(
                name = entry.name,
                shortName = entry.shortName,
                mccMnc = mccMnc,
                mcc = mccMnc.take(3),
                mnc = mccMnc.drop(3).take(3),
                country = entry.country,
                countryIso = entry.countryIso
            )
        }
        if (name.isNotBlank()) {
            val short = normalizeProviderName(name)
            return OperatorInfo(
                name = name, shortName = short,
                mccMnc = mccMnc, mcc = mccMnc.take(3), mnc = mccMnc.drop(3),
                country = "", countryIso = ""
            )
        }
        return null
    }

    private fun normalizeProviderName(name: String): String {
        val lower = name.lowercase()
        return when {
            "mtn" in lower -> "MTN"
            "orange" in lower -> "Orange"
            "camtel" in lower -> "CAMTEL"
            "vodafone" in lower -> "Vodafone"
            "africell" in lower -> "Africell"
            "nexttel" in lower -> "NEXTTEL"
            "free" in lower -> "Free"
            "bouygues" in lower -> "Bouygues"
            "sfr" in lower -> "SFR"
            "t-mobile" in lower || "tmobile" in lower -> "T-Mobile"
            "verizon" in lower -> "Verizon"
            "at&t" in lower || "att" in lower -> "AT&T"
            else -> name
        }
    }

    // ── Remote table loader ────────────────────────────────────────────────

    suspend fun loadRemoteTable(context: Context) {
        if (remoteTableLoaded) return
        try {
            val url = URL("https://api-v1.kingom.ggff.net:5443/api/v1/mcc-mnc.json")
            val conn = withTimeout(5000L) {
                val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                val network = cm.activeNetwork
                if (network != null) network.openConnection(url) as HttpURLConnection
                else url.openConnection() as HttpURLConnection
            }
            conn.connectTimeout = 5000
            conn.readTimeout = 5000
            val text = BufferedReader(InputStreamReader(conn.inputStream)).readText()
            val json = JSONObject(text)
            val keys = json.keys()
            while (keys.hasNext()) {
                val key = keys.next()
                val entry = json.getJSONObject(key)
                remoteTable[key] = OperatorEntry(
                    name = entry.getString("name"),
                    shortName = entry.getString("short"),
                    country = entry.getString("country"),
                    countryIso = entry.getString("iso")
                )
            }
            remoteTableLoaded = true
            NativeLogger.i("NetDetect", "Remote table loaded: ${remoteTable.size} entries")
        } catch (e: Exception) {
            NativeLogger.w("NetDetect", "Remote table load failed, using built-in: ${e.message}")
        }
    }

    // ── Utility ────────────────────────────────────────────────────────────

    private fun findCachedIsp(): CachedIsp? {
        return asnCache.values.firstOrNull { it.isValid() }
    }

    private fun providerFromIsp(
        isp: String, org: String?, ip: String,
        sources: List<IspSource>, confidence: Confidence
    ): NetworkProvider {
        val short = normalizeProviderName(isp)
        return NetworkProvider(
            connectionType = "wifi",
            providerName = short,
            fullProviderName = isp,
            confidence = confidence,
            country = "", countryIso = "",
            mccMnc = null, mcc = null, mnc = null,
            isp = isp,
            isRoaming = false,
            homeOperator = null, visitedOperator = null,
            wifiSources = sources,
            isVpnConnected = false
        )
    }

    private fun noNetwork(reason: String): NetworkProvider {
        NativeLogger.w("NetDetect", "noNetwork: $reason")
        return NetworkProvider(
            connectionType = "unknown", providerName = "Unknown", fullProviderName = "",
            confidence = Confidence.NONE,
            country = "", countryIso = "",
            mccMnc = null, mcc = null, mnc = null,
            isp = null, isRoaming = false,
            homeOperator = null, visitedOperator = null,
            wifiSources = null, isVpnConnected = false
        )
    }

    /** Safe TelephonyManager call that catches SecurityException. */
    private fun <T> safeGet(tm: TelephonyManager?, block: (TelephonyManager) -> T): T? {
        if (tm == null) return null
        return try { block(tm) } catch (e: SecurityException) { null }
    }

    fun clearCache() {
        asnCache.clear()
        NativeLogger.i("NetDetect", "cache cleared")
    }

    // ── Sync wrapper (for Flutter method channel) ──────────────────────────

    private fun <T> runBlockingSafe(block: suspend () -> T): T {
        var result: T? = null
        var error: Throwable? = null
        val latch = java.util.concurrent.CountDownLatch(1)
        CoroutineScope(Dispatchers.IO).launch {
            try {
                result = block()
            } catch (e: Throwable) {
                error = e
            } finally {
                latch.countDown()
            }
        }
        latch.await()
        if (error != null) throw error!!
        @Suppress("UNCHECKED_CAST")
        return result as T
    }
}
