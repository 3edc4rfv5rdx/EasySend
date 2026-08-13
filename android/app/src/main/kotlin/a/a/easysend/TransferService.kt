package a.a.easysend

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import androidx.core.app.NotificationCompat

/**
 * Foreground service that keeps the app alive while a transfer runs, or while
 * background receiving is switched on.
 *
 * A backgrounded process can be dropped at any time, and once the screen goes
 * off Doze cuts its network and lets Wi-Fi sleep. The service plus the two
 * locks below are what keep a transfer going after the app is swiped away.
 */
class TransferService : Service() {

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    companion object {
        const val CHANNEL_ID = "easysend_transfer"
        const val NOTIFICATION_ID = 1

        const val ACTION_START = "start"
        const val ACTION_UPDATE = "update"
        const val ACTION_STOP = "stop"

        // The two buttons on the ongoing notification. They only carry the
        // press to Dart, which owns transfers and the exit.
        const val ACTION_NOTIFY_STOP = "notify_stop"
        const val ACTION_NOTIFY_EXIT = "notify_exit"

        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        const val EXTRA_PROGRESS = "progress"
        const val EXTRA_STOP_LABEL = "stopLabel"
        const val EXTRA_EXIT_LABEL = "exitLabel"
        const val EXTRA_EXIT_NEEDS_APP = "exitNeedsApp"

        // Distinct request codes, or the two buttons would share one
        // PendingIntent and the second would silently reuse the first's extras.
        private const val REQUEST_CONTENT = 0
        private const val REQUEST_STOP = 1
        private const val REQUEST_EXIT = 2
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                releaseLocks()
                stopForeground(STOP_FOREGROUND_REMOVE)
                stopSelf()
                return START_NOT_STICKY
            }
            // Nothing is decided here: Dart cancels the transfer or runs the
            // exit, and the notification follows from the state that leaves.
            ACTION_NOTIFY_STOP -> {
                (application as EasySendApplication).notifyDart("notificationStop")
                return START_NOT_STICKY
            }
            ACTION_NOTIFY_EXIT -> {
                (application as EasySendApplication).notifyDart("notificationExit")
                return START_NOT_STICKY
            }
            else -> {
                val title = intent?.getStringExtra(EXTRA_TITLE) ?: "EasySend"
                val text = intent?.getStringExtra(EXTRA_TEXT) ?: ""
                val progress = intent?.getIntExtra(EXTRA_PROGRESS, -1) ?: -1
                // Labels are localized in Dart. Without them there is nothing
                // truthful to write on a button, so none is drawn.
                val stopLabel = intent?.getStringExtra(EXTRA_STOP_LABEL).orEmpty()
                val exitLabel = intent?.getStringExtra(EXTRA_EXIT_LABEL).orEmpty()
                val exitNeedsApp = intent?.getBooleanExtra(EXTRA_EXIT_NEEDS_APP, false) ?: false
                startForegroundWith(title, text, progress, stopLabel, exitLabel, exitNeedsApp)
                // progress >= 0 is an active transfer. ACTION_UPDATE must be
                // sufficient after an idle listener start or service recreation.
                if (progress in 0..100) {
                    acquireOrRefreshTransferLocks()
                } else {
                    releaseLocks()
                }
            }
        }
        // Do not resurrect the service with a null intent: a transfer that died
        // with its process cannot be resumed anyway.
        return START_NOT_STICKY
    }

    private fun startForegroundWith(
        title: String,
        text: String,
        progress: Int,
        stopLabel: String,
        exitLabel: String,
        exitNeedsApp: Boolean,
    ) {
        createChannel()

        val pending = openAppIntent(REQUEST_CONTENT, exitOnOpen = false)

        val builder = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle(title)
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_upload)
            .setContentIntent(pending)
            .setOngoing(true)
            .setSilent(true)
            .setPriority(NotificationCompat.PRIORITY_LOW)

        // progress < 0 means "no transfer running", e.g. the idle listener.
        if (progress in 0..100) {
            builder.setProgress(100, progress, false)
            // Only while something is running is there anything to stop, and
            // stopping it leaves background receiving switched on.
            if (stopLabel.isNotEmpty()) {
                builder.addAction(0, stopLabel, serviceAction(REQUEST_STOP, ACTION_NOTIFY_STOP))
            }
        }
        // An exit that has a question to ask has to be asked on screen, so that
        // button opens the app and the app runs the same exit as ✕. With
        // nothing to confirm it acts from the shade and the app stays away.
        if (exitLabel.isNotEmpty()) {
            builder.addAction(
                0,
                exitLabel,
                if (exitNeedsApp) {
                    openAppIntent(REQUEST_EXIT, exitOnOpen = true)
                } else {
                    serviceAction(REQUEST_EXIT, ACTION_NOTIFY_EXIT)
                },
            )
        }

        val notification: Notification = builder.build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, foregroundType(progress))
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    /**
     * Opens the app, optionally asking it to run the exit once it is there.
     *
     * Since Android 12 a notification may not start an Activity by way of a
     * service or broadcast, so a button that has to show something goes to the
     * Activity directly.
     */
    private fun openAppIntent(requestCode: Int, exitOnOpen: Boolean): PendingIntent {
        val intent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
            if (exitOnOpen) putExtra(MainActivity.EXTRA_EXIT_REQUESTED, true)
        }
        return PendingIntent.getActivity(
            this, requestCode, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    // Deliberately not built with apply: inside it the name `action` resolves to
    // Intent's own property rather than to this parameter, and the assignment
    // would quietly become a no-op, leaving the button with no action at all.
    private fun serviceAction(requestCode: Int, action: String): PendingIntent {
        val intent = Intent(this, TransferService::class.java)
        intent.action = action
        return PendingIntent.getService(
            this, requestCode, intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }

    // Android 15 limits dataSync services to six hours per rolling day. An
    // idle LAN listener is not a data transfer, so Android 14+ uses the
    // explicitly declared specialUse type for that user-enabled mode. Older
    // releases do not know specialUse and do not enforce the dataSync quota.
    private fun foregroundType(progress: Int): Int =
        if (progress in 0..100 || Build.VERSION.SDK_INT < Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        } else {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE
        }

    private fun createChannel() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Transfers",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            description = "Ongoing file transfers"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    /**
     * Partial wake lock keeps the CPU running with the screen off; the
     * high-performance Wi-Fi lock stops the radio from dozing between packets.
     */
    private fun acquireOrRefreshTransferLocks() {
        if (wakeLock == null) {
            val power = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = power.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "EasySend::transfer").apply {
                setReferenceCounted(false)
            }
        }
        // A timed wake lock may have expired during a very long transfer; each
        // progress update re-enters here and reacquires it when necessary.
        wakeLock?.let { if (!it.isHeld) it.acquire(TIMEOUT_MS) }
        if (wifiLock == null) {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
            wifiLock = wifi.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "EasySend::wifi").apply {
                setReferenceCounted(false)
            }
        }
        // High-performance Wi-Fi is held only in active mode, never by the
        // idle background listener.
        wifiLock?.let { if (!it.isHeld) it.acquire() }
    }

    private fun releaseLocks() {
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        wifiLock?.let { if (it.isHeld) it.release() }
        wifiLock = null
    }

    override fun onTimeout(startId: Int, fgsType: Int) {
        // Android gives only a few seconds before raising a fatal
        // RemoteServiceException. Stop synchronously, and leave a durable
        // notice for Dart in case no Activity/channel is attached right now.
        releaseLocks()
        stopForeground(STOP_FOREGROUND_REMOVE)
        (application as EasySendApplication).reportServiceTimeout(fgsType)
        stopSelf()
    }

    override fun onDestroy() {
        releaseLocks()
        // Dart has no other way of learning this. Android destroys the service
        // on its own — with a removed task, or under memory pressure — and a
        // Dart side that still believes it is up will never post the
        // notification again, leaving a receiver nothing on screen represents.
        (application as EasySendApplication).notifyDart("serviceGone")
        super.onDestroy()
    }
}

// Safety net: a lock is never meant to outlive a transfer, but a crashed
// transfer must not drain the battery until reboot.
private const val TIMEOUT_MS = 6L * 60L * 60L * 1000L
