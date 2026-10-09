package app.alextran.immich.externaleditor

import android.app.Activity
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import android.util.Log
import android.webkit.MimeTypeMap
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.io.FileOutputStream

private const val TAG = "ExternalEditorPlugin"
private const val REQUEST_EDIT = 0x1E17
private const val SCRATCH_DIR = "external_edit"
private const val MEDIA_RELATIVE_DIR = "Pictures/Immich Edits"

/// Launches a third-party editor with ACTION_EDIT and hands the result back to Dart.
///
/// The scratch copy is registered in MediaStore rather than served from a
/// FileProvider: Google Photos (and some others) refuse to edit anything that is
/// not a MediaStore item. Editors return their work in one of three ways:
///  1. a content URI in the result intent (copied out),
///  2. an in-place overwrite of the MediaStore item (detected by size/mtime),
///  3. a new file saved somewhere else with no result at all. That yields null
///     here; Immich's regular backup picks the new file up instead.
/// Whatever happens, the MediaStore scratch item is removed afterwards.
class ExternalEditorPlugin : FlutterPlugin, ActivityAware, PluginRegistry.ActivityResultListener,
  ExternalEditorHostApi {
  private var context: Context? = null
  private var activity: Activity? = null
  private var binding: ActivityPluginBinding? = null

  private var pending: PendingEdit? = null

  private data class PendingEdit(
    val mediaUri: Uri,
    val sizeBefore: Long,
    val modifiedBefore: Long,
    val callback: (Result<String?>) -> Unit,
  )

  override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    context = binding.applicationContext
    ExternalEditorHostApi.setUp(binding.binaryMessenger, this)
  }

  override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
    ExternalEditorHostApi.setUp(binding.binaryMessenger, null)
    context = null
  }

  override fun onAttachedToActivity(binding: ActivityPluginBinding) {
    this.binding = binding
    activity = binding.activity
    binding.addActivityResultListener(this)
  }

  override fun onDetachedFromActivityForConfigChanges() = detachActivity()

  override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) = onAttachedToActivity(binding)

  override fun onDetachedFromActivity() = detachActivity()

  private fun detachActivity() {
    binding?.removeActivityResultListener(this)
    binding = null
    activity = null
  }

  override fun hasEditor(): Boolean {
    val context = context ?: return false
    // Editors usually filter on scheme=content, so probe with a URI shaped like the real one.
    val probeUri = ContentUris.withAppendedId(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, 1)
    val probe = Intent(Intent.ACTION_EDIT).setDataAndType(probeUri, "image/jpeg")
    return context.packageManager.queryIntentActivities(probe, PackageManager.MATCH_DEFAULT_ONLY).isNotEmpty()
  }

  override fun editImage(path: String, mimeType: String, callback: (Result<String?>) -> Unit) {
    val context = context
    val activity = activity
    if (context == null || activity == null) {
      callback(Result.failure(IllegalStateException("No activity attached")))
      return
    }
    if (pending != null) {
      callback(Result.failure(IllegalStateException("An edit is already in progress")))
      return
    }

    var mediaUri: Uri? = null
    try {
      // Publish a private copy so an in-place edit never touches the gallery original.
      mediaUri = insertScratchMedia(context, File(path), mimeType)
      val (size, modified) = queryMediaStats(context, mediaUri)

      val intent = Intent(Intent.ACTION_EDIT).apply {
        setDataAndType(mediaUri, mimeType)
        putExtra(Intent.EXTRA_STREAM, mediaUri)
        addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
      }
      if (intent.resolveActivity(context.packageManager) == null) {
        context.contentResolver.delete(mediaUri, null, null)
        callback(Result.success(null))
        return
      }

      pending = PendingEdit(mediaUri, size, modified, callback)
      activity.startActivityForResult(Intent.createChooser(intent, null), REQUEST_EDIT)
    } catch (e: Exception) {
      Log.w(TAG, "Failed to launch external editor", e)
      mediaUri?.let { context.contentResolver.delete(it, null, null) }
      pending = null
      callback(Result.failure(e))
    }
  }

  override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
    if (requestCode != REQUEST_EDIT) return false
    val edit = pending ?: return true
    pending = null

    val context = context
    if (context == null) {
      edit.callback(Result.success(null))
      return true
    }

    Log.i(TAG, "Editor returned resultCode=$resultCode data=${data?.data} extras=${data?.extras?.keySet()}")
    try {
      val returnedUri = data?.data
      val (sizeAfter, modifiedAfter) = queryMediaStats(context, edit.mediaUri)
      val result = when {
        // 1. editor handed back a URI (a saved copy, or our own item)
        resultCode == Activity.RESULT_OK && returnedUri != null -> copyUriToScratch(context, returnedUri, data.type)
        // 2. editor overwrote our MediaStore item
        sizeAfter > 0 && (sizeAfter != edit.sizeBefore || modifiedAfter != edit.modifiedBefore) ->
          copyUriToScratch(context, edit.mediaUri, null)
        // 3. cancelled, or saved somewhere we cannot see
        else -> null
      }
      Log.i(TAG, "Edit result: ${result?.absolutePath}")
      edit.callback(Result.success(result?.absolutePath))
    } catch (e: Exception) {
      Log.w(TAG, "Failed to read external editor result", e)
      edit.callback(Result.failure(e))
    } finally {
      // Always drop the scratch item so it never lingers in the gallery.
      try {
        context.contentResolver.delete(edit.mediaUri, null, null)
      } catch (e: Exception) {
        Log.w(TAG, "Failed to delete scratch media item ${edit.mediaUri}", e)
      }
    }
    return true
  }

  private fun scratchDir(context: Context): File = File(context.filesDir, SCRATCH_DIR).apply { mkdirs() }

  /// Inserts [source] into MediaStore under [MEDIA_RELATIVE_DIR] and returns its content URI.
  private fun insertScratchMedia(context: Context, source: File, mimeType: String): Uri {
    val resolver = context.contentResolver
    val values = ContentValues().apply {
      put(MediaStore.Images.Media.DISPLAY_NAME, "immich_edit_${System.currentTimeMillis()}_${source.name}")
      put(MediaStore.Images.Media.MIME_TYPE, mimeType.takeIf { it != "image/*" } ?: "image/jpeg")
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        put(MediaStore.Images.Media.RELATIVE_PATH, MEDIA_RELATIVE_DIR)
      } else {
        @Suppress("DEPRECATION")
        val dir = File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES), "Immich Edits")
        dir.mkdirs()
        @Suppress("DEPRECATION")
        put(MediaStore.Images.Media.DATA, File(dir, "immich_edit_${System.currentTimeMillis()}_${source.name}").absolutePath)
      }
    }
    val uri = resolver.insert(MediaStore.Images.Media.EXTERNAL_CONTENT_URI, values)
      ?: throw IllegalStateException("MediaStore insert failed")
    resolver.openOutputStream(uri, "w")?.use { output ->
      source.inputStream().use { input -> input.copyTo(output) }
    } ?: throw IllegalStateException("Cannot write to $uri")
    return uri
  }

  private fun queryMediaStats(context: Context, uri: Uri): Pair<Long, Long> {
    val projection = arrayOf(MediaStore.MediaColumns.SIZE, MediaStore.MediaColumns.DATE_MODIFIED)
    context.contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
      if (cursor.moveToFirst()) {
        return cursor.getLong(0) to cursor.getLong(1)
      }
    }
    return 0L to 0L
  }

  private fun copyUriToScratch(context: Context, uri: Uri, intentType: String?): File? {
    val mimeType = context.contentResolver.getType(uri) ?: intentType ?: "image/jpeg"
    val extension = MimeTypeMap.getSingleton().getExtensionFromMimeType(mimeType) ?: "jpg"
    val target = File(scratchDir(context), "${System.currentTimeMillis()}_edited.$extension")
    context.contentResolver.openInputStream(uri)?.use { input ->
      FileOutputStream(target).use { output -> input.copyTo(output) }
    } ?: return null
    return target
  }
}
