package a.a.easysend

import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Bundle
import android.provider.DocumentsContract
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import java.io.File

class MainActivity : FlutterActivity() {

    companion object {
        // Set by the notification's Exit button when the exit has something to
        // ask before it acts, and the question needs the app on screen.
        const val EXTRA_EXIT_REQUESTED = "easysend_exit"

        private const val PRIMARY_STORAGE = "/storage/emulated/0"
        private const val EXTERNAL_STORAGE_AUTHORITY = "com.android.externalstorage.documents"
        private const val PICK_FILES_REQUEST = 4711

        // Where copies of picked documents go. The Dart side knows this name —
        // `pickedCopiesDirName` in file_helpers.dart — and a test holds the two
        // together.
        private const val COPIES_DIR = "picked"

        // Counts the copies this process has made, so each gets a directory of
        // its own. Process-wide rather than per-Activity: the Activity is
        // destroyed and re-created while the picker is on screen.
        private val copySlot = java.util.concurrent.atomic.AtomicInteger()
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        consumeExitRequest(intent)
    }

    // singleTop: an app that is already open is handed the Intent here instead
    // of being created again.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        consumeExitRequest(intent)
    }

    private fun consumeExitRequest(intent: Intent?) {
        if (intent?.getBooleanExtra(EXTRA_EXIT_REQUESTED, false) != true) return
        // Taken out of the Intent, or every later recreation of this Activity —
        // a rotation, a system kill and return — would exit the app on its own.
        intent.removeExtra(EXTRA_EXIT_REQUESTED)
        (application as EasySendApplication).notifyDart("notificationExit")
    }

    /**
     * Opens the document picker for the Dart side.
     *
     * A plugin cannot do this reliably here. On both Samsung phones the system
     * destroys this Activity while the picker is on screen — with the process
     * held at adj 50 by the foreground service just as readily as without it —
     * and `file_picker` keeps the pending result in state it drops in
     * `onDetachedFromActivity`. The returning result then hits `type == null`
     * and is discarded without a word, so the Dart future never completes.
     *
     * `startActivityForResult` is built for exactly this: Android re-creates the
     * Activity and delivers the result to the new instance. From there it goes
     * to the Application, whose engine and channel belong to the process and
     * outlive any number of Activities.
     */
    internal fun pickFiles(): Boolean {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            // Open at the top of internal storage rather than wherever the
            // picker was left last time. Advisory: a picker may ignore it, and
            // nothing here depends on where the user ends up browsing.
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                putExtra(
                    DocumentsContract.EXTRA_INITIAL_URI,
                    DocumentsContract.buildDocumentUri(
                        EXTERNAL_STORAGE_AUTHORITY,
                        "primary:",
                    ),
                )
            }
        }
        return try {
            startActivityForResult(intent, PICK_FILES_REQUEST)
            true
        } catch (e: ActivityNotFoundException) {
            false
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        // Plugins still own every other request code — the folder picker among
        // them — so the delegate has to see this first.
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != PICK_FILES_REQUEST) return

        val app = application as EasySendApplication
        if (resultCode != RESULT_OK || data == null) {
            app.deliverPickedFiles(emptyList())
            return
        }

        val uris = mutableListOf<android.net.Uri>()
        val clip = data.clipData
        if (clip != null) {
            for (i in 0 until clip.itemCount) uris.add(clip.getItemAt(i).uri)
        } else {
            data.data?.let { uris.add(it) }
        }
        app.deliverPickedFiles(uris.mapNotNull { resolveToPath(it) })
    }

    /**
     * A readable filesystem path for a picked document.
     *
     * The app holds MANAGE_EXTERNAL_STORAGE, so a document on primary storage is
     * readable where it lies and needs no copy. Anything else — a provider that
     * hands out content only through a stream — is copied into the cache, which
     * is what the plugin did for every file.
     */
    private fun resolveToPath(uri: android.net.Uri): String? {
        if (uri.authority == EXTERNAL_STORAGE_AUTHORITY) {
            val documentId = try {
                DocumentsContract.getDocumentId(uri)
            } catch (e: IllegalArgumentException) {
                null
            }
            val parts = documentId?.split(':', limit = 2)
            if (parts?.size == 2 && parts[0] == "primary") {
                val candidate = File(PRIMARY_STORAGE, parts[1])
                if (candidate.isFile) return candidate.absolutePath
            }
        }
        return copyToCache(uri)
    }

    /**
     * A copy of the document inside our own cache, for the providers that only
     * expose a stream.
     *
     * The Dart side knows this directory by name — `pickedCopiesDirName` in
     * file_helpers.dart — and needs to, for two reasons: a move must not delete
     * a copy and report it as the user's original being gone, and nothing else
     * would ever clean these up.
     */
    private fun copyToCache(uri: android.net.Uri): String? {
        val name = displayName(uri) ?: return null
        return try {
            // A directory of its own for every copy. Two documents can carry the
            // same display name — a report.pdf from each of two cloud folders —
            // and one cache file for both leaves the second's bytes under the
            // first's path: the Dart side then folds the two picks into one,
            // because it tells picked files apart by their source path, and
            // sends a file whose name and content came from different
            // documents. The name has to stay the one its owner gave it, so the
            // uniqueness goes into the directory around it.
            val slot = File(
                File(cacheDir, COPIES_DIR),
                "${System.currentTimeMillis()}-${copySlot.getAndIncrement()}",
            )
            if (!slot.mkdirs()) return null
            val target = File(slot, name)
            contentResolver.openInputStream(uri)?.use { input ->
                target.outputStream().use { output -> input.copyTo(output) }
            } ?: return null
            target.absolutePath
        } catch (e: java.io.IOException) {
            null
        } catch (e: SecurityException) {
            null
        }
    }

    private fun displayName(uri: android.net.Uri): String? {
        contentResolver.query(uri, null, null, null, null)?.use { cursor ->
            val column = cursor.getColumnIndex(android.provider.OpenableColumns.DISPLAY_NAME)
            if (column >= 0 && cursor.moveToFirst()) {
                val value = cursor.getString(column)
                if (!value.isNullOrBlank()) return File(value).name
            }
        }
        return uri.lastPathSegment?.substringAfterLast('/')?.takeIf { it.isNotBlank() }
    }

    override fun provideFlutterEngine(context: Context): FlutterEngine =
        (application as EasySendApplication).flutterEngine

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        (application as EasySendApplication).attachActivity(this)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        (application as EasySendApplication).detachActivity(this)
        super.cleanUpFlutterEngine(flutterEngine)
    }

    // Sending our own file path out would raise FileUriExposedException, so the
    // receiving app gets a content:// URI granted for this one file only.
    internal fun openFile(path: String?): Boolean {
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
    internal fun openFolder(path: String?): Boolean {
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
