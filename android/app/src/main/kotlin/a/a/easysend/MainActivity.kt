package a.a.easysend

import android.content.ActivityNotFoundException
import android.content.Intent
import android.os.Build
import android.provider.DocumentsContract
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "easysend/service"
        const val PRIMARY_STORAGE = "/storage/emulated/0"
        const val EXTERNAL_STORAGE_AUTHORITY = "com.android.externalstorage.documents"
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "start", "update" -> {
                        val intent = Intent(this, TransferService::class.java).apply {
                            action = if (call.method == "start") {
                                TransferService.ACTION_START
                            } else {
                                TransferService.ACTION_UPDATE
                            }
                            putExtra(TransferService.EXTRA_TITLE, call.argument<String>("title"))
                            putExtra(TransferService.EXTRA_TEXT, call.argument<String>("text"))
                            putExtra(TransferService.EXTRA_PROGRESS, call.argument<Int>("progress") ?: -1)
                        }
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(true)
                    }

                    "stop" -> {
                        val intent = Intent(this, TransferService::class.java).apply {
                            action = TransferService.ACTION_STOP
                        }
                        startService(intent)
                        result.success(true)
                    }

                    "openFile" -> result.success(openFile(call.argument<String>("path")))

                    "openFolder" -> result.success(openFolder(call.argument<String>("path")))

                    else -> result.notImplemented()
                }
            }
    }

    // Sending our own file path out would raise FileUriExposedException, so the
    // receiving app gets a content:// URI granted for this one file only.
    private fun openFile(path: String?): Boolean {
        val file = File(path ?: return false)
        if (!file.isFile) return false

        val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", file)
        val extension = file.extension.lowercase()
        val mime = MimeTypeMap.getSingleton().getMimeTypeFromExtension(extension) ?: "*/*"

        val intent = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mime)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return launch(intent)
    }

    // File managers answer to a documents URI; a folder has no FileProvider
    // equivalent. If none of them takes it, fall back to whatever the system
    // calls its file manager, which at least lands the user in the right app.
    private fun openFolder(path: String?): Boolean {
        val dir = File(path ?: return false)
        if (!dir.isDirectory) return false

        val relative = dir.absolutePath.removePrefix(PRIMARY_STORAGE).trim('/')
        val uri = DocumentsContract.buildDocumentUri(
            EXTERNAL_STORAGE_AUTHORITY,
            if (relative.isEmpty()) "primary:" else "primary:$relative",
        )
        // No FLAG_GRANT_READ_URI_PERMISSION here: that flag hands the receiver a
        // URI of ours, and this one belongs to the storage provider. Offering
        // what we do not hold makes ActivityManager refuse the start outright
        // (SecurityException on One UI), so the folder never opens.
        val view = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, DocumentsContract.Document.MIME_TYPE_DIR)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        if (launch(view)) return true

        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) return false
        val files = Intent(Intent.ACTION_MAIN).apply {
            addCategory(Intent.CATEGORY_APP_FILES)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        return launch(files)
    }

    // A refused intent is one way in that did not work, not the end of the call:
    // both refusals answer false so the caller can try the next one.
    private fun launch(intent: Intent): Boolean = try {
        startActivity(intent)
        true
    } catch (e: ActivityNotFoundException) {
        false
    } catch (e: SecurityException) {
        false
    }
}
