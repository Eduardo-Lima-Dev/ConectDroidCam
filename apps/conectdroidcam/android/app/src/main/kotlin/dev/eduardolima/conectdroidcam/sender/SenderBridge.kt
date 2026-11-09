package dev.eduardolima.conectdroidcam.sender

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.view.WindowManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.net.Inet4Address
import java.net.NetworkInterface

/**
 * Liga a interface Flutter ao emissor nativo. Contrato:
 *
 * MethodChannel `cdc/sender`: hasCameraPermission, requestCameraPermission,
 * listProfiles, localAddresses, startPreview, stopPreview, startStreaming(profile),
 * stopStreaming.
 *
 * EventChannel `cdc/sender/events`: mapas com `event` = client | stats | error.
 */
class SenderBridge(private val activity: Activity, engine: FlutterEngine) :
    MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler,
    StreamServer.Listener,
    VideoEncoder.Listener {
    private val main = Handler(Looper.getMainLooper())
    private val textures = engine.renderer
    private var events: EventChannel.EventSink? = null

    private var camera: CameraController? = null
    private var encoder: VideoEncoder? = null
    private var server: StreamServer? = null
    private var pendingPermission: MethodChannel.Result? = null
    private var statsTask: Runnable? = null
    private var lastCounters: StreamServer.Counters? = null
    private var lastStatsAtMs = 0L

    init {
        MethodChannel(engine.dartExecutor.binaryMessenger, METHODS).setMethodCallHandler(this)
        EventChannel(engine.dartExecutor.binaryMessenger, EVENTS).setStreamHandler(this)
    }

    private fun hasCameraPermission() =
        activity.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED

    private fun ensureCamera(): CameraController =
        camera ?: CameraController(activity, textures) { message -> fatal(message) }.also { camera = it }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        try {
            when (call.method) {
                "hasCameraPermission" -> result.success(hasCameraPermission())
                "requestCameraPermission" -> requestCameraPermission(result)
                "listProfiles" -> listProfiles(result)
                "localAddresses" -> result.success(localAddresses())
                "startPreview" -> startPreview(result)
                "stopPreview" -> {
                    stopAll()
                    result.success(null)
                }
                "startStreaming" -> startStreaming(call.argument<String>("profile"), result)
                "stopStreaming" -> {
                    stopStreaming()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (e: Exception) {
            result.error("native_error", e.message ?: e.javaClass.simpleName, null)
        }
    }

    // --- Permissão --------------------------------------------------------------------

    private fun requestCameraPermission(result: MethodChannel.Result) {
        if (hasCameraPermission()) return result.success(true)
        pendingPermission?.success(false)
        pendingPermission = result
        activity.requestPermissions(arrayOf(Manifest.permission.CAMERA), REQUEST_CAMERA)
    }

    fun onPermissionResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != REQUEST_CAMERA) return
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingPermission?.success(granted)
        pendingPermission = null
    }

    // --- Perfis e rede ------------------------------------------------------------------

    private fun listProfiles(result: MethodChannel.Result) {
        if (!hasCameraPermission()) return result.error("permission", "Sem permissão de câmera", null)
        result.success(CodecSupport.availability(ensureCamera().encoderSizes()))
    }

    private fun localAddresses(): List<Map<String, String>> =
        NetworkInterface.getNetworkInterfaces().toList()
            .filter { runCatching { it.isUp && !it.isLoopback }.getOrDefault(false) }
            .flatMap { net ->
                net.inetAddresses.toList().filterIsInstance<Inet4Address>().map {
                    mapOf("interface" to net.name, "address" to (it.hostAddress ?: ""))
                }
            }

    // --- Prévia -------------------------------------------------------------------------

    private fun startPreview(result: MethodChannel.Result) {
        if (!hasCameraPermission()) return result.error("permission", "Sem permissão de câmera", null)
        ensureCamera().startPreview { outcome ->
            main.post {
                outcome.fold(
                    onSuccess = {
                        result.success(
                            mapOf("textureId" to it.textureId, "width" to it.width, "height" to it.height),
                        )
                    },
                    onFailure = { result.error("camera", it.message ?: "Falha ao abrir a câmera", null) },
                )
            }
        }
    }

    // --- Transmissão --------------------------------------------------------------------

    private fun startStreaming(profileId: String?, result: MethodChannel.Result) {
        val profile = profileId?.let { Profile.fromId(it) }
            ?: return result.error("argument", "Perfil inválido: $profileId", null)
        val cam = camera ?: return result.error("state", "Abra a prévia antes de transmitir", null)
        if (encoder != null) return result.error("state", "Já está transmitindo", null)
        if (CodecSupport.availability(cam.encoderSizes()).first { it["profile"] == profile.id }["available"] != true) {
            return result.error("unsupported", "Perfil indisponível neste aparelho", null)
        }

        val newServer = StreamServer(PORT, APP_VERSION, this)
        val newEncoder = VideoEncoder(profile, this)
        try {
            newServer.setStream(profile)
            newServer.setProfiles(CodecSupport.availability(cam.encoderSizes()))
            newServer.start()
            newEncoder.start()
        } catch (e: Exception) {
            newServer.stop()
            newEncoder.stop()
            return result.error("start", e.message ?: "Não foi possível iniciar a transmissão", null)
        }
        server = newServer
        encoder = newEncoder

        cam.attachEncoder(newEncoder.inputSurface) { outcome ->
            main.post {
                outcome.fold(
                    onSuccess = {
                        activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        startStats()
                        result.success(
                            mapOf(
                                "profile" to profile.id,
                                "width" to profile.width,
                                "height" to profile.height,
                                "fps" to STREAM_FPS,
                                "bitrateKbps" to profile.bitrateKbps,
                                "port" to PORT,
                            ),
                        )
                    },
                    onFailure = {
                        stopStreaming()
                        result.error("camera", it.message ?: "Falha ao ligar a câmera ao codificador", null)
                    },
                )
            }
        }
    }

    private fun stopStreaming() {
        statsTask?.let { main.removeCallbacks(it) }
        statsTask = null
        lastCounters = null
        camera?.detachEncoder()
        encoder?.stop()
        encoder = null
        server?.stop()
        server = null
        main.post { activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) }
    }

    fun stopAll() {
        stopStreaming()
        camera?.stop()
        camera = null
    }

    private fun fatal(message: String) {
        main.post {
            stopAll()
            events?.success(mapOf("event" to "error", "message" to message))
        }
    }

    // --- Estatísticas -------------------------------------------------------------------

    private fun startStats() {
        lastCounters = server?.counters()
        lastStatsAtMs = System.currentTimeMillis()
        val task = object : Runnable {
            override fun run() {
                val current = server?.counters() ?: return
                val previous = lastCounters
                val now = System.currentTimeMillis()
                val seconds = (now - lastStatsAtMs) / 1000.0
                if (previous != null && seconds > 0) {
                    events?.success(
                        mapOf(
                            "event" to "stats",
                            "fps" to (current.frames - previous.frames) / seconds,
                            "bitrateKbps" to ((current.bytes - previous.bytes) * 8.0 / 1000.0 / seconds),
                            "dropped" to current.dropped,
                            "clientConnected" to current.clientConnected,
                        ),
                    )
                }
                lastCounters = current
                lastStatsAtMs = now
                main.postDelayed(this, 1000)
            }
        }
        statsTask = task
        main.postDelayed(task, 1000)
    }

    // --- Callbacks do servidor e do codificador -------------------------------------------

    override fun onClientConnected(peer: String) {
        main.post { events?.success(mapOf("event" to "client", "connected" to true, "peer" to peer)) }
    }

    override fun onClientDisconnected() {
        main.post { events?.success(mapOf("event" to "client", "connected" to false)) }
    }

    override fun onKeyframeNeeded() {
        encoder?.requestKeyframe()
    }

    override fun onConfig(data: ByteArray) {
        server?.onConfig(data)
    }

    override fun onFrame(data: ByteArray, ptsUs: Long, keyframe: Boolean) {
        server?.onVideo(data, ptsUs, keyframe)
    }

    override fun onError(error: Exception) {
        fatal("Erro do codificador: ${error.message}")
    }

    // --- EventChannel -------------------------------------------------------------------

    override fun onListen(arguments: Any?, sink: EventChannel.EventSink?) {
        events = sink
    }

    override fun onCancel(arguments: Any?) {
        events = null
    }

    companion object {
        const val METHODS = "cdc/sender"
        const val EVENTS = "cdc/sender/events"
        const val PORT = 47821
        const val APP_VERSION = "0.1.0"
        private const val REQUEST_CAMERA = 4821
    }
}
