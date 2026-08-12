package a.a.easysend

import android.app.Application
import android.content.Context
import android.net.wifi.WifiManager
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
    private var serviceChannel: MethodChannel? = null

    companion object {
        private const val SERVICE_PREFS = "easysend_service"
        private const val SERVICE_TIMED_OUT = "timed_out"
    }

    fun attachServiceChannel(channel: MethodChannel) {
        serviceChannel = channel
    }

    fun detachServiceChannel(channel: MethodChannel) {
        if (serviceChannel === channel) serviceChannel = null
    }

    fun reportServiceTimeout(fgsType: Int) {
        getSharedPreferences(SERVICE_PREFS, Context.MODE_PRIVATE)
            .edit()
            .putBoolean(SERVICE_TIMED_OUT, true)
            .apply()
        serviceChannel?.invokeMethod(
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
