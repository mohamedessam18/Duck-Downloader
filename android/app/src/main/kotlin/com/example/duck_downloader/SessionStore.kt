package com.example.duck_downloader

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import org.json.JSONArray
import org.json.JSONObject
import java.net.URI

/**
 * The signed-in sessions, mirrored from Dart so the share sheet can use them.
 *
 * A link shared from another app never touches the Flutter isolate: ShareActivity
 * and DownloadService call the backend directly. Without this, being signed into
 * Instagram inside Duck did nothing for a private post shared *into* Duck — the
 * two entry points disagreed about who you were.
 *
 * Dart pushes the jars along with the hosts each one covers, rather than this
 * side keeping its own copy of the platform table. One table, in
 * platform_sessions.dart; a second one here would drift from it, which is the
 * bug that made Threads and Udemy take the wrong path for months.
 */
object SessionStore {
    private const val FILE = "duck_sessions"
    private const val KEY = "sessions"

    private fun prefs(context: Context): SharedPreferences? = try {
        EncryptedSharedPreferences.create(
            context,
            FILE,
            MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    } catch (_: Throwable) {
        // A device whose keystore refuses is a device that downloads signed
        // out, not one that crashes on the share sheet.
        null
    }

    /** Replaces every stored session with [payload], a JSON array from Dart. */
    fun replaceAll(context: Context, payload: String) {
        prefs(context)?.edit()?.putString(KEY, payload)?.apply()
    }

    fun clear(context: Context) {
        prefs(context)?.edit()?.remove(KEY)?.apply()
    }

    /**
     * The cookies for [url], or null.
     *
     * Matched on the parsed host and only as an exact host or a subdomain of
     * one. Substring matching would send `evil.com/?x=instagram.com` the
     * user's Instagram session.
     */
    fun cookiesForUrl(context: Context, url: String): String? {
        val host = try {
            URI(url).host?.lowercase()
        } catch (_: Throwable) {
            null
        } ?: return null

        val raw = prefs(context)?.getString(KEY, null) ?: return null
        return try {
            val entries = JSONArray(raw)
            for (i in 0 until entries.length()) {
                val entry = entries.optJSONObject(i) ?: continue
                val cookies = entry.optString("cookies")
                if (cookies.isBlank()) continue
                val hosts = entry.optJSONArray("hosts") ?: continue
                for (j in 0 until hosts.length()) {
                    val domain = hosts.optString(j).lowercase()
                    if (domain.isNotEmpty() &&
                        (host == domain || host.endsWith(".$domain"))
                    ) {
                        return cookies
                    }
                }
            }
            null
        } catch (_: Throwable) {
            null
        }
    }

    /** Adds `cookies` to a request body when this link has a session. */
    fun attach(context: Context, url: String, body: JSONObject): JSONObject {
        val cookies = cookiesForUrl(context, url)
        if (!cookies.isNullOrBlank()) body.put("cookies", cookies)
        return body
    }
}
