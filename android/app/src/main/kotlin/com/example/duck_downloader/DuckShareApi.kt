package com.example.duck_downloader

import android.content.Context
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.RequestBody.Companion.toRequestBody
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject
import java.util.concurrent.TimeUnit

/**
 * The same backend the Dart side talks to, reached from native code.
 *
 * The share sheet has to show real qualities before any Flutter engine has
 * booted — an engine cold start is over a second, and the whole point of the
 * sheet is that it appears instantly over the app the user is already in. So
 * the sheet and the download service speak to the API directly. This is a
 * second *client*, not a second download engine: `/api/extract`,
 * `/api/download` and `/ws/download/{id}` are exactly the endpoints
 * `api_client.dart` uses, so the two paths cannot produce different results.
 */
object DuckShareApi {

    /// Mirrors `_defaultApiBaseUrl` in `lib/services/api_client.dart`.
    ///
    /// Dart overwrites [PREF_BASE_URL] with whatever it actually resolved on
    /// every launch, so a `--dart-define=DUCK_API_BASE_URL=...` override still
    /// reaches native code. This constant is only what a device that has never
    /// opened the app falls back to.
    private const val DEFAULT_BASE_URL = "https://api.duckdownloader.site"

    const val PREFS = "duck_share"
    private const val PREF_BASE_URL = "apiBaseUrl"

    private val JSON = "application/json; charset=utf-8".toMediaType()

    /// Long read timeout: `/api/extract` runs yt-dlp server-side and a cold
    /// platform can genuinely take half a minute.
    val client: OkHttpClient = OkHttpClient.Builder()
        .connectTimeout(20, TimeUnit.SECONDS)
        .readTimeout(60, TimeUnit.SECONDS)
        .writeTimeout(30, TimeUnit.SECONDS)
        // A download can outlast any sane read timeout; the file GET sets its
        // own. Pings keep the progress socket alive behind carrier NAT.
        .pingInterval(20, TimeUnit.SECONDS)
        .build()

    fun baseUrl(context: Context): String {
        val stored = context
            .getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(PREF_BASE_URL, null)
            ?.trim()
            ?.trimEnd('/')
        return if (stored.isNullOrEmpty()) DEFAULT_BASE_URL else stored
    }

    fun absoluteFileUrl(context: Context, value: String): String {
        if (value.startsWith("http")) return value
        return baseUrl(context) + value
    }

    data class Format(val id: String, val label: String, val height: Int?)

    data class Meta(
        val title: String,
        val platform: String,
        val thumbnail: String?,
        val videoQualities: List<Format>,
        val audioQualities: List<Format>,
    )

    fun extract(context: Context, url: String): Meta {
        val body = SessionStore.attach(context, url, JSONObject().put("url", url))
            .toString()
            .toRequestBody(JSON)
        val request = Request.Builder()
            .url(baseUrl(context) + "/api/extract")
            .post(body)
            .build()
        client.newCall(request).execute().use { response ->
            val json = readJson(response)
            return Meta(
                title = json.optString("title").ifBlank { "Untitled" },
                platform = json.optString("platform").ifBlank { "Public source" },
                thumbnail = json.optString("thumbnail").ifBlank { null },
                videoQualities = readFormats(json.optJSONArray("qualities")),
                audioQualities = readFormats(json.optJSONArray("audio_formats")),
            )
        }
    }

    fun startDownload(
        context: Context,
        url: String,
        type: String,
        quality: String,
    ): String {
        val body = SessionStore.attach(
            context,
            url,
            JSONObject()
                .put("url", url)
                .put("type", type)
                .put("quality", quality)
                .put("removeMusic", false)
                .put("premiumNoWatermark", true),
        ).toString().toRequestBody(JSON)
        val request = Request.Builder()
            .url(baseUrl(context) + "/api/download")
            .post(body)
            .build()
        client.newCall(request).execute().use { response ->
            val id = readJson(response).optString("downloadId")
            if (id.isBlank()) throw IllegalStateException("Backend did not return a download id.")
            return id
        }
    }

    data class Update(
        val status: String,
        val progress: Int,
        val fileUrl: String?,
        val filename: String?,
        val error: String?,
    )

    /**
     * Opens the progress socket for one download.
     *
     * [onUpdate] is called on OkHttp's dispatcher thread, never the main
     * thread. Returns the socket so the caller can cancel it.
     */
    fun watch(
        context: Context,
        id: String,
        onUpdate: (Update) -> Unit,
        onClosed: (String?) -> Unit,
    ): WebSocket {
        val base = baseUrl(context)
        val wsUrl = base
            .replaceFirst("https://", "wss://")
            .replaceFirst("http://", "ws://") + "/ws/download/$id"
        val request = Request.Builder().url(wsUrl).build()
        return client.newWebSocket(request, object : WebSocketListener() {
            override fun onMessage(webSocket: WebSocket, text: String) {
                val update = try {
                    val json = JSONObject(text)
                    Update(
                        status = json.optString("status").ifBlank { "queued" },
                        progress = json.optInt("progress", 0),
                        fileUrl = json.optString("fileUrl").ifBlank { null },
                        filename = json.optString("filename").ifBlank { null },
                        error = json.optString("error").ifBlank { null },
                    )
                } catch (error: Exception) {
                    Update("failed", 0, null, null, "Unreadable update from the server.")
                }
                onUpdate(update)
            }

            override fun onFailure(webSocket: WebSocket, t: Throwable, response: Response?) {
                onClosed(t.message ?: "Connection to the download server failed.")
            }

            override fun onClosed(webSocket: WebSocket, code: Int, reason: String) {
                onClosed(null)
            }
        })
    }

    private fun readFormats(array: org.json.JSONArray?): List<Format> {
        if (array == null) return emptyList()
        val out = ArrayList<Format>(array.length())
        for (i in 0 until array.length()) {
            val item = array.optJSONObject(i) ?: continue
            val label = item.optString("label").ifBlank { "Best" }
            out.add(
                Format(
                    id = item.optString("id").ifBlank { label },
                    label = label,
                    height = if (item.isNull("height")) null else item.optInt("height"),
                )
            )
        }
        return out
    }

    private fun readJson(response: Response): JSONObject {
        val text = response.body?.string().orEmpty()
        if (!response.isSuccessful) {
            // The backend reports its own failures in `detail`; surfacing that
            // beats "HTTP 500" when the real answer is "this post is private".
            val detail = try {
                JSONObject(text).optString("detail")
            } catch (_: Exception) {
                ""
            }
            throw IllegalStateException(
                detail.ifBlank { "The download server refused this link (${response.code})." }
            )
        }
        return if (text.isBlank()) JSONObject() else JSONObject(text)
    }
}
