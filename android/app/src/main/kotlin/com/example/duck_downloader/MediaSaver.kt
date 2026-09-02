package com.example.duck_downloader

import android.content.ContentValues
import android.content.Context
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import java.io.File
import java.io.FileInputStream

/**
 * Publishes a finished download into the user's media library.
 *
 * This used to live inside MainActivity as six private methods. The download
 * foreground service saves files too, and it has no activity to borrow them
 * from — a service that outlives the UI is the whole point. Copying the
 * MediaStore dance into a second place is how the two drift apart, so it moved
 * here and MainActivity delegates.
 */
object MediaSaver {

    enum class Kind { VIDEO, AUDIO, IMAGE }

    fun save(
        context: Context,
        sourcePath: String,
        filename: String,
        mimeType: String,
        kind: Kind,
    ): Map<String, Any?> {
        val source = File(sourcePath)
        require(source.exists()) { "Downloaded file is not available." }
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            saveViaMediaStore(context, source, filename, mimeType, kind)
        } else {
            saveLegacy(context, source, filename, mimeType, kind)
        }
    }

    private fun collectionFor(kind: Kind): Uri = when (kind) {
        Kind.VIDEO -> MediaStore.Video.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        Kind.AUDIO -> MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        Kind.IMAGE -> MediaStore.Images.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
    }

    private fun directoryFor(kind: Kind): String = when (kind) {
        Kind.VIDEO -> Environment.DIRECTORY_MOVIES
        Kind.AUDIO -> Environment.DIRECTORY_MUSIC
        Kind.IMAGE -> Environment.DIRECTORY_PICTURES
    }

    /// Moves a finished download into one of the user's own folders.
    ///
    /// Those folders live under the media collections the phone already shows
    /// — Movies/Duck Downloader/<folder> and its siblings — so a file filed
    /// away is visible in the gallery and in any file manager. A "folder" only
    /// the app that made it can see is not what anybody means by the word.
    ///
    /// The source is deleted once the copy is written, so the file exists
    /// once. Returns the path it now lives at, which the library stores.
    fun moveIntoFolder(
        context: Context,
        sourcePath: String,
        filename: String,
        mimeType: String,
        kind: Kind,
        folder: String?,
    ): Map<String, Any?> {
        val source = File(sourcePath)
        require(source.exists()) { "That file is no longer where it was." }

        val relative = buildString {
            append(directoryFor(kind))
            append("/Duck Downloader")
            if (!folder.isNullOrBlank()) {
                append('/')
                append(folder)
            }
        }

        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, filename)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(MediaStore.MediaColumns.RELATIVE_PATH, relative)
                put(MediaStore.MediaColumns.IS_PENDING, 1)
            }
        }

        val resolver = context.applicationContext.contentResolver
        val uri = resolver.insert(collectionFor(kind), values)
            ?: throw IllegalStateException("Could not create the file.")
        resolver.openOutputStream(uri)?.use { output ->
            FileInputStream(source).use { input -> input.copyTo(output) }
        } ?: throw IllegalStateException("Could not write the file.")

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            values.clear()
            values.put(MediaStore.MediaColumns.IS_PENDING, 0)
            resolver.update(uri, values, null, null)
        }

        // The real path, so the player can open it the way it opens everything
        // else. MediaStore still fills DATA in for files it wrote, and a null
        // here is worth surfacing rather than silently leaving the library
        // pointing at a file that has already been deleted.
        val path = resolver.query(
            uri,
            arrayOf(MediaStore.MediaColumns.DATA),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        }

        if (path == null) {
            resolver.delete(uri, null, null)
            throw IllegalStateException("Could not resolve where the file went.")
        }

        source.delete()
        MediaScannerConnection.scanFile(
            context.applicationContext,
            arrayOf(path),
            arrayOf(mimeType),
            null,
        )
        return mapOf("success" to true, "path" to path, "uri" to uri.toString())
    }

    private fun saveViaMediaStore(
        context: Context,
        source: File,
        filename: String,
        mimeType: String,
        kind: Kind,
    ): Map<String, Any?> {
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, filename)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            put(MediaStore.MediaColumns.RELATIVE_PATH, directoryFor(kind) + "/Duck Downloader")
            put(MediaStore.MediaColumns.IS_PENDING, 1)
        }
        val resolver = context.applicationContext.contentResolver
        val uri = resolver.insert(collectionFor(kind), values)
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
        context: Context,
        source: File,
        filename: String,
        mimeType: String,
        kind: Kind,
    ): Map<String, Any?> {
        // Pictures had no "Duck Downloader" subfolder on the pre-Q path while
        // Movies and Music did. Same folder on every version now.
        val directory = Environment
            .getExternalStoragePublicDirectory(directoryFor(kind))
            .resolve("Duck Downloader")
        directory.mkdirs()
        val target = directory.resolve(filename)
        source.copyTo(target, overwrite = true)
        MediaScannerConnection.scanFile(
            context.applicationContext,
            arrayOf(target.absolutePath),
            arrayOf(mimeType),
            null,
        )
        return mapOf("success" to true, "uri" to Uri.fromFile(target).toString())
    }
}
