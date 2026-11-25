package dev.eduardolima.conectdroidcam.update

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import androidx.work.Constraints
import androidx.work.ExistingPeriodicWorkPolicy
import androidx.work.NetworkType
import androidx.work.PeriodicWorkRequest
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import dev.eduardolima.conectdroidcam.MainActivity
import dev.eduardolima.conectdroidcam.R
import org.json.JSONArray
import java.net.HttpURLConnection
import java.net.URL
import java.util.concurrent.TimeUnit

/**
 * Procura, em segundo plano, uma versão nova nas releases do GitHub e avisa por notificação,
 * mesmo com o app fechado. Tocar na notificação abre o app, onde fica o botão de atualizar.
 *
 * Avisa uma vez por versão: o último build avisado fica guardado. Sem internet, ou com o
 * GitHub fora, não faz nada e tenta de novo na próxima rodada.
 */
class UpdateCheckWorker(context: Context, params: WorkerParameters) : Worker(context, params) {
    override fun doWork(): Result {
        val latest = runCatching { latestApkBuild() }.getOrNull() ?: return Result.success()
        val installed = installedBuild(applicationContext)
        val prefs = applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val alreadyNotified = prefs.getLong(KEY_NOTIFIED, 0L)
        if (latest > installed && latest > alreadyNotified) {
            if (notify(latest)) prefs.edit().putLong(KEY_NOTIFIED, latest).apply()
        }
        return Result.success()
    }

    /** Maior `build-N` publicado que tenha APK; o mesmo critério do app (latestApk). */
    private fun latestApkBuild(): Long? {
        val conn = URL(RELEASES_URL).openConnection() as HttpURLConnection
        conn.connectTimeout = 15_000
        conn.readTimeout = 15_000
        conn.setRequestProperty("Accept", "application/vnd.github+json")
        conn.setRequestProperty("User-Agent", "ConectDroidCam")
        try {
            if (conn.responseCode != 200) return null
            val body = conn.inputStream.bufferedReader().use { it.readText() }
            val releases = JSONArray(body)
            var best: Long? = null
            for (i in 0 until releases.length()) {
                val r = releases.optJSONObject(i) ?: continue
                if (r.optBoolean("draft") || r.optBoolean("prerelease")) continue
                val n = TAG.matchEntire(r.optString("tag_name"))?.groupValues?.get(1)?.toLongOrNull() ?: continue
                val assets = r.optJSONArray("assets") ?: continue
                val hasApk = (0 until assets.length()).any {
                    assets.optJSONObject(it)?.optString("name")?.lowercase()?.endsWith(".apk") == true
                }
                if (hasApk && (best == null || n > best)) best = n
            }
            return best
        } finally {
            conn.disconnect()
        }
    }

    /** Devolve se a notificação foi mostrada (sem a permissão, o Android a bloqueia). */
    private fun notify(build: Long): Boolean {
        val ctx = applicationContext
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ctx.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED
        ) {
            return false
        }
        val manager = ctx.getSystemService(NotificationManager::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            manager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "Atualizações", NotificationManager.IMPORTANCE_DEFAULT).apply {
                    description = "Aviso de versão nova do ConectDroidCam"
                },
            )
        }
        val open = PendingIntent.getActivity(
            ctx,
            0,
            Intent(ctx, MainActivity::class.java).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        @Suppress("DEPRECATION")
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            android.app.Notification.Builder(ctx, CHANNEL_ID)
        } else {
            android.app.Notification.Builder(ctx)
        }
        val notification = builder
            .setSmallIcon(R.drawable.ic_stat_cdc)
            .setContentTitle("Nova versão do ConectDroidCam")
            .setContentText("O build $build está disponível. Toque para atualizar.")
            .setContentIntent(open)
            .setAutoCancel(true)
            .build()
        manager.notify(NOTIFICATION_ID, notification)
        return true
    }

    companion object {
        private const val RELEASES_URL =
            "https://api.github.com/repos/Eduardo-Lima-Dev/ConectDroidCam/releases?per_page=20"
        private val TAG = Regex("^build-(\\d+)$")
        private const val PREFS = "cdc_atualizacao"
        private const val KEY_NOTIFIED = "ultimo_build_avisado"
        private const val CHANNEL_ID = "atualizacoes"
        private const val NOTIFICATION_ID = 4710
        private const val WORK_NAME = "cdc-procurar-atualizacao"

        @Suppress("DEPRECATION")
        fun installedBuild(ctx: Context): Long {
            val pkg = ctx.packageManager.getPackageInfo(ctx.packageName, 0)
            return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) pkg.longVersionCode else pkg.versionCode.toLong()
        }

        /** Agenda a verificação a cada 6 horas, só com internet. Agendar de novo não duplica. */
        fun schedule(ctx: Context) {
            val request = PeriodicWorkRequest.Builder(UpdateCheckWorker::class.java, 6, TimeUnit.HOURS)
                .setConstraints(Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build())
                .build()
            WorkManager.getInstance(ctx)
                .enqueueUniquePeriodicWork(WORK_NAME, ExistingPeriodicWorkPolicy.KEEP, request)
        }
    }
}
