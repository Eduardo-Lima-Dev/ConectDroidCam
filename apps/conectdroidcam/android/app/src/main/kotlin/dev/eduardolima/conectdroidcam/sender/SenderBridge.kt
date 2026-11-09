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
 * listModes, localAddresses, startPreview, stopPreview, startStreaming(width, height, fps),
 * setFps(fps), stopStreaming.
 *
 * EventChannel `cdc/sender/events`: mapas com `event` = client | stats | rotation | error.
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

    /** FPS máximo da resolução em uso; limita o que `setFps` aceita. */
    private var streamMaxFps = DEFAULT_FPS

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
                "listModes" -> listModes(result)
                "localAddresses" -> result.success(localAddresses())
                "startPreview" -> startPreview(result)
                "stopPreview" -> {
                    stopAll()
                    result.success(null)
                }
                "startStreaming" -> startStreaming(
                    call.argument<Int>("width"),
                    call.argument<Int>("height"),
                    call.argument<Int>("fps"),
                    result,
                )
                "setFps" -> setFps(call.argument<Int>("fps"), result)
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

    private fun cameraModes(cam: CameraController): List<Map<String, Any?>> =
        CodecSupport.modes(cam.encoderSizes()) { cam.maxFps(it) }

    private fun listModes(result: MethodChannel.Result) {
        if (!hasCameraPermission()) return result.error("permission", "Sem permissão de câmera", null)
        val cam = ensureCamera()
        result.success(mapOf("modes" to cameraModes(cam), "fpsOptions" to cam.fixedFpsOptions()))
    }

    /** 0, 1, 2 ou 3 = Surface.ROTATION_0, 90, 180 ou 270. */
    @Suppress("DEPRECATION")
    private fun displayRotation(): Int = activity.windowManager.defaultDisplay.rotation

    /** A tela girou: o Flutter precisa reorientar a prévia. */
    fun onConfigurationChanged() {
        events?.success(mapOf("event" to "rotation", "displayRotation" to displayRotation()))
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
                            mapOf(
                                "textureId" to it.textureId,
                                "width" to it.width,
                                "height" to it.height,
                                "sensorOrientation" to it.sensorOrientation,
                                "displayRotation" to displayRotation(),
                            ),
                        )
                    },
                    onFailure = { result.error("camera", it.message ?: "Falha ao abrir a câmera", null) },
                )
            }
        }
    }

    // --- Transmissão --------------------------------------------------------------------

    private fun startStreaming(width: Int?, height: Int?, fps: Int?, result: MethodChannel.Result) {
        if (width == null || height == null || fps == null) {
            return result.error("argument", "Informe largura, altura e FPS", null)
        }
        val cam = camera ?: return result.error("state", "Abra a prévia antes de transmitir", null)
        if (encoder != null) return result.error("state", "Já está transmitindo", null)

        val modes = cameraModes(cam)
        val mode = modes.firstOrNull { it["width"] == width && it["height"] == height }
        if (mode == null || mode["available"] != true) {
            return result.error("unsupported", "Resolução indisponível neste aparelho", null)
        }
        val maxFps = mode["maxFps"] as Int
        if (fps !in cam.fixedFpsOptions() || fps > maxFps) {
            return result.error("unsupported", "FPS indisponível nesta resolução", null)
        }

        val bitrate = bitrateFor(width, height)
        val newServer = StreamServer(PORT, APP_VERSION, this)
        val newEncoder = VideoEncoder(width, height, fps, bitrate, this)
        // Atribuídos antes de iniciar: o codificador entrega o SPS/PPS logo ao começar, e
        // `onConfig` precisa encontrar o servidor, senão a configuração se perde.
        server = newServer
        encoder = newEncoder
        try {
            newServer.setStream(width, height, fps, bitrate)
            newServer.setProfiles(CodecSupport.namedAvailability(modes))
            newServer.start()
            newEncoder.start()
        } catch (e: Exception) {
            newServer.stop()
            newEncoder.stop()
            server = null
            encoder = null
            return result.error("start", e.message ?: "Não foi possível iniciar a transmissão", null)
        }

        streamMaxFps = maxFps
        cam.targetFps = fps
        cam.attachEncoder(newEncoder.inputSurface) { outcome ->
            main.post {
                outcome.fold(
                    onSuccess = {
                        activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        startStats()
                        result.success(
                            mapOf(
                                "width" to width,
                                "height" to height,
                                "fps" to fps,
                                "bitrateKbps" to bitrate,
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

    /** Muda o FPS com a transmissão ligada, sem reiniciar câmera nem codificador. */
    private fun setFps(fps: Int?, result: MethodChannel.Result) {
        val cam = camera ?: return result.error("state", "Abra a prévia primeiro", null)
        if (fps == null || fps !in cam.fixedFpsOptions() || fps > streamMaxFps) {
            return result.error("argument", "FPS inválido para esta resolução: $fps", null)
        }
        cam.setFps(fps) { outcome ->
            main.post {
                outcome.fold(
                    onSuccess = {
                        server?.updateFps(fps)
                        result.success(null)
                    },
                    onFailure = { result.error("camera", it.message ?: "Falha ao mudar o FPS", null) },
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
