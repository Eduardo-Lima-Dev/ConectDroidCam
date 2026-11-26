package dev.eduardolima.conectdroidcam.sender

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
import dev.eduardolima.conectdroidcam.MainActivity
import dev.eduardolima.conectdroidcam.R

class StreamingService : Service() {
    interface Actions {
        fun stopFromNotification()
        fun switchFromNotification()
    }

    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> actions?.stopFromNotification()
            ACTION_SWITCH -> actions?.switchFromNotification()
            else -> show(
                intent?.getStringExtra(EXTRA_TITLE) ?: "Transmitindo a câmera",
                intent?.getStringExtra(EXTRA_TEXT) ?: "",
                intent?.getBooleanExtra(EXTRA_CAN_SWITCH, false) == true,
            )
        }
        return START_NOT_STICKY
    }

    private fun show(title: String, text: String, canSwitch: Boolean) {
        val manager = getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Transmissão", NotificationManager.IMPORTANCE_LOW).apply {
                    description = "Mostra que a câmera está sendo transmitida e permite parar"
                    setShowBadge(false)
                },
            )
        }
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_SINGLE_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            Notification.Builder(this)
        }
        builder
            .setSmallIcon(R.drawable.ic_stat_cdc)
            .setContentTitle(title)
            .setContentText(text)
            .setContentIntent(open)
            .setOngoing(true)
            .setCategory(Notification.CATEGORY_SERVICE)
            .addAction(Notification.Action.Builder(null, "Parar", serviceIntent(ACTION_STOP, 1)).build())
        if (canSwitch) {
            builder.addAction(Notification.Action.Builder(null, "Trocar câmera", serviceIntent(ACTION_SWITCH, 2)).build())
        }
        val notification = builder.build()
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                startForeground(NOTIFICATION_ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CAMERA)
            } else {
                startForeground(NOTIFICATION_ID, notification)
            }
        } catch (e: Exception) {
            startError = e.message ?: e.javaClass.simpleName
            stopSelf()
            return
        }
        startError = null
        acquireLocks()
    }

    private fun serviceIntent(action: String, code: Int): PendingIntent =
        PendingIntent.getService(
            this,
            code,
            Intent(this, StreamingService::class.java).setAction(action),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )

    @Suppress("DEPRECATION")
    private fun acquireLocks() {
        if (wakeLock == null) {
            wakeLock = getSystemService(PowerManager::class.java)
                .newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "conectdroidcam:transmissao")
                .apply {
                    setReferenceCounted(false)
                    acquire(MAX_LOCK_MS)
                }
        }
        if (wifiLock == null) {
            val mode = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                WifiManager.WIFI_MODE_FULL_LOW_LATENCY
            } else {
                WifiManager.WIFI_MODE_FULL_HIGH_PERF
            }
            wifiLock = applicationContext.getSystemService(WifiManager::class.java)
                ?.createWifiLock(mode, "conectdroidcam:transmissao")
                ?.apply {
                    setReferenceCounted(false)
                    acquire()
                }
        }
    }

    override fun onDestroy() {
        runCatching { wakeLock?.takeIf { it.isHeld }?.release() }
        wakeLock = null
        runCatching { wifiLock?.takeIf { it.isHeld }?.release() }
        wifiLock = null
        super.onDestroy()
    }

    companion object {
        private const val CHANNEL_ID = "transmissao"
        private const val NOTIFICATION_ID = 4822
        private const val ACTION_STOP = "dev.eduardolima.conectdroidcam.PARAR"
        private const val ACTION_SWITCH = "dev.eduardolima.conectdroidcam.TROCAR"
        private const val EXTRA_TITLE = "titulo"
        private const val EXTRA_TEXT = "texto"
        private const val EXTRA_CAN_SWITCH = "podeTrocar"
        private const val MAX_LOCK_MS = 6 * 60 * 60 * 1000L

        @Volatile
        var actions: Actions? = null

        @Volatile
        var startError: String? = null
            private set

        fun show(context: Context, title: String, text: String, canSwitch: Boolean): Boolean {
            val intent = Intent(context, StreamingService::class.java)
                .putExtra(EXTRA_TITLE, title)
                .putExtra(EXTRA_TEXT, text)
                .putExtra(EXTRA_CAN_SWITCH, canSwitch)
            return try {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    context.startForegroundService(intent)
                } else {
                    context.startService(intent)
                }
                true
            } catch (e: Exception) {
                startError = e.message ?: e.javaClass.simpleName
                false
            }
        }

        fun hide(context: Context) {
            context.stopService(Intent(context, StreamingService::class.java))
        }
    }
}
