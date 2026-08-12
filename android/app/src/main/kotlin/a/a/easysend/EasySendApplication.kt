package a.a.easysend

import android.app.Application
import android.content.Context
import android.content.Intent
import android.net.wifi.WifiManager
import android.os.Build
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * Holds the multicast lock for as long as discovery is running.
 *
 * Wi-Fi hardware drops multicast and broadcast frames unless something asks it
 * not to, and discovery is built on both: announces every five seconds and the
 * query a newcomer sends to be answered at once.
 *
 * The lock used to belong to MainActivity and was released in its onDestroy.
 * That tied it to the lifetime of a screen while the thing that needs it — the
 * Dart isolate running discovery — outlives any screen: with background
 * receiving on, the Activity can be destroyed while the process keeps working,
 * and the two halves then disagreed in silence, Dart going on believing it held
 * a lock that Android had taken back. Whoever needs it should own it, so it
 * lives here, where the process does, and is released only when discovery says
 * it has stopped.
 */
class EasySendApplication : Application() {

    private var multicastLock: WifiManager.MulticastLock? = null
    private lateinit var serviceChannel: MethodChannel
    private var activity: MainActivity? = null
    lateinit var flutterEngine: FlutterEngine
        private set

    companion object {
        private const val SERVICE_PREFS = "easysend_service"
        private const val SERVICE_TIMED_OUT = "timed_out"
        private const val CHANNEL = "easysend/service"
    }

    /**
     * The engine is built here so it outlives any Activity, but Dart is
     * deliberately not started here.
     *
     * `main()` talks to the platform before `runApp` — `SystemChrome` and the
     * notification plugin among others — and those calls only have an answering
     * end once an Activity is attached and `GeneratedPluginRegistrant` has run.
     * Starting the entrypoint from `onCreate` raced the first Activity into
     * existence: usually Dart lost the race while loading settings and themes
     * off disk and everything worked, but when it won, `await
     * SystemChrome.setPreferredOrientations` never returned and the app sat on
     * its splash screen for good.
     *
     * `FlutterActivityAndFragmentDelegate.doInitialFlutterViewRun` starts the
     * entrypoint itself whenever the engine is not already executing Dart, so
     * the first Activity does it in the right order. The engine still belongs
     * to the process, and Dart keeps running after that Activity is destroyed.
     */
    override fun onCreate() {
        super.onCreate()
        flutterEngine = FlutterEngine(this)
        serviceChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        serviceChannel.setMethodCallHandler { call, result ->
            try {
                handle(call, result)
            } catch (e: Exception) {
                result.error("easysend", e.message, call.method)
            }
        }
    }

    fun attachActivity(value: MainActivity) {
        activity = value
    }

    fun detachActivity(value: MainActivity) {
        if (activity === value) activity = null
    }

    private fun handle(call: MethodCall, result: MethodChannel.Result) {
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
                startService(Intent(this, TransferService::class.java).apply {
                    action = TransferService.ACTION_STOP
                })
                result.success(true)
            }

            "takeServiceTimeout" -> result.success(takeServiceTimeout())

            "openFile" -> result.success(
                activity?.openFile(call.argument<String>("path")) ?: false,
            )

            "openFolder" -> result.success(
                activity?.openFolder(call.argument<String>("path")) ?: false,
            )

            "acquireMulticast" -> {
                acquireMulticast()
                result.success(true)
            }

            "releaseMulticast" -> {
                releaseMulticast()
                result.success(true)
            }

            else -> result.notImplemented()
        }
    }

    fun reportServiceTimeout(fgsType: Int) {
        getSharedPreferences(SERVICE_PREFS, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(SERVICE_TIMED_OUT, true)
            .apply()
        serviceChannel.invokeMethod(
            "serviceTimeout",
            fgsType,
            object : MethodChannel.Result {
                override fun success(result: Any?) = clearServiceTimeout()
                override fun error(code: String, message: String?, details: Any?) = Unit
                override fun notImplemented() = Unit
            },
        )
    }

    fun takeServiceTimeout(): Boolean {
        val prefs = getSharedPreferences(SERVICE_PREFS, Context.MODE_PRIVATE)
        val timedOut = prefs.getBoolean(SERVICE_TIMED_OUT, false)
        if (timedOut) clearServiceTimeout()
        return timedOut
    }

    private fun clearServiceTimeout() {
        getSharedPreferences(SERVICE_PREFS, Context.MODE_PRIVATE)
            .edit()
            .remove(SERVICE_TIMED_OUT)
            .apply()
    }

    fun acquireMulticast() {
        if (multicastLock?.isHeld == true) return
        val wifi = getSystemService(Context.WIFI_SERVICE) as WifiManager
        multicastLock = wifi.createMulticastLock("EasySend::discovery").apply {
            setReferenceCounted(false)
            acquire()
        }
    }

    fun releaseMulticast() {
        multicastLock?.let { if (it.isHeld) it.release() }
        multicastLock = null
    }
}
