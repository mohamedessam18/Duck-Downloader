package com.example.duck_downloader

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
import io.flutter.embedding.android.FlutterFragmentActivity

class MainActivity : AudioServiceFragmentActivity() {
    private val channelName = "duck_downloader/media"
    private var methodChannel: MethodChannel? = null
    private var isVideoPlaying = false

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
        handleIntent(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        handleIntent(intent)
    }

    private fun handleIntent(intent: Intent?) {
        if (intent?.action == Intent.ACTION_SEND && intent.type == "text/plain") {
            moveTaskToBack(true)
        }
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
                                updatePiPParams(isVideoPlaying)
                                val params = android.app.PictureInPictureParams.Builder().build()
                                val success = enterPictureInPictureMode(params)
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

    private fun updatePiPParams(playing: Boolean) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val actions = ArrayList<RemoteAction>()
            val iconId = if (playing) {
                android.R.drawable.ic_media_pause
            } else {
                android.R.drawable.ic_media_play
            }
            val title = if (playing) "Pause" else "Play"
            val controlType = if (playing) 2 else 1
            
            val intent = Intent("ACTION_MEDIA_CONTROL").putExtra("CONTROL_TYPE", controlType)
            val pendingIntent = PendingIntent.getBroadcast(
                this,
                controlType,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            
            val action = RemoteAction(
                Icon.createWithResource(this, iconId),
                title,
                title,
                pendingIntent
            )
            actions.add(action)
            
            val builder = android.app.PictureInPictureParams.Builder()
                .setActions(actions)

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                builder.setAutoEnterEnabled(playing)
            }

            setPictureInPictureParams(builder.build())
        }
    }

    override fun onDestroy() {
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
                    updatePiPParams(true)
                    val builder = android.app.PictureInPictureParams.Builder()
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                        builder.setAutoEnterEnabled(true)
                    }
                    enterPictureInPictureMode(builder.build())
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
    }

    private fun saveMedia(
        sourcePath: String,
        filename: String,
        mimeType: String,
        video: Boolean,
    ): Map<String, Any?> {
        val source = File(sourcePath)
        require(source.exists()) { "Downloaded file is not available." }
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            saveMediaStoreQ(source, filename, mimeType, video)
        } else {
            saveLegacy(source, filename, mimeType, video)
        }
    }

    private fun saveMediaStoreQ(
        source: File,
        filename: String,
        mimeType: String,
        video: Boolean,
    ): Map<String, Any?> {
        val collection = if (video) {
            MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        }
        val relativePath = if (video) {
            Environment.DIRECTORY_MOVIES + "/Duck Downloader"
        } else {
            Environment.DIRECTORY_MUSIC + "/Duck Downloader"
        }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, filename)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val resolver = applicationContext.contentResolver
        val uri = resolver.insert(collection, values)
            ?: throw IllegalStateException("Could not create media library item.")
        resolver.openOutputStream(uri)?.use { output ->
            FileInputStream(source).use { input -> input.copyTo(output) }
        } ?: throw IllegalStateException("Could not open media library item.")
        values.clear()
        values.put(MediaStore.MediaColumns.IS_PENDING, 0)
        resolver.update(uri, values, null, null)
        return mapOf("success" to true, "uri" to uri.toString())
    }

    private fun saveLegacy(
        source: File,
        filename: String,
        mimeType: String,
        video: Boolean,
    ): Map<String, Any?> {
        val directory = Environment.getExternalStoragePublicDirectory(
            if (video) Environment.DIRECTORY_MOVIES else Environment.DIRECTORY_MUSIC,
        ).resolve("Duck Downloader")
        directory.mkdirs()
        val target = directory.resolve(filename)
        source.copyTo(target, overwrite = true)
        MediaScannerConnection.scanFile(
            applicationContext,
            arrayOf(target.absolutePath),
            arrayOf(mimeType),
            null,
        )
        return mapOf("success" to true, "uri" to Uri.fromFile(target).toString())
    }

    private fun saveImageMedia(
        sourcePath: String,
        filename: String,
        mimeType: String,
    ): Map<String, Any?> {
        val source = File(sourcePath)
        require(source.exists()) { "Downloaded file is not available." }
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            saveMediaStoreImageQ(source, filename, mimeType)
        } else {
            saveLegacyImage(source, filename, mimeType)
        }
    }

    private fun saveMediaStoreImageQ(
        source: File,
        filename: String,
        mimeType: String,
    ): Map<String, Any?> {
        val collection = MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        val relativePath = Environment.DIRECTORY_PICTURES + "/Duck Downloader"
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, filename)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val resolver = applicationContext.contentResolver
        val uri = resolver.insert(collection, values)
            ?: throw IllegalStateException("Could not create media library item.")
        resolver.openOutputStream(uri)?.use { output ->
            FileInputStream(source).use { input -> input.copyTo(output) }
        } ?: throw IllegalStateException("Could not open media library item.")
        values.clear()
        values.put(MediaStore.MediaColumns.IS_PENDING, 0)
        resolver.update(uri, values, null, null)
        return mapOf("success" to true, "uri" to uri.toString())
    }

    private fun saveLegacyImage(
        source: File,
        filename: String,
        mimeType: String,
    ): Map<String, Any?> {
        val directory = Environment.getExternalStoragePublicDirectory(
            Environment.DIRECTORY_PICTURES
        ).resolve("Duck Downloader")
        directory.mkdirs()
        val target = directory.resolve(filename)
        source.copyTo(target, overwrite = true)
        MediaScannerConnection.scanFile(
            applicationContext,
            arrayOf(target.absolutePath),
            arrayOf(mimeType),
            null,
        )
        return mapOf("success" to true, "uri" to Uri.fromFile(target).toString())
    }

    private fun setSystemRingtone(file: File, title: String): Boolean {
        return try {
            val resolver = applicationContext.contentResolver
            val collection = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            } else {
                MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
            }

            try {
                resolver.delete(collection, "${MediaStore.Audio.Media.TITLE} = ?", arrayOf(title))
            } catch (e: Exception) {
                // Ignore
            }

            val values = ContentValues().apply {
                put(MediaStore.Audio.Media.TITLE, title)
                put(MediaStore.Audio.Media.DISPLAY_NAME, "$title.mp3")
                put(MediaStore.Audio.Media.MIME_TYPE, "audio/mp3")
                put(MediaStore.Audio.Media.IS_RINGTONE, true)
                put(MediaStore.Audio.Media.IS_NOTIFICATION, false)
                put(MediaStore.Audio.Media.IS_ALARM, false)
                put(MediaStore.Audio.Media.IS_MUSIC, false)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    put(MediaStore.Audio.Media.RELATIVE_PATH, Environment.DIRECTORY_RINGTONES + "/Duck Downloader")
                    put(MediaStore.Audio.Media.IS_PENDING, 1)
                } else {
                    val pubDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_RINGTONES)
                        .resolve("Duck Downloader")
                    pubDir.mkdirs()
                    val target = pubDir.resolve("$title.mp3")
                    file.copyTo(target, overwrite = true)
                    put(MediaStore.MediaColumns.DATA, target.absolutePath)
                }
            }

            val ringtoneUri = resolver.insert(collection, values) ?: return false

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                resolver.openOutputStream(ringtoneUri)?.use { output ->
                    FileInputStream(file).use { input -> input.copyTo(output) }
                } ?: return false

                val updateValues = ContentValues().apply {
                    put(MediaStore.Audio.Media.IS_PENDING, 0)
                }
                resolver.update(ringtoneUri, updateValues, null, null)
            }

            android.media.RingtoneManager.setActualDefaultRingtoneUri(
                this,
                android.media.RingtoneManager.TYPE_RINGTONE,
                ringtoneUri
            )
            true
        } catch (e: Exception) {
            e.printStackTrace()
            false
        }
    }
}
