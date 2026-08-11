package a.a.easysend

import android.app.Application
import android.content.Context
import android.net.wifi.WifiManager

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
