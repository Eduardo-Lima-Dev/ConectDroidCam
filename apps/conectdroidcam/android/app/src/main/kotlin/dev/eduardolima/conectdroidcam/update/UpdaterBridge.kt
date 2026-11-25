package dev.eduardolima.conectdroidcam.update

import android.app.Activity
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageInstaller
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.provider.Settings
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Instala uma versão nova do app baixada das releases do GitHub, sem loja.
 *
 * O download é feito pelo Flutter; aqui só se informa a versão instalada, a pasta para o
 * arquivo e se o usuário já permitiu "instalar apps desconhecidos" para o ConectDroidCam. A
 * instalação usa o `PackageInstaller` do Android, que sempre pede a confirmação do usuário.
 * O Android só aceita a atualização se ela tiver a mesma assinatura da versão instalada.
 *
 * MethodChannel `cdc/updater`: info, canInstall, openInstallSettings, downloadDir,
 * install(path). O resultado da instalação volta pelo método `installStatus` (do lado nativo
 * para o Flutter), com `status` = pendingUser | success | conflict | failure e `message`.
 */
class UpdaterBridge(private val activity: Activity, engine: FlutterEngine) :
    MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL)
    private val main = Handler(Looper.getMainLooper())
    private var receiverRegistered = false

    init {
        channel.setMethodCallHandler(this)
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "info" -> result.success(info())
                "canInstall" -> result.success(canInstall())
                "openInstallSettings" -> {
                    openInstallSettings()
                    result.success(null)
                }
                "downloadDir" -> result.success(downloadDir().absolutePath)
                "install" -> {
                    val path = call.argument<String>("path")
                        ?: return result.error("argument", "Informe o caminho do APK", null)
                    install(File(path))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("updater", e.message ?: e.javaClass.simpleName, null)
        }
    }

    @Suppress("DEPRECATION")
    private fun info(): Map<String, Any?> {
        val pm = activity.packageManager
        val pkg = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            pm.getPackageInfo(activity.packageName, PackageManager.PackageInfoFlags.of(0))
        } else {
            pm.getPackageInfo(activity.packageName, 0)
        }
        val code = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) pkg.longVersionCode else pkg.versionCode.toLong()
        return mapOf("versionCode" to code, "versionName" to pkg.versionName)
    }

    /** O usuário já permitiu que o ConectDroidCam instale apps? (Android 8+ exige.) */
    private fun canInstall(): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.O || activity.packageManager.canRequestPackageInstalls()

    private fun openInstallSettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            activity.startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES, Uri.parse("package:${activity.packageName}")),
            )
        }
    }

    /** Pasta privada do app para o APK baixado; apagada a cada atualização. */
    private fun downloadDir(): File = File(activity.cacheDir, "atualizacao").apply { mkdirs() }

    private fun install(apk: File) {
        if (!apk.isFile) throw IllegalArgumentException("APK não encontrado: ${apk.path}")
        registerReceiver()
        val installer = activity.packageManager.packageInstaller
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL).apply {
            setAppPackageName(activity.packageName)
            setSize(apk.length())
        }
        val sessionId = installer.createSession(params)
        installer.openSession(sessionId).use { session ->
            apk.inputStream().use { input ->
                session.openWrite("ConectDroidCam.apk", 0, apk.length()).use { output ->
                    input.copyTo(output)
                    session.fsync(output)
                }
            }
            val callback = Intent(ACTION_STATUS).setPackage(activity.packageName)
            val flags = PendingIntent.FLAG_UPDATE_CURRENT or
                (if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) PendingIntent.FLAG_MUTABLE else 0)
            val pending = PendingIntent.getBroadcast(activity, sessionId, callback, flags)
            session.commit(pending.intentSender)
        }
    }

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
            val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)
            when (status) {
                PackageInstaller.STATUS_PENDING_USER_ACTION -> {
                    // O Android quer a confirmação do usuário: abre a tela de instalação.
                    @Suppress("DEPRECATION")
                    val confirm = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        intent.getParcelableExtra(Intent.EXTRA_INTENT, Intent::class.java)
                    } else {
                        intent.getParcelableExtra(Intent.EXTRA_INTENT)
                    }
                    confirm?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    confirm?.let { activity.startActivity(it) }
                    report("pendingUser", null)
                }
                PackageInstaller.STATUS_SUCCESS -> report("success", null)
                PackageInstaller.STATUS_FAILURE_CONFLICT -> report("conflict", message)
                PackageInstaller.STATUS_FAILURE_ABORTED -> report("aborted", message)
                else -> report("failure", message)
            }
        }
    }

    private fun report(status: String, message: String?) {
        main.post { channel.invokeMethod("installStatus", mapOf("status" to status, "message" to message)) }
    }

    private fun registerReceiver() {
        if (receiverRegistered) return
        val filter = IntentFilter(ACTION_STATUS)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            activity.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            @Suppress("UnspecifiedRegisterReceiverFlag")
            activity.registerReceiver(receiver, filter)
        }
        receiverRegistered = true
    }

    fun dispose() {
        if (receiverRegistered) {
            runCatching { activity.unregisterReceiver(receiver) }
            receiverRegistered = false
        }
    }

    private companion object {
        const val CHANNEL = "cdc/updater"
        const val ACTION_STATUS = "dev.eduardolima.conectdroidcam.UPDATE_STATUS"
    }
}
