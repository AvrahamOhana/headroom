package com.avrahamohana.headroom.t3k

import android.content.Context
import android.net.Uri
import android.util.Base64
import androidx.browser.customtabs.CustomTabsIntent
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.net.HttpURLConnection
import java.net.URL
import java.net.URLEncoder
import java.security.MessageDigest
import java.security.SecureRandom

data class T3KTone(
    val id: Int, val title: String, val description: String?, val gear: String?, val thumb: String?,
    val makes: String, val tags: String, val user: String?, val downloads: Int?, var favorites: Int?,
    var isFav: Boolean, val calibrated: Boolean, val verified: Boolean,
)
data class T3KModel(val id: Int, val name: String, val url: String, val size: String?, val arch: String?)
data class T3KPage(val tones: List<T3KTone>, val totalPages: Int)

/** TONE3000 API client: OAuth 2.0 PKCE (+ refresh), search / lists / favorites / download. Port of T3K.swift. */
class T3KClient(private val ctx: Context) {
    companion object {
        const val CLIENT_ID = "t3k_pub_hTu9uxJ8c4u7vvPiaz2DQ-FoMul2X5m9"
        const val REDIRECT = "namrig://oauth-callback"
        const val BASE = "https://www.tone3000.com/api/v1"
    }
    private val prefs = ctx.getSharedPreferences("t3k", Context.MODE_PRIVATE)
    var accessToken by mutableStateOf(prefs.getString("token", null)); private set
    private var refreshToken: String? = prefs.getString("refresh", null)
    private var expiresAt: Long = prefs.getLong("expires", 0)
    var authError by mutableStateOf<String?>(null)
    var username by mutableStateOf<String?>(null); private set
    var loggingIn by mutableStateOf(false); private set
    val isLoggedIn get() = accessToken != null

    fun logout() {
        accessToken = null; refreshToken = null; expiresAt = 0; username = null
        prefs.edit().clear().apply()
    }

    // ------------------------------------------------------------ OAuth
    fun beginLogin(activityCtx: Context) {
        authError = null
        val verifier = random()
        prefs.edit().putString("verifier", verifier).apply()
        val uri = Uri.parse("$BASE/oauth/authorize").buildUpon()
            .appendQueryParameter("client_id", CLIENT_ID).appendQueryParameter("redirect_uri", REDIRECT)
            .appendQueryParameter("response_type", "code").appendQueryParameter("code_challenge", challenge(verifier))
            .appendQueryParameter("code_challenge_method", "S256").appendQueryParameter("state", random()).build()
        CustomTabsIntent.Builder().build().launchUrl(activityCtx, uri)
    }

    /** Called with the namrig://oauth-callback intent. */
    suspend fun handleRedirect(uri: Uri) {
        val code = uri.getQueryParameter("code") ?: run { authError = uri.getQueryParameter("error") ?: "No authorization code"; return }
        loggingIn = true
        try {
            token(mapOf("grant_type" to "authorization_code", "code" to code, "code_verifier" to (prefs.getString("verifier", "") ?: ""), "redirect_uri" to REDIRECT))
            loadProfile()
        } catch (e: Exception) { authError = e.message } finally { loggingIn = false }
    }

    private suspend fun token(fields: Map<String, String>) = withContext(Dispatchers.IO) {
        val body = (fields + ("client_id" to CLIENT_ID)).entries.joinToString("&") { "${it.key}=${URLEncoder.encode(it.value, "UTF-8")}" }
        val c = (URL("$BASE/oauth/token").openConnection() as HttpURLConnection).apply {
            requestMethod = "POST"; doOutput = true; setRequestProperty("Content-Type", "application/x-www-form-urlencoded")
        }
        c.outputStream.use { it.write(body.toByteArray()) }
        if (c.responseCode !in 200..299) throw IOException("Login failed (${c.responseCode})")
        val j = JSONObject(c.inputStream.bufferedReader().readText())
        val at = j.getString("access_token")
        val rt = j.optString("refresh_token").ifEmpty { null }
        val exp = if (j.has("expires_in")) System.currentTimeMillis() + ((j.getDouble("expires_in") - 60) * 1000).toLong() else 0L
        withContext(Dispatchers.Main) {
            accessToken = at; if (rt != null) refreshToken = rt; expiresAt = exp
            prefs.edit().putString("token", at).putString("refresh", refreshToken).putLong("expires", exp).apply()
        }
    }
    private suspend fun refreshIfNeeded(force: Boolean = false): Boolean {
        val r = refreshToken ?: return accessToken != null && !force
        if (!force && (expiresAt == 0L || expiresAt > System.currentTimeMillis())) return true
        return runCatching { token(mapOf("grant_type" to "refresh_token", "refresh_token" to r)) }.isSuccess
    }

    suspend fun loadProfile() {
        runCatching { JSONObject(get("$BASE/user")) }.getOrNull()?.let { j ->
            username = j.optString("username").ifEmpty { j.optJSONObject("user")?.optString("username") }
        }
    }

    // ------------------------------------------------------------ API
    private suspend fun get(url: String): String {
        if (!refreshIfNeeded()) { logout(); throw IOException("Please log in to TONE3000") }
        suspend fun once(): Pair<Int, String> = withContext(Dispatchers.IO) {
            val c = (URL(url).openConnection() as HttpURLConnection).apply { setRequestProperty("Authorization", "Bearer $accessToken") }
            val code = c.responseCode
            code to (if (code in 200..299) c.inputStream else (c.errorStream ?: c.inputStream)).bufferedReader().readText()
        }
        var (code, body) = once()
        if (code == 401) {
            if (refreshIfNeeded(force = true)) { val r = once(); code = r.first; body = r.second; if (code == 401) logout() } else logout()
        }
        if (code == 429) throw IOException("TONE3000 rate limit — wait a minute and try again.")
        if (code >= 400) throw IOException("TONE3000 error $code")
        return body
    }

    private fun q(vararg kv: Pair<String, String>) = kv.filter { it.second.isNotEmpty() }.joinToString("&") { "${it.first}=${URLEncoder.encode(it.second, "UTF-8")}" }

    suspend fun search(query: String, gear: String, arch: String, sort: String, format: String, calibrated: Boolean, verified: Boolean, page: Int) =
        parsePage(get("$BASE/tones/search?" + q("page_size" to "25", "page" to "$page", "format" to format, "query" to query, "gears" to gear,
            "architecture" to arch, "sort" to sort, "calibrated" to if (calibrated) "true" else "", "verified" to if (verified) "true" else "")), page)
    suspend fun userTones(list: String, gear: String, page: Int) = parsePage(get("$BASE/tones/$list?" + q("page_size" to "25", "page" to "$page", "gear" to gear)), page)
    suspend fun trending(gear: String) = parsePage(get("$BASE/tones/trending?" + q("gear" to gear)), 1).copy(totalPages = 1)

    suspend fun models(toneId: Int, arch: String): List<T3KModel> {
        val body = get("$BASE/models?" + q("tone_id" to "$toneId", "page_size" to "50", "architecture" to arch))
        val arr = listOf("models", "data").firstNotNullOfOrNull { runCatching { JSONObject(body).getJSONArray(it) }.getOrNull() } ?: runCatching { JSONArray(body) }.getOrNull() ?: JSONArray()
        return (0 until arr.length()).map { arr.getJSONObject(it) }.map { j ->
            T3KModel(j.getInt("id"), j.optString("name"), j.optString("model_url"), j.optString("size").ifEmpty { null },
                j.optString("architecture_version").ifEmpty { j.optString("architecture").ifEmpty { null } })
        }
    }

    suspend fun setFavorite(id: Int, on: Boolean): Boolean {
        if (!refreshIfNeeded()) return false
        return withContext(Dispatchers.IO) {
            runCatching {
                val c = (URL("$BASE/tones/$id/favorite").openConnection() as HttpURLConnection).apply {
                    requestMethod = if (on) "PUT" else "DELETE"; setRequestProperty("Authorization", "Bearer $accessToken")
                }
                c.responseCode in 200..299
            }.getOrDefault(false)
        }
    }

    /** Streams the file to cache with progress (0…1). Returns the file. */
    suspend fun download(m: T3KModel, progress: (Float) -> Unit): File = withContext(Dispatchers.IO) {
        val c = (URL(m.url).openConnection() as HttpURLConnection).apply { accessToken?.let { setRequestProperty("Authorization", "Bearer $it") } }
        if (c.responseCode !in 200..299) throw IOException("Download failed (${c.responseCode})")
        val total = c.contentLengthLong
        val ext = Uri.parse(m.url).lastPathSegment?.substringAfterLast('.', "")?.ifEmpty { null } ?: "nam"
        val dst = File(ctx.cacheDir, "t3k_download.$ext")
        c.inputStream.use { i -> dst.outputStream().use { o ->
            val buf = ByteArray(64 * 1024); var n: Int; var got = 0L; var lastPct = -1
            while (i.read(buf).also { n = it } > 0) {
                o.write(buf, 0, n); got += n
                if (total > 0) { val pct = (got * 50 / total).toInt(); if (pct != lastPct) { lastPct = pct; val f = got.toFloat() / total; withContext(Dispatchers.Main) { progress(f) } } }
            }
        } }
        withContext(Dispatchers.Main) { progress(1f) }
        dst
    }

    private fun parsePage(body: String, page: Int): T3KPage {
        val root = runCatching { JSONObject(body) }.getOrNull()
        val arr = root?.let { r -> listOf("data", "tones").firstNotNullOfOrNull { runCatching { r.getJSONArray(it) }.getOrNull() } }
            ?: runCatching { JSONArray(body) }.getOrNull() ?: JSONArray()
        val tones = (0 until arr.length()).map { arr.getJSONObject(it) }.map { j ->
            fun names(k: String) = j.optJSONArray(k)?.let { a -> (0 until a.length()).mapNotNull { a.optJSONObject(it)?.optString("name") } }.orEmpty()
            T3KTone(j.getInt("id"), j.optString("title"), j.optString("description").ifEmpty { null }, j.optString("gear").ifEmpty { null },
                j.optJSONArray("images")?.optString(0)?.ifEmpty { null }, names("makes").joinToString(", "), names("tags").joinToString(" · "),
                j.optJSONObject("user")?.optString("username")?.ifEmpty { null },
                if (j.has("downloads_count")) j.optInt("downloads_count") else null, if (j.has("favorites_count")) j.optInt("favorites_count") else null,
                j.optBoolean("is_favorite", j.optBoolean("is_favorited", false)), j.optBoolean("calibrated", false), j.optBoolean("verified", false))
        }
        val total = root?.optInt("total_pages", 0)?.takeIf { it > 0 } ?: root?.optInt("pages", 0)?.takeIf { it > 0 } ?: if (tones.size >= 25) page + 1 else page
        return T3KPage(tones, total)
    }

    private fun random(): String { val b = ByteArray(32); SecureRandom().nextBytes(b); return b64(b) }
    private fun challenge(v: String) = b64(MessageDigest.getInstance("SHA-256").digest(v.toByteArray()))
    private fun b64(b: ByteArray) = Base64.encodeToString(b, Base64.URL_SAFE or Base64.NO_PADDING or Base64.NO_WRAP)

    /** Downloaded tone ids (badge). */
    var library: Set<Int>
        get() = prefs.getStringSet("library", emptySet())!!.mapNotNull { it.toIntOrNull() }.toSet()
        set(v) { prefs.edit().putStringSet("library", v.map { "$it" }.toSet()).apply() }
}
