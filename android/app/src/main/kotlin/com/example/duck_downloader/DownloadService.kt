package com.example.duck_downloader

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import okhttp3.Request
import okhttp3.WebSocket
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger

/**
 * Runs shared-link downloads with the app closed.
 *
 * A share is started from another app's screen and the user goes straight back
 * to scrolling, so nothing about this can depend on Duck being in the
 * foreground. A foreground service is the only thing Android guarantees will
 * keep running, which is also what makes the notification mandatory rather
 * than decorative — it is the user's only handle on work they cannot see.
 *
 * Concurrency is capped at [MAX_CONCURRENT]. Before this existed, a shared
 * playlist fired every item at the backend at once.
 */
class DownloadService : Service() {

    companion object {
        const val ACTION_ENQUEUE = "com.example.duck_downloader.ENQUEUE"
        const val ACTION_CANCEL_ALL = "com.example.duck_downloader.CANCEL_ALL"

        /**
         * Keeps the process alive for downloads Dart is running itself.
         *
         * In-app downloads live in the Flutter isolate, and Android is free to
         * freeze that the moment the user leaves for WhatsApp — which is
         * exactly when a long download dies. A foreground service keeps the
         * whole process running, so the isolate keeps its sockets. Dart owns
         * the transfer; this owns the notification and the right to survive.
         */
        const val ACTION_KEEP_ALIVE = "com.example.duck_downloader.KEEP_ALIVE"
        const val ACTION_STOP_KEEP_ALIVE = "com.example.duck_downloader.STOP_KEEP_ALIVE"

        private const val CHANNEL_PROGRESS = "duck_downloads"
        private const val CHANNEL_DONE = "duck_downloads_done"
        private const val NOTIFICATION_ID = 4801

        /**
         * How many downloads actually run at once.
         *
         * Three is the number every mainstream downloader settles on: enough
         * that a playlist does not crawl, few enough that a phone on mobile
         * data is not starving every stream it started.
         */
        const val MAX_CONCURRENT = 3

        /// Where finished downloads wait for the app to pick them up.
        const val INBOX_KEY = "shareInbox"

        /**
         * Starts a share download.
         *
         * Must be called while the calling activity is still on screen.
         * Android 12 refuses `startForegroundService` from the background, and
         * ShareActivity finishes the moment its sheet is dismissed — so asking
         * the backend for a download id first and starting the service after
         * put the service start on the wrong side of that line. Every share on
         * Android 12+ was silently refused while the toast said the download
         * had begun.
         *
         * The network call moved inside the service for the same reason: the
         * service is what has to be alive for it, not the sheet.
         */
        fun enqueue(
            context: Context,
            url: String,
            title: String,
            thumbnail: String?,
            platform: String,
            type: String,
            quality: String,
        ) {
            val intent = Intent(context, DownloadService::class.java).apply {
                action = ACTION_ENQUEUE
                putExtra("url", url)
                putExtra("title", title)
                putExtra("thumbnail", thumbnail)
                putExtra("platform", platform)
                putExtra("type", type)
                putExtra("quality", quality)
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }
    }

    private val pool = Executors.newFixedThreadPool(MAX_CONCURRENT)
    private val sockets = ConcurrentHashMap<String, WebSocket>()
    private val titles = ConcurrentHashMap<String, String>()
    private val percents = ConcurrentHashMap<String, Int>()
    private val queued = AtomicInteger(0)
    private val finished = AtomicInteger(0)
    @Volatile private var cancelled = false

    /// Dart's own queue, mirrored for the notification. Null when Dart has
    /// nothing running.
    @Volatile private var appSide: AppSideProgress? = null

    private data class AppSideProgress(
        val title: String,
        val percent: Int,
        val running: Int,
        val total: Int,
    )

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        createChannels()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_CANCEL_ALL -> {
                cancelEverything()
                return START_NOT_STICKY
            }
            ACTION_KEEP_ALIVE -> {
                appSide = AppSideProgress(
                    title = intent.getStringExtra("title") ?: "Duck Downloader",
                    percent = intent.getIntExtra("percent", 0),
                    running = intent.getIntExtra("running", 1),
                    total = intent.getIntExtra("total", 1),
                )
                goForeground()
                return START_NOT_STICKY
            }
            ACTION_STOP_KEEP_ALIVE -> {
                appSide = null
                maybeStop()
                return START_NOT_STICKY
            }
            ACTION_ENQUEUE -> Unit
            else -> {
                // Nothing to do and no work in flight: never sit in the
                // foreground holding a notification over an empty queue.
                maybeStop()
                return START_NOT_STICKY
            }
        }

        val url = intent.getStringExtra("url")
        if (url.isNullOrBlank()) return START_NOT_STICKY
        val title = intent.getStringExtra("title") ?: "Download"

        // A key for the notification and the maps until the backend gives us
        // its own id. The two are swapped once the job is accepted.
        val localId = "local-" + System.nanoTime()

        // Promote before any work starts. Android gives a service a few seconds
        // from startForegroundService to call this, and killing us for missing
        // it would take the download with it.
        titles[localId] = title
        percents[localId] = 0
        queued.incrementAndGet()
        goForeground()

        val thumbnail = intent.getStringExtra("thumbnail")
        val platform = intent.getStringExtra("platform") ?: "Public source"
        val type = intent.getStringExtra("type") ?: "video"
        val quality = intent.getStringExtra("quality") ?: "Best"

        pool.execute {
            var backendId: String? = null
            try {
                // Asking the backend from here rather than from the sheet is
                // what keeps the service start legal on Android 12+.
                val accepted = DuckShareApi.startDownload(this, url, type, quality)
                backendId = accepted
                titles[accepted] = title
                percents[accepted] = percents.remove(localId) ?: 0
                titles.remove(localId)
                runDownload(accepted, url, title, thumbnail, platform, type, quality)
            } catch (error: Exception) {
                recordFailure(backendId ?: localId, url, title, platform, type, error.message)
            } finally {
                val key = backendId ?: localId
                sockets.remove(key)
                percents.remove(key)
                titles.remove(key)
                finished.incrementAndGet()
                if (queued.get() == finished.get()) {
                    maybeStop()
                } else {
                    goForeground()
                }
            }
        }
        return START_NOT_STICKY
    }

    /**
     * Waits on the backend, then pulls the finished file down and publishes it.
     *
     * Blocking this pool thread on the latch is deliberate: it is what makes
     * [MAX_CONCURRENT] mean anything. A non-blocking version would start every
     * socket immediately and the cap would be decorative.
     */
    private fun runDownload(
        downloadId: String,
        url: String,
        title: String,
        thumbnail: String?,
        platform: String,
        type: String,
        quality: String,
    ) {
        val latch = CountDownLatch(1)
        // fileUrl, filename, failure. A plain array because the socket
        // callbacks run on OkHttp's thread and this one reads it after the
        // latch — the latch is the happens-before edge, so no lock is needed.
        val holder = arrayOfNulls<String>(3)

        val socket = DuckShareApi.watch(
            this,
            downloadId,
            onUpdate = { update ->
                percents[downloadId] = update.progress.coerceIn(0, 100)
                goForeground()
                when (update.status) {
                    "completed" -> {
                        holder[0] = update.fileUrl
                        holder[1] = update.filename
                        latch.countDown()
                    }
                    "failed", "cancelled" -> {
                        holder[2] = update.error ?: "The download did not finish."
                        latch.countDown()
                    }
                }
            },
            onClosed = { error ->
                // A clean close before a terminal status still ends the wait —
                // otherwise the thread parks here until the timeout for a
                // download the server already forgot about.
                if (holder[0] == null && holder[2] == null) {
                    holder[2] = error ?: "The download server closed the connection."
                }
                latch.countDown()
            },
        )
        sockets[downloadId] = socket

        // A ceiling, not an expectation: a long video on a slow backend is
        // normal, a socket that never speaks again is not.
        if (!latch.await(2, TimeUnit.HOURS)) {
            holder[2] = "The download timed out."
        }
        socket.cancel()
        sockets.remove(downloadId)

        if (cancelled) return
        holder[2]?.let { throw IllegalStateException(it) }

        val remote = holder[0] ?: throw IllegalStateException("The server did not return a file.")
        val safeName = sanitize(holder[1] ?: "$title.${extensionFor(type)}")
        val local = fetchToCache(DuckShareApi.absoluteFileUrl(this, remote), safeName)

        val kind = when (type) {
            "audio" -> MediaSaver.Kind.AUDIO
            "image" -> MediaSaver.Kind.IMAGE
            else -> MediaSaver.Kind.VIDEO
        }
        MediaSaver.save(this, local.absolutePath, safeName, mimeFor(type), kind)

        recordSuccess(downloadId, url, title, thumbnail, platform, type, quality, local.absolutePath)
        notifyDone(title, true)
    }

    private fun fetchToCache(fileUrl: String, filename: String): File {
        val request = Request.Builder().url(fileUrl).build()
        // No read timeout on the body: this is the transfer itself, and a
        // 400MB video over a weak signal legitimately outlasts any ceiling
        // that would be sane for a JSON call.
        val call = DuckShareApi.client
            .newBuilder()
            .readTimeout(0, TimeUnit.MILLISECONDS)
            .build()
            .newCall(request)
        call.execute().use { response ->
            if (!response.isSuccessful) {
                throw IllegalStateException("Could not fetch the finished file (${response.code}).")
            }
            val target = File(cacheDir, "share_${System.currentTimeMillis()}_$filename")
            response.body?.byteStream()?.use { input ->
                target.outputStream().use { output -> input.copyTo(output) }
            } ?: throw IllegalStateException("The finished file was empty.")
            return target
        }
    }

    // ---- The inbox the app drains on next launch ------------------------------

    /**
     * Records the download where Dart can find it.
     *
     * The service cannot write to the app's Hive box — Hive is not safe to
     * open from two places, and the app may well be running. So finished
     * shares land in SharedPreferences and `DownloadsController` folds them
     * into the library the next time it starts or resumes.
     */
    private fun appendToInbox(entry: JSONObject) {
        val prefs = getSharedPreferences(DuckShareApi.PREFS, Context.MODE_PRIVATE)
        synchronized(DownloadService::class.java) {
            val existing = prefs.getString(INBOX_KEY, "[]").orEmpty()
            val array = try {
                JSONArray(existing)
            } catch (_: Exception) {
                JSONArray()
            }
            array.put(entry)
            prefs.edit().putString(INBOX_KEY, array.toString()).apply()
        }
    }

    private fun recordSuccess(
        downloadId: String,
        url: String,
        title: String,
        thumbnail: String?,
        platform: String,
        type: String,
        quality: String,
        filePath: String,
    ) {
        appendToInbox(
            JSONObject()
                .put("id", downloadId)
                .put("url", url)
                .put("title", title)
                .put("thumbnail", thumbnail ?: JSONObject.NULL)
                .put("platform", platform)
                .put("type", type)
                .put("quality", quality)
                .put("filePath", filePath)
                .put("status", "completed")
                .put("createdAt", System.currentTimeMillis())
        )
    }

    private fun recordFailure(
        downloadId: String,
        url: String,
        title: String,
        platform: String,
        type: String,
        error: String?,
    ) {
        if (cancelled) return
        appendToInbox(
            JSONObject()
                .put("id", downloadId)
                .put("url", url)
                .put("title", title)
                .put("thumbnail", JSONObject.NULL)
                .put("platform", platform)
                .put("type", type)
                .put("quality", "")
                .put("filePath", JSONObject.NULL)
                .put("status", "failed")
                .put("error", error ?: "The download failed.")
                .put("createdAt", System.currentTimeMillis())
        )
        notifyDone(title, false)
    }

    // ---- Notifications --------------------------------------------------------

    private fun createChannels() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val manager = getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_PROGRESS,
                "Downloads",
                // Low: an ongoing progress bar must never make a sound or push
                // itself in front of what the user is doing.
                NotificationManager.IMPORTANCE_LOW,
            ).apply { setShowBadge(false) }
        )
        manager.createNotificationChannel(
            NotificationChannel(
                CHANNEL_DONE,
                "Finished downloads",
                NotificationManager.IMPORTANCE_DEFAULT,
            )
        )
    }

    private fun goForeground() {
        val notification = buildProgressNotification()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun buildProgressNotification(): Notification {
        // Native shares take the notification when there are any; otherwise it
        // reports whatever Dart's own queue is doing. They are never both busy
        // in practice — a share downloads in the service precisely because the
        // app is not open.
        appSide?.let { app ->
            if (queued.get() == finished.get()) return buildAppSideNotification(app)
        }
        val active = percents.size
        val total = queued.get()
        val done = finished.get()
        // One overall bar rather than one notification per file: five separate
        // progress rows is what makes a downloader feel like spam.
        val overall = if (total == 0) 0 else {
            val inFlight = percents.values.sum()
            ((done * 100 + inFlight) / total).coerceIn(0, 100)
        }
        val heading = titles.values.firstOrNull() ?: "Duck Downloader"
        val text = if (total > 1) {
            "${done + 1} of $total · $overall%"
        } else {
            "$overall%"
        }

        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val cancel = PendingIntent.getService(
            this,
            1,
            Intent(this, DownloadService::class.java).setAction(ACTION_CANCEL_ALL),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

        return NotificationCompat.Builder(this, CHANNEL_PROGRESS)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(heading)
            .setContentText(text)
            .setProgress(100, overall, active == 0)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(open)
            .addAction(0, "Cancel", cancel)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    private fun buildAppSideNotification(app: AppSideProgress): Notification {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val text = if (app.total > 1) {
            "${app.running} of ${app.total} · ${app.percent}%"
        } else {
            "${app.percent}%"
        }
        return NotificationCompat.Builder(this, CHANNEL_PROGRESS)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(app.title)
            .setContentText(text)
            .setProgress(100, app.percent, false)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
            .setContentIntent(open)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    private fun notifyDone(title: String, success: Boolean) {
        val open = PendingIntent.getActivity(
            this,
            2,
            Intent(this, MainActivity::class.java).apply {
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val notification = NotificationCompat.Builder(this, CHANNEL_DONE)
            .setSmallIcon(R.drawable.ic_notification)
            .setContentTitle(if (success) "Download finished" else "Download failed")
            .setContentText(title)
            .setAutoCancel(true)
            .setContentIntent(open)
            .build()
        getSystemService(NotificationManager::class.java)
            .notify(title.hashCode(), notification)
    }

    // ---- Teardown -------------------------------------------------------------

    private fun cancelEverything() {
        cancelled = true
        appSide = null
        sockets.values.forEach { it.cancel() }
        sockets.clear()
        percents.clear()
        titles.clear()
        pool.shutdownNow()
        stopForegroundAndSelf()
    }

    /**
     * Stops only when nothing needs us any more.
     *
     * Two independent producers can hold this service up: shares it is
     * downloading itself, and Dart asking to stay alive. Stopping while either
     * is live would kill the very work the service exists for.
     */
    private fun maybeStop() {
        val nativeBusy = queued.get() > finished.get()
        if (nativeBusy || appSide != null) {
            goForeground()
            return
        }
        stopForegroundAndSelf()
    }

    private fun stopForegroundAndSelf() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        stopSelf()
    }

    override fun onDestroy() {
        sockets.values.forEach { it.cancel() }
        pool.shutdownNow()
        super.onDestroy()
    }

    // ---- Helpers --------------------------------------------------------------

    private fun extensionFor(type: String) = when (type) {
        "audio" -> "mp3"
        "image" -> "jpg"
        else -> "mp4"
    }

    private fun mimeFor(type: String) = when (type) {
        "audio" -> "audio/mpeg"
        "image" -> "image/jpeg"
        else -> "video/mp4"
    }

    /// MediaStore rejects a DISPLAY_NAME containing a path separator, and a
    /// shared title routinely contains one.
    private fun sanitize(name: String): String {
        val cleaned = name.replace(Regex("[\\\\/:*?\"<>|\\n\\r]"), "_").trim()
        return if (cleaned.isBlank()) "duck_download" else cleaned.take(120)
    }
}
