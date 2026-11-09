package dev.eduardolima.conectdroidcam.sender

import android.Manifest
import android.app.Activity
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import android.util.Size
import android.view.WindowManager
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.json.JSONArray
import org.json.JSONObject
import java.net.Inet4Address
import java.net.NetworkInterface

/**
 * Liga a interface Flutter ao emissor nativo. Contrato:
 *
 * MethodChannel `cdc/sender`: hasCameraPermission, requestCameraPermission,
 * listModes, localAddresses, startPreview, stopPreview, startStreaming(width, height, fps),
 * setFps(fps), switchCamera(front), stopStreaming.
 *
 * EventChannel `cdc/sender/events`: mapas com `event` = client | stats | rotation | discovery | error
 * | remote (o computador ligou, desligou ou mudou a transmissão) | camera (o computador trocou a câmera).
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

    /** A transmissão foi ligada por ordem do computador: ela acaba quando ele desconecta. */
    private var startedByRemote = false
    private val advertiser = NsdAdvertiser(activity)
    private var pendingPermission: MethodChannel.Result? = null
    private var statsTask: Runnable? = null
    private var lastCounters: StreamServer.Counters? = null
    private var lastStatsAtMs = 0L

    /** FPS máximo da resolução em uso; limita o que `setFps` aceita. */
    private var streamMaxFps = DEFAULT_FPS

    /** Tamanho que o codificador usa agora; `null` sem transmissão. */
    private var streamSize: Size? = null

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
                "switchCamera" -> switchCamera(call.argument<Boolean>("front"), result)
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

    /**
     * Graus, no sentido horário, que o quadro do codificador precisa girar para ficar em pé na
     * posição atual do aparelho. O codificador entrega a imagem na orientação do sensor, que é
     * sempre horizontal; com o celular em pé ela chega deitada. É a fórmula do Camera2: câmera
     * traseira `sensor - tela`, frontal `sensor + tela`, que também espelha.
     */
    private fun videoRotation(cam: CameraController): Int {
        val tela = displayRotation() * 90
        val graus = if (cam.isFrontFacing) cam.sensorOrientation + tela else cam.sensorOrientation - tela
        return (graus % 360 + 360) % 360
    }

    /** A tela girou: o Flutter reorienta a prévia e o computador, o vídeo enviado. */
    fun onConfigurationChanged() {
        events?.success(mapOf("event" to "rotation", "displayRotation" to displayRotation()))
        val cam = camera ?: return
        server?.updateRotation(videoRotation(cam))
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
                        startListening()
                        result.success(previewMap(it))
                    },
                    onFailure = { result.error("camera", it.message ?: "Falha ao abrir a câmera", null) },
                )
            }
        }
    }

    private fun previewMap(p: CameraController.Preview) = mapOf(
        "textureId" to p.textureId,
        "width" to p.width,
        "height" to p.height,
        "sensorOrientation" to p.sensorOrientation,
        "displayRotation" to displayRotation(),
        "isFront" to p.isFront,
        "canSwitch" to p.canSwitch,
    )

    /**
     * Troca a câmera, com ou sem transmissão. Com ela ligada o codificador não para: o vídeo
     * só fica parado enquanto a câmera nova abre, e a rotação enviada ao computador é refeita.
     */
    private fun switchCamera(front: Boolean?, result: MethodChannel.Result) {
        doSwitchCamera(front) { outcome ->
            outcome.fold(
                onSuccess = { result.success(previewMap(it)) },
                onFailure = { result.error("camera", it.message ?: "Falha ao trocar de câmera", null) },
            )
        }
    }

    /** Troca de câmera pedida pelo celular ou pelo computador; [done] roda na thread principal. */
    private fun doSwitchCamera(front: Boolean?, done: (Result<CameraController.Preview>) -> Unit) {
        val cam = camera ?: return done(Result.failure(IllegalStateException("Abra a prévia primeiro")))
        val wantFront = front ?: !cam.isFrontFacing
        cam.switchFacing(wantFront, streamSize) { outcome ->
            main.post {
                outcome.onSuccess {
                    server?.updateRotation(videoRotation(cam))
                    publishCapabilities()
                }
                done(outcome)
            }
        }
    }

    // --- Transmissão --------------------------------------------------------------------

    private fun startStreaming(width: Int?, height: Int?, fps: Int?, result: MethodChannel.Result) {
        if (width == null || height == null || fps == null) {
            return result.error("argument", "Informe largura, altura e FPS", null)
        }
        doStartStreaming(width, height, fps, remote = false) { outcome ->
            outcome.fold(
                onSuccess = { result.success(it) },
                onFailure = { result.error("start", it.message ?: "Não foi possível iniciar a transmissão", null) },
            )
        }
    }

    /**
     * Liga o codificador e a câmera. Serve ao botão do celular e ao comando do computador
     * ([remote]); [done] roda na thread principal.
     */
    private fun doStartStreaming(
        width: Int,
        height: Int,
        fps: Int,
        remote: Boolean,
        done: (Result<Map<String, Any?>>) -> Unit,
    ) {
        fun fail(message: String) = done(Result.failure(IllegalStateException(message)))

        val cam = camera ?: return fail("Abra a prévia antes de transmitir")
        val currentServer = server ?: return fail("O servidor não está ligado")
        if (encoder != null) return fail("Já está transmitindo")

        val modes = cameraModes(cam)
        val mode = modes.firstOrNull { it["width"] == width && it["height"] == height }
        if (mode == null || mode["available"] != true) {
            return fail("Resolução indisponível neste aparelho")
        }
        val maxFps = mode["maxFps"] as Int
        if (fps !in cam.fixedFpsOptions() || fps > maxFps) {
            return fail("FPS indisponível nesta resolução")
        }

        val bitrate = bitrateFor(width, height)
        val newEncoder = VideoEncoder(width, height, fps, bitrate, this)
        // Atribuído antes de iniciar: o codificador entrega o SPS/PPS logo ao começar, e
        // `onConfig` precisa encontrar o servidor, senão a configuração se perde.
        encoder = newEncoder
        try {
            currentServer.setStream(width, height, fps, bitrate, videoRotation(cam))
            currentServer.setProfiles(CodecSupport.namedAvailability(modes))
            newEncoder.start()
        } catch (e: Exception) {
            newEncoder.stop()
            encoder = null
            currentServer.clearStream()
            return fail(e.message ?: "Não foi possível iniciar a transmissão")
        }

        streamMaxFps = maxFps
        streamSize = Size(width, height)
        startedByRemote = remote
        cam.targetFps = fps
        cam.attachEncoder(newEncoder.inputSurface) { outcome ->
            main.post {
                outcome.fold(
                    onSuccess = {
                        activity.window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                        startStats()
                        publishCapabilities()
                        done(
                            Result.success(
                                mapOf(
                                    "width" to width,
                                    "height" to height,
                                    "fps" to fps,
                                    "bitrateKbps" to bitrate,
                                    "port" to PORT,
                                ),
                            ),
                        )
                    },
                    onFailure = {
                        stopStreaming()
                        fail(it.message ?: "Falha ao ligar a câmera ao codificador")
                    },
                )
            }
        }
    }

    /** Muda o FPS com a transmissão ligada, sem reiniciar câmera nem codificador. */
    private fun setFps(fps: Int?, result: MethodChannel.Result) {
        doSetFps(fps) { outcome ->
            outcome.fold(
                onSuccess = { result.success(null) },
                onFailure = { result.error("argument", it.message ?: "Falha ao mudar o FPS", null) },
            )
        }
    }

    private fun doSetFps(fps: Int?, done: (Result<Unit>) -> Unit) {
        val cam = camera ?: return done(Result.failure(IllegalStateException("Abra a prévia primeiro")))
        if (fps == null || fps !in cam.fixedFpsOptions() || fps > streamMaxFps) {
            return done(Result.failure(IllegalArgumentException("FPS inválido para esta resolução: $fps")))
        }
        cam.setFps(fps) { outcome ->
            main.post {
                outcome.onSuccess { server?.updateFps(fps) }
                done(outcome)
            }
        }
    }

    // --- Servidor e comandos do computador ------------------------------------------------

    /**
     * Liga o servidor e o anúncio na rede assim que a prévia abre, e não só ao transmitir:
     * assim o computador acha o celular, conecta e decide o resto.
     */
    private fun startListening() {
        if (server != null) return
        val newServer = StreamServer(PORT, APP_VERSION, this)
        try {
            newServer.start()
        } catch (e: Exception) {
            events?.success(mapOf("event" to "error", "message" to "Não consegui abrir a porta $PORT: ${e.message}"))
            return
        }
        server = newServer
        publishCapabilities()
        advertiser.start(PORT, APP_VERSION) { name, error ->
            main.post {
                events?.success(
                    mapOf("event" to "discovery", "registered" to (name != null), "name" to name, "error" to error),
                )
            }
        }
    }

    /** Descreve ao computador o que a câmera em uso oferece e se há transmissão. */
    private fun publishCapabilities() {
        val cam = camera ?: return
        val currentServer = server ?: return
        val frame = Protocol.control("capabilities") {
            put(
                "modes",
                JSONArray().also { array ->
                    cameraModes(cam).forEach { m ->
                        array.put(
                            JSONObject().apply {
                                put("width", m["width"])
                                put("height", m["height"])
                                put("available", m["available"])
                                put("maxFps", m["maxFps"])
                                (m["reason"] as? String)?.let { put("reason", it) }
                            },
                        )
                    }
                },
            )
            put("fpsOptions", JSONArray(cam.fixedFpsOptions()))
            put("facing", if (cam.isFrontFacing) "front" else "back")
            put("canSwitch", cam.canSwitch())
            put("streaming", encoder != null)
        }
        currentServer.setCapabilities(frame)
    }

    /** Avisa a interface do celular de uma mudança feita pelo computador. */
    private fun notifyRemoteState() {
        val size = streamSize
        events?.success(
            mapOf(
                "event" to "remote",
                "streaming" to (encoder != null),
                "width" to (size?.width ?: 0),
                "height" to (size?.height ?: 0),
                "fps" to (camera?.targetFps ?: DEFAULT_FPS),
                "bitrateKbps" to (size?.let { bitrateFor(it.width, it.height) } ?: 0),
                "port" to PORT,
            ),
        )
    }

    override fun onCommand(type: String, message: JSONObject) {
        main.post { handleCommand(type, message) }
    }

    private fun handleCommand(type: String, message: JSONObject) {
        fun refuse(reason: String?) = server?.sendError(reason ?: "Não foi possível executar o comando")
        when (type) {
            "stream.start" -> {
                val width = message.optInt("width", 0)
                val height = message.optInt("height", 0)
                val fps = message.optInt("fps", 0)
                doStartStreaming(width, height, fps, remote = true) { outcome ->
                    outcome.fold(onSuccess = { notifyRemoteState() }, onFailure = { refuse(it.message) })
                }
            }
            "stream.stop" -> {
                if (encoder != null) stopStreaming()
                notifyRemoteState()
            }
            "fps.set" -> doSetFps(message.optInt("fps", 0)) { outcome ->
                outcome.fold(onSuccess = { notifyRemoteState() }, onFailure = { refuse(it.message) })
            }
            "camera.switch" -> {
                val front = when (message.optString("facing")) {
                    "front" -> true
                    "back" -> false
                    else -> null
                }
                doSwitchCamera(front) { outcome ->
                    outcome.fold(
                        onSuccess = {
                            events?.success(
                                mapOf("event" to "camera") + previewMap(it),
                            )
                        },
                        onFailure = { refuse(it.message) },
                    )
                }
            }
        }
    }

    private fun stopStreaming() {
        statsTask?.let { main.removeCallbacks(it) }
        statsTask = null
        lastCounters = null
        streamSize = null
        camera?.detachEncoder()
        encoder?.stop()
        encoder = null
        startedByRemote = false
        server?.clearStream()
        publishCapabilities()
        main.post { activity.window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) }
    }

    fun stopAll() {
        stopStreaming()
        advertiser.stop()
        server?.stop()
        server = null
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
        main.post {
            events?.success(mapOf("event" to "client", "connected" to false))
            // Quem ligou a transmissão foi o computador e ele foi embora: ninguém assiste.
            if (startedByRemote && encoder != null) {
                stopStreaming()
                notifyRemoteState()
            }
        }
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
