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

        const val EXTRA_TITLE = "title"
        const val EXTRA_TEXT = "text"
        const val EXTRA_PROGRESS = "progress"
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
            else -> {
                val title = intent?.getStringExtra(EXTRA_TITLE) ?: "EasySend"
                val text = intent?.getStringExtra(EXTRA_TEXT) ?: ""
                val progress = intent?.getIntExtra(EXTRA_PROGRESS, -1) ?: -1
                startForegroundWith(title, text, progress)
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

    private fun startForegroundWith(title: String, text: String, progress: Int) {
        createChannel()

        val tapIntent = Intent(this, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val pending = PendingIntent.getActivity(
            this, 0, tapIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

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
        }

        val notification: Notification = builder.build()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
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

    override fun onDestroy() {
        releaseLocks()
        super.onDestroy()
    }
}

// Safety net: a lock is never meant to outlive a transfer, but a crashed
// transfer must not drain the battery until reboot.
private const val TIMEOUT_MS = 6L * 60L * 60L * 1000L
