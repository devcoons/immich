package app.alextran.immich

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.ext.SdkExtensions
import android.util.Log
import app.alextran.immich.background.BackgroundEngineLock
import app.alextran.immich.background.BackgroundWorkerApiImpl
import app.alextran.immich.background.BackgroundWorkerFgHostApi
import app.alextran.immich.background.BackgroundWorkerLockApi
import app.alextran.immich.connectivity.ConnectivityApi
import app.alextran.immich.connectivity.ConnectivityApiImpl
import app.alextran.immich.core.ImmichPlugin
import app.alextran.immich.images.ThumbnailApi
import app.alextran.immich.images.ThumbnailsImpl
import app.alextran.immich.sync.NativeSyncApi
import app.alextran.immich.sync.NativeSyncApiImpl26
import app.alextran.immich.sync.NativeSyncApiImpl30
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterFragmentActivity() {

  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    // If app was launched via ACTION_VIEW, this catches the cold start path.
    maybeHandleViewIntent(intent)
  }

  override fun onNewIntent(intent: Intent) {
    super.onNewIntent(intent)
    setIntent(intent)
    // This catches subsequent opens because you use singleTask.
    maybeHandleViewIntent(intent)
  }

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    registerPlugins(this, flutterEngine)

    // Init channel once engine is ready, then flush any pending VIEW intent.
    ensureIntentChannel(flutterEngine)
    flushPendingViewIntent()
  }

  private fun maybeHandleViewIntent(intent: Intent?) {
    if (intent == null) return
    if (Intent.ACTION_VIEW != intent.action) return

    val uri: Uri = intent.data ?: return

    Log.d(TAG, "Received VIEW intent with URI: $uri")

    // Queue it; channel may not be ready yet during cold start.
    pendingViewUri = uri.toString()
    flushPendingViewIntent()
  }

  private fun ensureIntentChannel(flutterEngine: FlutterEngine) {
    if (intentChannel != null) return
    intentChannel = MethodChannel(
      flutterEngine.dartExecutor.binaryMessenger,
      INTENT_CHANNEL_NAME
    )

    // Set up method call handler for getting file paths from content URIs
    intentChannel?.setMethodCallHandler { call, result ->
      when (call.method) {
        "getPathFromUri" -> {
          val uriString = call.argument<String>("uri")
          if (uriString != null) {
            try {
              val uri = Uri.parse(uriString)
              val path = getPathFromUri(uri)
              if (path != null) {
                result.success(path)
              } else {
                result.error("UNAVAILABLE", "Could not resolve URI to file path", null)
              }
            } catch (e: Exception) {
              result.error("ERROR", "Failed to get path from URI: ${e.message}", null)
            }
          } else {
            result.error("INVALID", "URI string is null", null)
          }
        }
        "readUriBytes" -> {
          val uriString = call.argument<String>("uri")
          if (uriString != null) {
            try {
              val uri = Uri.parse(uriString)
              val bytes = readUriBytes(uri)
              if (bytes != null) {
                Log.d(TAG, "Read ${bytes.size} bytes from URI: $uri")
                result.success(bytes)
              } else {
                result.error("UNAVAILABLE", "Could not read bytes from URI", null)
              }
            } catch (e: Exception) {
              Log.e(TAG, "Failed to read bytes from URI: ${e.message}", e)
              result.error("ERROR", "Failed to read bytes from URI: ${e.message}", null)
            }
          } else {
            result.error("INVALID", "URI string is null", null)
          }
        }
        else -> result.notImplemented()
      }
    }
  }

  private fun getPathFromUri(uri: Uri): String? {
    return try {
      // For content:// URIs, try to get the real file path
      if (uri.scheme == "content") {
        val projection = arrayOf(android.provider.MediaStore.MediaColumns.DATA)
        contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
          if (cursor.moveToFirst()) {
            val columnIndex = cursor.getColumnIndexOrThrow(android.provider.MediaStore.MediaColumns.DATA)
            return cursor.getString(columnIndex)
          }
        }
        // If we can't get the path, return the URI string itself
        // The file will need to be accessed via ContentResolver
        return uri.toString()
      } else if (uri.scheme == "file") {
        return uri.path
      }
      null
    } catch (e: Exception) {
      null
    }
  }

  private fun readUriBytes(uri: Uri): ByteArray? {
    return try {
      contentResolver.openInputStream(uri)?.use { inputStream ->
        inputStream.readBytes()
      }
    } catch (e: Exception) {
      Log.e(TAG, "Error reading bytes from URI: ${e.message}", e)
      null
    }
  }

  private fun flushPendingViewIntent() {
    val channel = intentChannel ?: return
    val uri = pendingViewUri ?: return
    pendingViewUri = null

    Log.d(TAG, "Flushing VIEW intent to Flutter: $uri")
    channel.invokeMethod("viewUri", mapOf("uri" to uri))
  }

  companion object {
    private const val TAG = "ImmichMainActivity"
    private const val INTENT_CHANNEL_NAME = "app.alextran.immich/intent"
    @Volatile private var intentChannel: MethodChannel? = null
    @Volatile private var pendingViewUri: String? = null

    fun registerPlugins(ctx: Context, flutterEngine: FlutterEngine) {
      val messenger = flutterEngine.dartExecutor.binaryMessenger
      val backgroundEngineLockImpl = BackgroundEngineLock(ctx)
      BackgroundWorkerLockApi.setUp(messenger, backgroundEngineLockImpl)

      val nativeSyncApiImpl =
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.R ||
          SdkExtensions.getExtensionVersion(Build.VERSION_CODES.R) < 1
        ) {
          NativeSyncApiImpl26(ctx)
        } else {
          NativeSyncApiImpl30(ctx)
        }

      NativeSyncApi.setUp(messenger, nativeSyncApiImpl)
      ThumbnailApi.setUp(messenger, ThumbnailsImpl(ctx))
      BackgroundWorkerFgHostApi.setUp(messenger, BackgroundWorkerApiImpl(ctx))
      ConnectivityApi.setUp(messenger, ConnectivityApiImpl(ctx))

      flutterEngine.plugins.add(BackgroundServicePlugin())
      flutterEngine.plugins.add(HttpSSLOptionsPlugin())
      flutterEngine.plugins.add(backgroundEngineLockImpl)
      flutterEngine.plugins.add(nativeSyncApiImpl)
    }

    fun cancelPlugins(flutterEngine: FlutterEngine) {
      val nativeApi =
        flutterEngine.plugins.get(NativeSyncApiImpl26::class.java) as ImmichPlugin?
          ?: flutterEngine.plugins.get(NativeSyncApiImpl30::class.java) as ImmichPlugin?
      nativeApi?.detachFromEngine()
    }
  }
}
