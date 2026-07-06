package com.example.duck_downloader

import android.content.ContentValues
import android.content.Context
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import com.ryanheise.audioservice.AudioServiceActivity
import com.ryanheise.audioservice.AudioServicePlugin
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.FileInputStream

class MainActivity : AudioServiceActivity() {
    private val channelName = "duck_downloader/media"
    private var methodChannel: MethodChannel? = null
    private var isVideoPlaying = false

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
                    "setVideoPlaying" -> {
                        isVideoPlaying = call.argument<Boolean>("playing") ?: false
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            } catch (error: Exception) {
                result.error("failed", error.message ?: "Operation failed.", null)
            }
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (isVideoPlaying) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                try {
                    val params = android.app.PictureInPictureParams.Builder().build()
                    enterPictureInPictureMode(params)
                } catch (e: Exception) {
                    // Ignore
                }
            } else if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                @Suppress("DEPRECATION")
                enterPictureInPictureMode()
            }
        }
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: android.content.res.Configuration?) {
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
}
