package com.example.duck_downloader

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import com.ryanheise.audioservice.AudioServiceFragmentActivity
import com.ryanheise.audioservice.AudioServicePlugin
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream
import android.content.Intent
import android.os.Bundle
import android.app.PendingIntent
import android.app.RemoteAction
import android.content.BroadcastReceiver
import android.content.IntentFilter
import android.graphics.drawable.Icon
import java.util.ArrayList
import android.app.Activity
import android.content.IntentSender
import io.flutter.embedding.android.FlutterFragmentActivity

class MainActivity : AudioServiceFragmentActivity() {
    private val channelName = "duck_downloader/media"
    private var methodChannel: MethodChannel? = null
    private var isVideoPlaying = false

    /**
     * PiP action ids shared with the Dart side.
     *
     * Kept as explicit constants because they travel over the method channel as
     * bare ints; a mismatch here silently maps "next" onto "pause".
     */
    private object PipAction {
        const val PLAY = 1
        const val PAUSE = 2
        const val NEXT = 3
        const val PREVIOUS = 4
    }

    private var hasNextVideo = false
    private var hasPreviousVideo = false

    /**
     * Screen on/off, reported straight to Dart.
     *
     * Locking the phone and leaving the app look identical to Flutter's
     * lifecycle callbacks, which is why the player used to wait 350ms hoping
     * onUserLeaveHint would fire first. The system tells us precisely which one
     * happened, so the handoff can start on the same frame instead.
     */
    private val screenReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            when (intent?.action) {
                Intent.ACTION_SCREEN_OFF ->
                    methodChannel?.invokeMethod("screenOff", null)
                Intent.ACTION_USER_PRESENT ->
                    methodChannel?.invokeMethod("screenOn", null)
            }
        }
    }

    private val pipReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
            if (intent == null) return
            val action = intent.action
            if ("ACTION_MEDIA_CONTROL" == action) {
                val controlType = intent.getIntExtra("CONTROL_TYPE", 0)
                methodChannel?.invokeMethod("pipAction", controlType)
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            registerReceiver(pipReceiver, IntentFilter("ACTION_MEDIA_CONTROL"), RECEIVER_NOT_EXPORTED)
        } else {
            registerReceiver(pipReceiver, IntentFilter("ACTION_MEDIA_CONTROL"))
        }
        // Screen on/off are protected system broadcasts, so they must stay
        // exported-by-default; they cannot be received via a manifest entry.
        registerReceiver(
            screenReceiver,
            IntentFilter().apply {
                addAction(Intent.ACTION_SCREEN_OFF)
                addAction(Intent.ACTION_USER_PRESENT)
            },
        )
    }

    /**
     * A share arriving while the app is already running.
     *
     * `setIntent` has to happen before `super`: the share plugin reads
     * `getIntent()` when it is notified, and doing it the other way round left
     * it looking at the intent from the previous launch. This override used to
     * call `setIntent` and stop there, so a link shared into a running app did
     * nothing at all — no sheet, no download, no error.
     */
    override fun onNewIntent(intent: Intent) {
        setIntent(intent)
        super.onNewIntent(intent)
    }

    override fun provideFlutterEngine(context: Context): FlutterEngine? {
        return AudioServicePlugin.getFlutterEngine(context)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
        methodChannel = channel
        channel.setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    // Keeps the native side pointed at the same backend the
                    // Dart side resolved, including a --dart-define override.
                    // Without this the share sheet would talk to whatever URL
                    // was compiled into DuckShareApi months ago.
                    // Dart's own downloads run in the Flutter isolate, which
                    // Android freezes once the app is backgrounded. The service
                    // keeps the process — and therefore those transfers — alive.
                    "keepDownloadsAlive" -> {
                        val intent = Intent(this, DownloadService::class.java).apply {
                            action = DownloadService.ACTION_KEEP_ALIVE
                            putExtra("title", call.argument<String>("title"))
                            putExtra("percent", call.argument<Int>("percent") ?: 0)
                            putExtra("running", call.argument<Int>("running") ?: 1)
                            putExtra("total", call.argument<Int>("total") ?: 1)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(true)
                    }
                    "releaseDownloadsAlive" -> {
                        startService(
                            Intent(this, DownloadService::class.java)
                                .setAction(DownloadService.ACTION_STOP_KEEP_ALIVE)
                        )
                        result.success(true)
                    }
                    "syncShareConfig" -> {
                        val baseUrl = call.argument<String>("apiBaseUrl")
                        getSharedPreferences(DuckShareApi.PREFS, Context.MODE_PRIVATE)
                            .edit()
                            .putString("apiBaseUrl", baseUrl)
                            .apply()
                        result.success(true)
                    }
                    // Hands over everything DownloadService finished while the
                    // app was closed, and clears it in the same breath so a
                    // download cannot be added to the library twice.
                    "drainShareInbox" -> {
                        val prefs = getSharedPreferences(DuckShareApi.PREFS, Context.MODE_PRIVATE)
                        val payload = prefs.getString(DownloadService.INBOX_KEY, "[]") ?: "[]"
                        prefs.edit().remove(DownloadService.INBOX_KEY).apply()
                        result.success(payload)
                    }
                    "saveVideo", "saveAudioToMusic" -> {
                        val path = call.argument<String>("path")
                        val filename = call.argument<String>("filename")
                        val mimeType = call.argument<String>("mimeType")
                        if (path.isNullOrBlank() || filename.isNullOrBlank() || mimeType.isNullOrBlank()) {
                            result.error("invalid_args", "Missing path, filename, or mimeType.", null)
                            return@setMethodCallHandler
                        }
                        if (call.method == "saveVideo") {
                            result.success(saveMedia(path, filename, mimeType, true))
                        } else {
                            result.success(saveMedia(path, filename, mimeType, false))
                        }
                    }
                    "saveImage" -> {
                        val path = call.argument<String>("path")
                        val filename = call.argument<String>("filename")
                        val mimeType = call.argument<String>("mimeType")
                        if (path.isNullOrBlank() || filename.isNullOrBlank() || mimeType.isNullOrBlank()) {
                            result.error("invalid_args", "Missing path, filename, or mimeType.", null)
                            return@setMethodCallHandler
                        }
                        result.success(saveImageMedia(path, filename, mimeType))
                    }
                    "enterPiP" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            try {
                                val success =
                                    enterPictureInPictureMode(buildPiPParams(isVideoPlaying))
                                result.success(success)
                            } catch (e: Exception) {
                                result.error("pip_error", e.message, null)
                            }
                        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                            @Suppress("DEPRECATION")
                            enterPictureInPictureMode()
                            result.success(true)
                        } else {
                            result.error("pip_not_supported", "Android version does not support PiP.", null)
                        }
                    }
                    "isInPiP" -> {
                        val inPiP = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                            isInPictureInPictureMode
                        } else {
                            false
                        }
                        result.success(inPiP)
                    }
                    "renameDeviceMedia" -> {
                        val path = call.argument<String>("path")
                        val newName = call.argument<String>("newName")
                        if (path.isNullOrBlank() || newName.isNullOrBlank()) {
                            result.error("invalid_args", "Missing path or newName.", null)
                            return@setMethodCallHandler
                        }
                        renameDeviceMedia(path, newName, result)
                    }
                    "deleteDeviceMedia" -> {
                        val paths = call.argument<List<String>>("paths")
                        if (paths.isNullOrEmpty()) {
                            result.error("invalid_args", "Missing paths.", null)
                            return@setMethodCallHandler
                        }
                        deleteDeviceMedia(paths, result)
                    }
                    "requestMediaWriteAccess" -> {
                        val paths = call.argument<List<String>>("paths") ?: emptyList()
                        requestMediaWriteAccess(paths, result)
                    }
                    "queryDeviceMedia" -> {
                        // Runs off the main thread: the query itself is fast,
                        // but a library with tens of thousands of rows still
                        // takes long enough to drop frames.
                        Thread {
                            val rows = runCatching { queryDeviceMedia() }
                            runOnUiThread {
                                rows.fold(
                                    onSuccess = { result.success(it) },
                                    onFailure = {
                                        result.error(
                                            "query_failed",
                                            it.message ?: "Could not read the media library.",
                                            null,
                                        )
                                    },
                                )
                            }
                        }.start()
                    }
                    "moveDeviceMedia" -> {
                        val paths = call.argument<List<String>>("paths")
                        val target = call.argument<String>("targetFolder")
                        if (paths.isNullOrEmpty() || target.isNullOrBlank()) {
                            result.error("invalid_args", "Missing paths or targetFolder.", null)
                            return@setMethodCallHandler
                        }
                        moveDeviceMedia(paths, target, result)
                    }
                    "updateDeviceMediaTags" -> {
                        val path = call.argument<String>("path")
                        if (path.isNullOrBlank()) {
                            result.error("invalid_args", "Missing path.", null)
                            return@setMethodCallHandler
                        }
                        updateDeviceMediaTags(
                            path,
                            mapOf(
                                "title" to call.argument<String>("title"),
                                "artist" to call.argument<String>("artist"),
                                "album" to call.argument<String>("album"),
                            ),
                            result,
                        )
                    }
                    "setVideoQueueState" -> {
                        hasNextVideo = call.argument<Boolean>("hasNext") ?: false
                        hasPreviousVideo = call.argument<Boolean>("hasPrevious") ?: false
                        updatePiPParams(isVideoPlaying)
                        result.success(null)
                    }
                    "setVideoPlaying" -> {
                        isVideoPlaying = call.argument<Boolean>("playing") ?: false
                        updatePiPParams(isVideoPlaying)
                        result.success(null)
                    }
                    "canWriteSettings" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            result.success(android.provider.Settings.System.canWrite(this))
                        } else {
                            result.success(true)
                        }
                    }
                    "requestWriteSettingsPermission" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                            val intent = Intent(android.provider.Settings.ACTION_MANAGE_WRITE_SETTINGS).apply {
                                data = Uri.parse("package:$packageName")
                                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                            }
                            startActivity(intent)
                        }
                        result.success(true)
                    }
                    "setRingtone" -> {
                        val path = call.argument<String>("path")
                        val title = call.argument<String>("title")
                        if (path.isNullOrBlank() || title.isNullOrBlank()) {
                            result.error("invalid_args", "Missing path or title.", null)
                            return@setMethodCallHandler
                        }
                        val file = File(path)
                        if (!file.exists()) {
                            result.error("file_not_found", "Audio file does not exist.", null)
                            return@setMethodCallHandler
                        }
                        result.success(setSystemRingtone(file, title))
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("failed", error.message ?: "Operation failed.", null)
            }
        }
    }

    /** Builds one PiP control, greyed out when the queue cannot go that way. */
    @android.annotation.TargetApi(Build.VERSION_CODES.O)
    private fun pipAction(
        controlType: Int,
        iconId: Int,
        title: String,
        enabled: Boolean = true,
    ): RemoteAction {
        val intent = Intent("ACTION_MEDIA_CONTROL")
            .setPackage(packageName)
            .putExtra("CONTROL_TYPE", controlType)
        val pendingIntent = PendingIntent.getBroadcast(
            this,
            controlType,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return RemoteAction(
            Icon.createWithResource(this, iconId),
            title,
            title,
            pendingIntent,
        ).apply { isEnabled = enabled }
    }

    /**
     * Previous / Play-Pause / Next, in the order Android renders them.
     *
     * Three is the count every launcher guarantees
     * (`maxNumPictureInPictureActions`), so the set is capped there rather than
     * risking silently dropped controls.
     */
    @android.annotation.TargetApi(Build.VERSION_CODES.O)
    private fun buildPiPParams(playing: Boolean): android.app.PictureInPictureParams {
        val actions = ArrayList<RemoteAction>()
        actions.add(
            pipAction(
                PipAction.PREVIOUS,
                android.R.drawable.ic_media_previous,
                "Previous",
                enabled = hasPreviousVideo,
            ),
        )
        actions.add(
            if (playing) {
                pipAction(PipAction.PAUSE, android.R.drawable.ic_media_pause, "Pause")
            } else {
                pipAction(PipAction.PLAY, android.R.drawable.ic_media_play, "Play")
            },
        )
        actions.add(
            pipAction(
                PipAction.NEXT,
                android.R.drawable.ic_media_next,
                "Next",
                enabled = hasNextVideo,
            ),
        )

        val builder = android.app.PictureInPictureParams.Builder().setActions(actions)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            // Lets the system animate straight into PiP as the user swipes
            // home, instead of the window appearing after the gesture finishes.
            builder.setAutoEnterEnabled(playing)
            builder.setSeamlessResizeEnabled(true)
        }
        return builder.build()
    }

    private fun updatePiPParams(playing: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            setPictureInPictureParams(buildPiPParams(playing))
        }
    }

    override fun onDestroy() {
        try {
            unregisterReceiver(screenReceiver)
        } catch (e: Exception) {
            // Never registered.
        }
        try {
            unregisterReceiver(pipReceiver)
        } catch (e: Exception) {
            // Ignore
        }
        super.onDestroy()
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (!isVideoPlaying) return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                val inPiP = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) isInPictureInPictureMode else false
                if (!inPiP) {
                    // Tell Dart *before* entering, so the player knows this is
                    // "left the app" and skips the background-audio handoff it
                    // would otherwise start off the lifecycle event.
                    methodChannel?.invokeMethod("enteringPip", null)
                    enterPictureInPictureMode(buildPiPParams(true))
                }
            } catch (e: Exception) {
                // Ignore
            }
        } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            @Suppress("DEPRECATION")
            enterPictureInPictureMode()
        }
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: android.content.res.Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        methodChannel?.invokeMethod("pipModeChanged", isInPictureInPictureMode)

        if (!isInPictureInPictureMode) {
            // Leaving PiP means one of two things: the user tapped the window
            // to come back (activity resumes), or they dismissed it with the X
            // (activity stops). Only the second should keep playing as audio,
            // and the lifecycle state is what separates them.
            val dismissed = !lifecycle.currentState.isAtLeast(
                androidx.lifecycle.Lifecycle.State.STARTED,
            )
            if (dismissed) {
                methodChannel?.invokeMethod("pipDismissed", null)
            }
        }
    }

    private fun saveMedia(
        sourcePath: String,
        filename: String,
        mimeType: String,
        video: Boolean,
    ): Map<String, Any?> = MediaSaver.save(
        this,
        sourcePath,
        filename,
        mimeType,
        if (video) MediaSaver.Kind.VIDEO else MediaSaver.Kind.AUDIO,
    )

    private fun saveImageMedia(
        sourcePath: String,
        filename: String,
        mimeType: String,
    ): Map<String, Any?> = MediaSaver.save(
        this,
        sourcePath,
        filename,
        mimeType,
        MediaSaver.Kind.IMAGE,
    )

    private fun setSystemRingtone(file: File, title: String): Boolean {
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M && !android.provider.Settings.System.canWrite(this)) {
                return false
            }

            val resolver = applicationContext.contentResolver
            val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            } else {
                MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
            }

            try {
                resolver.delete(collection, "${MediaStore.Audio.Media.TITLE} = ?", arrayOf(title))
            } catch (_: Exception) {}

            val ringtoneUri = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                publishRingtoneScoped(resolver, collection, file, title)
            } else {
                publishRingtoneLegacy(resolver, collection, file, title)
            } ?: return false

            android.media.RingtoneManager.setActualDefaultRingtoneUri(
                applicationContext,
                android.media.RingtoneManager.TYPE_RINGTONE,
                ringtoneUri
            )
            true
        } catch (e: Exception) {
            e.printStackTrace()
            false
        }
    }

    /**
     * Publishes the clip into the shared Ringtones collection and returns its URI.
     *
     * Android 10 changed two things that quietly broke ringtone registration:
     * `MediaStore.MediaColumns.DATA` became read-only on insert, and an app's
     * own external files directory stopped being readable by other processes.
     * Writing the clip to `getExternalFilesDir(DIRECTORY_RINGTONES)` and
     * handing telephony a path into it therefore produced a row the ringtone
     * picker could see but never play — "Ringtone set successfully" with
     * silence on the next call.
     *
     * The supported route is to insert a pending row with a RELATIVE_PATH under
     * the shared Ringtones folder, stream the bytes through the resolver, then
     * clear IS_PENDING — the same shape the video and music saves already use.
     */
    private fun publishRingtoneScoped(
        resolver: android.content.ContentResolver,
        collection: Uri,
        file: File,
        title: String,
    ): Uri? {
        val displayName = "${file.nameWithoutExtension}.mp3"
        val relativePath = Environment.DIRECTORY_RINGTONES + "/Duck Downloader"

        // Drop any previous copy so repeated taps do not stack up duplicates.
        try {
            resolver.delete(
                collection,
                "${MediaStore.MediaColumns.RELATIVE_PATH} = ? AND ${MediaStore.MediaColumns.DISPLAY_NAME} = ?",
                arrayOf("$relativePath/", displayName),
            )
        } catch (_: Exception) {}

        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, displayName)
            put(MediaStore.Audio.Media.TITLE, title)
            put(MediaStore.MediaColumns.MIME_TYPE, "audio/mpeg")
            put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
            put(MediaStore.Audio.Media.IS_RINGTONE, true)
            put(MediaStore.Audio.Media.IS_NOTIFICATION, false)
            put(MediaStore.Audio.Media.IS_ALARM, false)
            put(MediaStore.Audio.Media.IS_MUSIC, false)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }

        val uri = resolver.insert(collection, values) ?: return null
        try {
            resolver.openOutputStream(uri)?.use { output ->
                FileInputStream(file).use { input -> input.copyTo(output) }
            } ?: return null
        } catch (e: Exception) {
            resolver.delete(uri, null, null)
            throw e
        }

        values.clear()
        values.put(MediaStore.MediaColumns.IS_PENDING, 0)
        resolver.update(uri, values, null, null)
        return uri
    }

    /** Pre-Q devices can still point the ringtone at a real filesystem path. */
    private fun publishRingtoneLegacy(
        resolver: android.content.ContentResolver,
        collection: Uri,
        file: File,
        title: String,
    ): Uri? {
        val directory = Environment.getExternalStoragePublicDirectory(
            Environment.DIRECTORY_RINGTONES,
        ).resolve("Duck Downloader")
        directory.mkdirs()
        val target = directory.resolve("${file.nameWithoutExtension}.mp3")
        file.copyTo(target, overwrite = true)

        try {
            resolver.delete(
                collection,
                "${MediaStore.MediaColumns.DATA} = ?",
                arrayOf(target.absolutePath),
            )
        } catch (_: Exception) {}

        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DATA, target.absolutePath)
            put(MediaStore.Audio.Media.TITLE, title)
            put(MediaStore.MediaColumns.SIZE, target.length())
            put(MediaStore.MediaColumns.MIME_TYPE, "audio/mpeg")
            put(MediaStore.Audio.Media.IS_RINGTONE, true)
            put(MediaStore.Audio.Media.IS_NOTIFICATION, false)
            put(MediaStore.Audio.Media.IS_ALARM, false)
            put(MediaStore.Audio.Media.IS_MUSIC, false)
        }
        return resolver.insert(collection, values)
    }

    // ── Reading the user's media library ────────────────────────────────────
    //
    // This replaces a recursive filesystem walk over a hardcoded list of
    // folders. That walk was synchronous (so it froze the UI thread), ran once
    // per media type (so three times over), could not see anything outside the
    // hardcoded list, and is largely blocked outright on Android 11+.
    //
    // MediaStore already maintains exactly this index. One query returns every
    // media file with the size, duration and folder the old code had to stat
    // for, and it is the only approach that still works under scoped storage.

    /**
     * Returns every readable media file, newest first.
     *
     * `type` is 1 = image, 2 = video, 3 = audio, matching MediaStore's own
     * MEDIA_TYPE constants so the Dart side can switch on it directly.
     */
    private fun queryDeviceMedia(): List<Map<String, Any?>> {
        val collection = MediaStore.Files.getContentUri(
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                MediaStore.VOLUME_EXTERNAL
            } else {
                "external"
            },
        )

        val projection = mutableListOf(
            MediaStore.MediaColumns._ID,
            MediaStore.MediaColumns.DISPLAY_NAME,
            MediaStore.MediaColumns.DATA,
            MediaStore.MediaColumns.SIZE,
            MediaStore.MediaColumns.MIME_TYPE,
            MediaStore.MediaColumns.DATE_MODIFIED,
            MediaStore.Files.FileColumns.MEDIA_TYPE,
        )
        // BUCKET_* and DURATION only exist on the Files collection from
        // Android 10; asking for them on older releases throws.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            projection += MediaStore.MediaColumns.BUCKET_DISPLAY_NAME
            projection += MediaStore.MediaColumns.DURATION
        }

        val selection = "${MediaStore.Files.FileColumns.MEDIA_TYPE} IN (?, ?, ?)"
        val args = arrayOf(
            MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE.toString(),
            MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO.toString(),
            MediaStore.Files.FileColumns.MEDIA_TYPE_AUDIO.toString(),
        )

        val rows = ArrayList<Map<String, Any?>>()
        contentResolver.query(
            collection,
            projection.toTypedArray(),
            selection,
            args,
            "${MediaStore.MediaColumns.DATE_MODIFIED} DESC",
        )?.use { cursor ->
            val idCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns._ID)
            val nameCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DISPLAY_NAME)
            val dataCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATA)
            val sizeCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.SIZE)
            val mimeCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.MIME_TYPE)
            val dateCol = cursor.getColumnIndexOrThrow(MediaStore.MediaColumns.DATE_MODIFIED)
            val typeCol = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MEDIA_TYPE)
            val bucketCol = cursor.getColumnIndex(MediaStore.MediaColumns.BUCKET_DISPLAY_NAME)
            val durationCol = cursor.getColumnIndex(MediaStore.MediaColumns.DURATION)

            while (cursor.moveToNext()) {
                val path = cursor.getString(dataCol) ?: continue
                val parent = File(path).parentFile
                // Deliberately no File.exists() check here. It was added to
                // skip rows for files that are already gone, but under scoped
                // storage exists() also returns false for files this app may
                // read perfectly well through MediaStore — and on Android 14
                // partial access that is most of the library. The result was
                // an empty browser on exactly the devices that had the most to
                // show. MediaStore's own index is the better authority; a
                // stale row is a far smaller problem than no rows at all.

                val bucket = if (bucketCol >= 0) cursor.getString(bucketCol) else null
                rows += mapOf(
                    "id" to cursor.getLong(idCol),
                    "name" to (cursor.getString(nameCol) ?: File(path).name),
                    "path" to path,
                    "folderPath" to (parent?.absolutePath ?: ""),
                    "folderName" to (bucket ?: parent?.name ?: "Storage"),
                    "size" to cursor.getLong(sizeCol),
                    "mimeType" to cursor.getString(mimeCol),
                    // DATE_MODIFIED is in seconds, unlike every other Android
                    // timestamp; multiplying here keeps the Dart side sane.
                    "modified" to cursor.getLong(dateCol) * 1000L,
                    "type" to cursor.getInt(typeCol),
                    "duration" to if (durationCol >= 0 && !cursor.isNull(durationCol)) {
                        cursor.getLong(durationCol)
                    } else {
                        null
                    },
                )
            }
        }
        android.util.Log.i("DuckMedia", "queryDeviceMedia returned ${rows.size} rows")
        return rows
    }

    // ── Editing the user's own media ────────────────────────────────────────
    //
    // Under scoped storage an app may only modify MediaStore rows it created.
    // Everything else needs the user's explicit, per-item consent: Android 11+
    // exposes that as createWriteRequest / createDeleteRequest, which show a
    // system dialog and return through onActivityResult. Android 10 raises a
    // RecoverableSecurityException carrying the same kind of intent. Below
    // that, a plain file operation is still allowed.

    private var pendingMediaResult: MethodChannel.Result? = null
    private var pendingMediaAction: (() -> Unit)? = null

    private companion object {
        const val REQUEST_MEDIA_WRITE = 9101
        const val REQUEST_MEDIA_DELETE = 9102

        /** How many URIs one consent request may carry. See requestMediaWriteAccess. */
        const val MAX_CONSENT_URIS = 500
    }

    /**
     * Resolves a filesystem path to its MediaStore row.
     *
     * Returns the URI in the collection matching the row's MEDIA_TYPE —
     * images, video or audio — never the generic `files` collection that the
     * lookup itself has to query, because only one of those is usable.
     *
     * This is the whole ballgame for editing, not a tidiness point.
     * MediaStore.createWriteRequest and createDeleteRequest reject a
     * `content://media/external/file/<id>` URI outright with
     * "All requested items must be Media items", so handing them a files URI
     * made every rename, move and delete fail on Android 11 and up — the
     * consent dialog never even appeared. The lookup still queries the files
     * collection, since that is the only one holding all three types at once.
     *
     * Matches on DATA first, then falls back to display name plus parent
     * folder. DATA has been deprecated since Android 10 and is not guaranteed
     * to be populated or to match byte-for-byte (symlinks, differing volume
     * prefixes), and a null here used to quietly degrade the whole operation
     * into a no-op that still reported success.
     */
    private fun mediaUriFor(path: String): Uri? {
        val volume = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.VOLUME_EXTERNAL
        } else {
            "external"
        }
        val files = MediaStore.Files.getContentUri(volume)

        fun collectionFor(mediaType: Int): Uri = when (mediaType) {
            MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE ->
                MediaStore.Images.Media.getContentUri(volume)
            MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO ->
                MediaStore.Video.Media.getContentUri(volume)
            MediaStore.Files.FileColumns.MEDIA_TYPE_AUDIO ->
                MediaStore.Audio.Media.getContentUri(volume)
            // Not a media item, so no consent request will accept it either.
            // Handing back the files URI still lets the pre-Android-11 direct
            // path do its work.
            else -> files
        }

        fun queryFor(selection: String, args: Array<String>): Uri? {
            return try {
                contentResolver.query(
                    files,
                    arrayOf(
                        MediaStore.MediaColumns._ID,
                        MediaStore.Files.FileColumns.MEDIA_TYPE,
                    ),
                    selection,
                    args,
                    null,
                )?.use { cursor ->
                    if (cursor.moveToFirst()) {
                        ContentUris.withAppendedId(
                            collectionFor(cursor.getInt(1)),
                            cursor.getLong(0),
                        )
                    } else {
                        null
                    }
                }
            } catch (error: Exception) {
                // A query the caller has no permission for throws rather than
                // returning empty; treat it as "not resolvable".
                null
            }
        }

        queryFor("${MediaStore.MediaColumns.DATA} = ?", arrayOf(path))?.let { return it }

        val file = File(path)
        val parent = file.parentFile?.name ?: return null
        return queryFor(
            "${MediaStore.MediaColumns.DISPLAY_NAME} = ? AND " +
                "${MediaStore.MediaColumns.DATA} LIKE ?",
            arrayOf(file.name, "%/$parent/${file.name}"),
        )
    }

    /** Reads a row's current DISPLAY_NAME back, or null if it cannot be read. */
    private fun mediaDisplayNameFor(uri: Uri): String? = runCatching {
        contentResolver.query(
            uri,
            arrayOf(MediaStore.MediaColumns.DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { if (it.moveToFirst()) it.getString(0) else null }
    }.getOrNull()

    private fun renameDeviceMedia(path: String, newName: String, result: MethodChannel.Result) {
        // A name carrying a separator would move the file, not rename it, and
        // MediaStore silently reinterprets the trailing segment as RELATIVE_PATH.
        if (newName.isBlank() || newName.contains('/') || newName.contains('\\')) {
            result.error("bad_name", "That name is not valid.", null)
            return
        }

        val source = File(path)
        val target = File(source.parentFile, newName)
        val uri = mediaUriFor(path)

        // Deliberately NOT gated on source.exists() alone. Under scoped storage
        // — and on Android 14 partial access in particular — File.exists()
        // answers false for files this app can still read and rename perfectly
        // well through MediaStore. The identical check on the query path was
        // emptying the entire browser, and here it was refusing every rename
        // with "That file no longer exists". A row in the library is proof
        // enough that the file is there.
        if (uri == null && !source.exists()) {
            result.error("missing_file", "That file is not in the media library.", null)
            return
        }
        if (target.exists() || mediaUriFor(target.absolutePath) != null) {
            result.error("name_taken", "A file with that name already exists.", null)
            return
        }

        val apply = {
            val renamed = if (uri != null) {
                val values = ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, newName)
                }
                contentResolver.update(uri, values, null, null)
                // The updated-row count is not trustworthy here: some providers
                // report 0 for a write they did perform, and MediaStore may
                // uniquify the name to "foo (1).mp4" rather than fail. Read the
                // row back and let the actual stored name be the answer — Dart
                // re-reads the folder afterwards, so whatever it landed on is
                // what the user sees.
                mediaDisplayNameFor(uri) != source.name
            } else {
                source.renameTo(target)
            }

            MediaScannerConnection.scanFile(
                applicationContext,
                arrayOf(path, target.absolutePath),
                null,
                null,
            )

            if (!renamed && !target.exists()) {
                throw IllegalStateException("Android refused the rename.")
            }
        }

        runWithMediaConsent(listOf(path), REQUEST_MEDIA_WRITE, result, apply)
    }

    private fun deleteDeviceMedia(paths: List<String>, result: MethodChannel.Result) {
        // Runs both as the direct path (pre-Android 11) and as the follow-up
        // after createDeleteRequest, which removes the rows it was granted but
        // leaves behind anything that never resolved to a MediaStore row.
        val apply = {
            for (path in paths) {
                if (!File(path).exists()) continue
                val uri = mediaUriFor(path)
                if (uri != null) {
                    contentResolver.delete(uri, null, null)
                } else {
                    File(path).delete()
                }
            }
            MediaScannerConnection.scanFile(
                applicationContext,
                paths.toTypedArray(),
                null,
                null,
            )
            // The return values above are unreliable — File.delete() returns
            // false under scoped storage and ContentResolver.delete() can
            // report zero rows for a file that is gone. The filesystem is the
            // only honest answer, and reporting success for a file that is
            // still there is worse than an error: the row vanishes from the
            // list and reappears on the next scan.
            val survivors = paths.filter { File(it).exists() }
            if (survivors.isNotEmpty()) {
                throw IllegalStateException(
                    "Could not delete ${survivors.size} of ${paths.size} files.",
                )
            }
        }
        runWithMediaConsent(paths, REQUEST_MEDIA_DELETE, result, apply)
    }

    /**
     * Moves files into [targetFolder], an absolute directory path.
     *
     * Done as copy-then-delete rather than `File.renameTo`: the destination is
     * frequently on a different MediaStore volume (internal storage to SD
     * card), where rename fails outright, and a half-completed rename would
     * lose the file. Copying first means a failure leaves the original intact.
     */
    private fun moveDeviceMedia(
        paths: List<String>,
        targetFolder: String,
        result: MethodChannel.Result,
    ) {
        val destination = File(targetFolder)
        if (!destination.isDirectory && !destination.mkdirs()) {
            result.error("bad_target", "That folder does not exist.", null)
            return
        }
        val clashes = paths.filter { File(destination, File(it).name).exists() }
        if (clashes.isNotEmpty()) {
            result.error(
                "name_taken",
                "${clashes.size} file(s) with the same name are already there.",
                null,
            )
            return
        }

        val apply = {
            val failed = mutableListOf<String>()
            for (path in paths) {
                val source = File(path)
                if (!source.exists()) continue
                val target = File(destination, source.name)
                val copied = runCatching {
                    source.inputStream().use { input ->
                        target.outputStream().use { output -> input.copyTo(output) }
                    }
                    target.length() == source.length()
                }.getOrDefault(false)

                if (!copied) {
                    target.delete()
                    failed += path
                    continue
                }

                val uri = mediaUriFor(path)
                if (uri != null) {
                    contentResolver.delete(uri, null, null)
                } else {
                    source.delete()
                }
                // The original surviving means two copies now exist, which is
                // worse than a clean failure — undo rather than leave a mess.
                if (source.exists()) {
                    target.delete()
                    failed += path
                }
            }
            MediaScannerConnection.scanFile(
                applicationContext,
                (paths + paths.map { File(destination, File(it).name).absolutePath })
                    .toTypedArray(),
                null,
                null,
            )
            if (failed.isNotEmpty()) {
                throw IllegalStateException(
                    "Could not move ${failed.size} of ${paths.size} files.",
                )
            }
        }

        runWithMediaConsent(paths, REQUEST_MEDIA_WRITE, result, apply)
    }

    /**
     * Updates the title / artist / album tags MediaStore holds for a file.
     *
     * This edits the MediaStore row, not the file's own ID3 tags — which is
     * what every music player on the device reads, and what the user actually
     * sees. Rewriting embedded tags would need a full transcode.
     */
    private fun updateDeviceMediaTags(
        path: String,
        tags: Map<String, String?>,
        result: MethodChannel.Result,
    ) {
        val uri = mediaUriFor(path)
        if (uri == null) {
            result.error(
                "not_indexed",
                "That file is not in the media library yet.",
                null,
            )
            return
        }

        val values = ContentValues().apply {
            tags["title"]?.let { put(MediaStore.MediaColumns.TITLE, it) }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                tags["artist"]?.let { put(MediaStore.Audio.AudioColumns.ARTIST, it) }
                tags["album"]?.let { put(MediaStore.Audio.AudioColumns.ALBUM, it) }
            }
        }
        if (values.size() == 0) {
            result.error("no_changes", "Nothing to update.", null)
            return
        }

        val apply = {
            if (contentResolver.update(uri, values, null, null) <= 0) {
                throw IllegalStateException("The media library rejected the change.")
            }
        }
        runWithMediaConsent(listOf(path), REQUEST_MEDIA_WRITE, result, apply)
    }

    /**
     * True when this app can already modify [uri] without asking again.
     *
     * Two ways that happens. The app created the row, and MediaStore always
     * lets an owner modify its own entries — that covers everything Duck
     * downloaded. Or the user granted write access through an earlier consent
     * dialog: those grants are held per URI and outlive the screen that asked
     * for them, which is the whole reason a single up-front request is worth
     * making.
     */
    private fun canWrite(uri: Uri): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return true

        val granted = checkUriPermission(
            uri,
            android.os.Process.myPid(),
            android.os.Process.myUid(),
            Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
        ) == android.content.pm.PackageManager.PERMISSION_GRANTED
        if (granted) return true

        return runCatching {
            contentResolver.query(
                uri,
                arrayOf(MediaStore.MediaColumns.OWNER_PACKAGE_NAME),
                null,
                null,
                null,
            )?.use { cursor ->
                cursor.moveToFirst() && cursor.getString(0) == packageName
            }
        }.getOrNull() ?: false
    }

    /**
     * Asks once for write access to a whole set of files.
     *
     * Android has no runtime permission that grants blanket modify access to
     * media the app did not create — that is the point of scoped storage, and
     * MANAGE_EXTERNAL_STORAGE, the only real exception, is restricted by Play
     * to file managers and backup tools. What *is* possible is asking for many
     * files in one breath: createWriteRequest takes a list and shows a single
     * dialog, and the grant persists. So the browser asks once, up front, and
     * every rename, move and delete afterwards happens silently.
     */
    private fun requestMediaWriteAccess(paths: List<String>, result: MethodChannel.Result) {
        // Below Android 11 a plain file write is still allowed, so there is
        // nothing to ask for.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R || paths.isEmpty()) {
            result.success(true)
            return
        }
        // The URI list crosses a Binder transaction, which is capped at about
        // a megabyte; a library of tens of thousands of files would blow it.
        // Dart sends newest-first, so a cap keeps the most relevant ones.
        val capped = paths.take(MAX_CONSENT_URIS)
        if (capped.mapNotNull { mediaUriFor(it) }.none { !canWrite(it) }) {
            result.success(true)
            return
        }
        // An empty action: this call exists purely to obtain the grant.
        runWithMediaConsent(capped, REQUEST_MEDIA_WRITE, result) {}
    }

    /**
     * Runs [action], asking the user for permission first when the platform
     * requires it. The action is retried verbatim once consent is granted.
     */
    private fun runWithMediaConsent(
        paths: List<String>,
        requestCode: Int,
        result: MethodChannel.Result,
        action: () -> Unit,
    ) {
        // Only one consent dialog can be outstanding. Without this guard a
        // second call overwrites `pendingMediaResult`, and the Dart future for
        // the first one never completes — leaving the sheet spinning on
        // `_busy` with no way out.
        if (pendingMediaResult != null) {
            result.error("busy", "Another media edit is still waiting for you.", null)
            return
        }

        // Only the files we cannot already write need a dialog. Without this
        // filter the one-time bulk grant would buy nothing: every later edit
        // would raise its own consent sheet regardless of what the user had
        // already agreed to.
        val uris = paths.mapNotNull { mediaUriFor(it) }.filterNot { canWrite(it) }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R && uris.isNotEmpty()) {
            pendingMediaResult = result
            // createDeleteRequest removes the rows itself, but it only covers
            // the URIs that resolved. Replaying `action` afterwards mops up
            // anything left and verifies the result either way.
            pendingMediaAction = action
            val launched = runCatching {
                val sender = if (requestCode == REQUEST_MEDIA_DELETE) {
                    MediaStore.createDeleteRequest(contentResolver, uris).intentSender
                } else {
                    MediaStore.createWriteRequest(contentResolver, uris).intentSender
                }
                startIntentSenderForResult(sender, requestCode, null, 0, 0, 0)
            }
            if (launched.isFailure) {
                // Nothing will come back through onActivityResult, so settle
                // the call here rather than stranding it forever.
                pendingMediaResult = null
                pendingMediaAction = null
                result.error(
                    "consent_unavailable",
                    launched.exceptionOrNull()?.message ?: "Could not ask for permission.",
                    null,
                )
            }
            return
        }

        try {
            action()
            result.success(true)
        } catch (security: SecurityException) {
            val sender = recoverableIntentSender(security)
            if (sender == null) {
                result.error("permission_denied", security.message, null)
                return
            }
            pendingMediaResult = result
            pendingMediaAction = action
            val launched = runCatching {
                startIntentSenderForResult(sender, requestCode, null, 0, 0, 0)
            }
            if (launched.isFailure) {
                pendingMediaResult = null
                pendingMediaAction = null
                result.error(
                    "consent_unavailable",
                    launched.exceptionOrNull()?.message ?: "Could not ask for permission.",
                    null,
                )
            }
        } catch (error: Exception) {
            result.error("failed", error.message ?: "Operation failed.", null)
        }
    }

    private fun recoverableIntentSender(error: SecurityException): IntentSender? {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return null
        val recoverable = error as? android.app.RecoverableSecurityException ?: return null
        return recoverable.userAction.actionIntent.intentSender
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != REQUEST_MEDIA_WRITE && requestCode != REQUEST_MEDIA_DELETE) return

        val result = pendingMediaResult ?: return
        val action = pendingMediaAction
        pendingMediaResult = null
        pendingMediaAction = null

        if (resultCode != Activity.RESULT_OK) {
            result.success(false)
            return
        }
        try {
            action?.invoke()
            result.success(true)
        } catch (error: Exception) {
            result.error("failed", error.message ?: "Operation failed.", null)
        }
    }
}
