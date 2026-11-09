package dev.eduardolima.conectdroidcam.sender

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.media.MediaCodec
import android.os.Handler
import android.os.HandlerThread
import android.util.Range
import android.util.Size
import android.view.Surface
import io.flutter.view.TextureRegistry

/**
 * Camera2 com duas saídas: a prévia (textura do Flutter, em resolução baixa) e,
 * durante a transmissão, a superfície do codificador (na resolução escolhida).
 *
 * Callbacks chegam na thread da câmera; quem chama é responsável por voltar à
 * thread principal quando precisar.
 */
class CameraController(
    context: Context,
    private val textures: TextureRegistry,
    private val onFatal: (String) -> Unit,
) {
    data class Preview(
        val textureId: Long,
        val width: Int,
        val height: Int,
        val sensorOrientation: Int,
        val isFront: Boolean,
        /** O aparelho tem câmera frontal e traseira, então dá para trocar. */
        val canSwitch: Boolean,
    )

    private val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager

    /** Câmera em uso. Muda em [switchFacing]. */
    var cameraId: String = pickCameraId(front = false)
        private set
    private var characteristics: CameraCharacteristics = manager.getCameraCharacteristics(cameraId)

    /** Graus, no sentido horário, que a imagem do sensor precisa girar para ficar em pé com o aparelho na posição natural. */
    var sensorOrientation: Int = orientationOf(characteristics)
        private set

    var isFrontFacing: Boolean = isFront(characteristics)
        private set

    private var aeRanges: Array<Range<Int>> = fpsRangesOf(characteristics)

    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var entry: TextureRegistry.SurfaceTextureEntry? = null
    private var previewSurface: Surface? = null
    private var encoderSurface: Surface? = null
    private var preview: Preview? = null

    /** FPS que a câmera deve produzir. Vale para a próxima sessão e para a atual (veja [setFps]). */
    @Volatile
    var targetFps: Int = DEFAULT_FPS

    private fun orientationOf(c: CameraCharacteristics) = c.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90

    private fun isFront(c: CameraCharacteristics) =
        c.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_FRONT

    private fun fpsRangesOf(c: CameraCharacteristics): Array<Range<Int>> =
        c.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES) ?: emptyArray()

    /** Primeira câmera da frente ou de trás; se não houver, qualquer uma. */
    private fun pickCameraId(front: Boolean): String {
        val ids = manager.cameraIdList
        val wanted = if (front) CameraCharacteristics.LENS_FACING_FRONT else CameraCharacteristics.LENS_FACING_BACK
        return ids.firstOrNull { manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) == wanted }
            ?: ids.firstOrNull()
            ?: throw IllegalStateException("Este aparelho não tem câmera")
    }

    /** Id da câmera do lado pedido, ou `null` se o aparelho não a tem. */
    private fun idFor(front: Boolean): String? {
        val wanted = if (front) CameraCharacteristics.LENS_FACING_FRONT else CameraCharacteristics.LENS_FACING_BACK
        return manager.cameraIdList.firstOrNull {
            manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) == wanted
        }
    }

    /** O aparelho tem câmera frontal e traseira? */
    fun canSwitch(): Boolean = idFor(front = true) != null && idFor(front = false) != null

    private fun bind(id: String) {
        cameraId = id
        characteristics = manager.getCameraCharacteristics(id)
        sensorOrientation = orientationOf(characteristics)
        isFrontFacing = isFront(characteristics)
        aeRanges = fpsRangesOf(characteristics)
    }

    private fun streamMap() = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)

    /** Tamanhos que a câmera entrega para um codificador. */
    fun encoderSizes(): List<Size> = encoderSizesOf(characteristics)

    private fun encoderSizesOf(c: CameraCharacteristics): List<Size> {
        val map = c.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP) ?: return emptyList()
        val sizes = map.getOutputSizes(MediaCodec::class.java)
            ?: map.getOutputSizes(SurfaceTexture::class.java)
        return sizes?.toList() ?: emptyList()
    }

    /** FPS máximo que a câmera sustenta no tamanho, segundo a duração mínima de frame. */
    fun maxFps(size: Size): Int = maxFpsOf(characteristics, size)

    private fun maxFpsOf(c: CameraCharacteristics, size: Size): Int {
        val map = c.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP) ?: return DEFAULT_FPS
        val nanos = runCatching { map.getOutputMinFrameDuration(MediaCodec::class.java, size) }
            .getOrElse { map.getOutputMinFrameDuration(SurfaceTexture::class.java, size) }
        return if (nanos > 0) (1_000_000_000.0 / nanos).toInt() else DEFAULT_FPS
    }

    /** FPS fixos que a câmera aceita no modo normal, de [MIN_FPS_OPTION] até [DEFAULT_FPS]. */
    fun fixedFpsOptions(): List<Int> = fixedFpsOf(aeRanges)

    private fun fixedFpsOf(ranges: Array<Range<Int>>): List<Int> =
        ranges
            .filter { it.lower == it.upper && it.upper in MIN_FPS_OPTION..DEFAULT_FPS }
            .map { it.upper }
            .distinct()
            .sorted()

    private fun choosePreviewSize(): Size {
        val sizes = streamMap()?.getOutputSizes(SurfaceTexture::class.java)?.toList() ?: emptyList()
        val sixteenNine = sizes.filter { it.width <= 1280 && it.width * 9 == it.height * 16 }
        return sixteenNine.maxByOrNull { it.width * it.height }
            ?: sizes.filter { it.width <= 1280 }.maxByOrNull { it.width * it.height }
            ?: Size(640, 480)
    }

    private fun fpsRangeFor(fps: Int): Range<Int>? =
        aeRanges.firstOrNull { it.lower == fps && it.upper == fps }
            ?: aeRanges.filter { it.upper == fps }.maxByOrNull { it.lower }
            ?: aeRanges.filter { it.upper >= fps }.minByOrNull { it.upper }

    private fun currentPreview(textureId: Long, size: Size) =
        Preview(textureId, size.width, size.height, sensorOrientation, isFrontFacing, canSwitch())

    /** Abre a câmera atual e monta a sessão com as saídas que existirem. */
    @SuppressLint("MissingPermission")
    private fun openCurrent(cameraHandler: Handler, onResult: (Result<Unit>) -> Unit) {
        try {
            manager.openCamera(
                cameraId,
                object : CameraDevice.StateCallback() {
                    override fun onOpened(camera: CameraDevice) {
                        device = camera
                        rebuildSession(onResult)
                    }

                    override fun onDisconnected(camera: CameraDevice) {
                        camera.close()
                        if (device === camera) device = null
                        onFatal("A câmera foi desconectada. Outro app pode estar usando, ou este foi para segundo plano.")
                    }

                    override fun onError(camera: CameraDevice, error: Int) {
                        camera.close()
                        if (device === camera) device = null
                        onFatal("Erro da câmera (código $error)")
                    }
                },
                cameraHandler,
            )
        } catch (e: Exception) {
            onResult(Result.failure(e))
        }
    }

    fun startPreview(onResult: (Result<Preview>) -> Unit) {
        preview?.let { return onResult(Result.success(it)) }
        val worker = HandlerThread("cdc-camera").also { it.start() }
        thread = worker
        val cameraHandler = Handler(worker.looper)
        handler = cameraHandler

        val size = choosePreviewSize()
        val textureEntry = textures.createSurfaceTexture()
        textureEntry.surfaceTexture().setDefaultBufferSize(size.width, size.height)
        entry = textureEntry
        previewSurface = Surface(textureEntry.surfaceTexture())
        val info = currentPreview(textureEntry.id(), size)

        openCurrent(cameraHandler) { result ->
            result.fold(
                onSuccess = {
                    preview = info
                    onResult(Result.success(info))
                },
                onFailure = {
                    stop()
                    onResult(Result.failure(it))
                },
            )
        }
    }

    /**
     * Troca entre a câmera da frente e a de trás **sem parar o codificador**: a superfície dele
     * é a mesma, só a câmera que escreve nela muda. O vídeo fica parado por cerca de um segundo
     * enquanto a câmera nova abre.
     *
     * Com a transmissão ligada, a câmera nova precisa oferecer o mesmo tamanho e o mesmo FPS que
     * o codificador usa (informados em [activeSize] e [targetFps]); senão seria preciso reiniciar
     * o codificador, o que não é feito, e a troca é recusada.
     */
    fun switchFacing(front: Boolean, activeSize: Size?, onResult: (Result<Preview>) -> Unit) {
        val current = preview ?: return onResult(Result.failure(IllegalStateException("Abra a prévia primeiro")))
        val worker = handler ?: return onResult(Result.failure(IllegalStateException("A câmera está fechada")))
        val newId = idFor(front) ?: return onResult(
            Result.failure(IllegalStateException(if (front) "Este aparelho não tem câmera frontal" else "Este aparelho não tem câmera traseira")),
        )
        if (newId == cameraId) return onResult(Result.success(current))

        if (encoderSurface != null && activeSize != null) {
            val novas = manager.getCameraCharacteristics(newId)
            val nome = if (front) "frontal" else "traseira"
            if (encoderSizesOf(novas).none { it.width == activeSize.width && it.height == activeSize.height }) {
                return onResult(
                    Result.failure(
                        IllegalStateException(
                            "A câmera $nome não oferece ${activeSize.width}×${activeSize.height}. " +
                                "Pare a transmissão, escolha uma resolução que as duas ofereçam e tente de novo.",
                        ),
                    ),
                )
            }
            if (maxFpsOf(novas, activeSize) < targetFps || targetFps !in fixedFpsOf(fpsRangesOf(novas))) {
                return onResult(
                    Result.failure(
                        IllegalStateException("A câmera $nome não faz $targetFps FPS em ${activeSize.width}×${activeSize.height}."),
                    ),
                )
            }
        }

        val oldId = cameraId
        worker.post {
            // Fecha só a câmera e a sessão: as superfícies (prévia e codificador) ficam.
            runCatching { session?.close() }
            session = null
            runCatching { device?.close() }
            device = null

            bind(newId)
            val size = choosePreviewSize()
            entry?.surfaceTexture()?.setDefaultBufferSize(size.width, size.height)
            val updated = currentPreview(current.textureId, size)
            openCurrent(worker) { result ->
                result.fold(
                    onSuccess = {
                        preview = updated
                        onResult(Result.success(updated))
                    },
                    onFailure = { erro ->
                        // Tenta voltar à câmera anterior; se também falhar, é um erro fatal.
                        bind(oldId)
                        openCurrent(worker) { volta ->
                            volta.onFailure { onFatal("Não consegui trocar de câmera nem voltar à anterior.") }
                            onResult(Result.failure(erro))
                        }
                    },
                )
            }
        }
    }

    /** Liga a saída do codificador. A prévia continua na mesma textura. */
    fun attachEncoder(surface: Surface, onResult: (Result<Unit>) -> Unit) {
        encoderSurface = surface
        rebuildSession(onResult)
    }

    fun detachEncoder(onResult: (Result<Unit>) -> Unit = {}) {
        if (encoderSurface == null) return onResult(Result.success(Unit))
        encoderSurface = null
        rebuildSession(onResult)
    }

    /**
     * Muda o FPS com a câmera ligada, só trocando o pedido repetido: não reinicia a sessão
     * nem o codificador, então a imagem não pisca e o cliente não percebe corte.
     */
    fun setFps(fps: Int, onResult: (Result<Unit>) -> Unit) {
        targetFps = fps
        val camera = device
        val active = session
        val worker = handler
        // Sem sessão aberta, o valor novo é aplicado quando ela abrir.
        if (camera == null || active == null || worker == null) return onResult(Result.success(Unit))
        worker.post {
            try {
                applyRequest(camera, active)
                onResult(Result.success(Unit))
            } catch (e: Exception) {
                onResult(Result.failure(e))
            }
        }
    }

    private fun applyRequest(camera: CameraDevice, active: CameraCaptureSession) {
        val surfaces = listOfNotNull(previewSurface, encoderSurface)
        val template = if (encoderSurface != null) CameraDevice.TEMPLATE_RECORD else CameraDevice.TEMPLATE_PREVIEW
        val request = camera.createCaptureRequest(template).apply {
            surfaces.forEach { addTarget(it) }
            val afModes = characteristics.get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES)
            if (afModes?.contains(CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO) == true) {
                set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
            }
            fpsRangeFor(targetFps)?.let { set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, it) }
        }.build()
        active.setRepeatingRequest(request, null, handler)
    }

    @Suppress("DEPRECATION")
    private fun rebuildSession(onResult: (Result<Unit>) -> Unit) {
        val camera = device ?: return onResult(Result.failure(IllegalStateException("câmera fechada")))
        val surfaces = listOfNotNull(previewSurface, encoderSurface)
        try {
            camera.createCaptureSession(
                surfaces,
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(configured: CameraCaptureSession) {
                        session = configured
                        try {
                            applyRequest(camera, configured)
                            onResult(Result.success(Unit))
                        } catch (e: Exception) {
                            onResult(Result.failure(e))
                        }
                    }

                    override fun onConfigureFailed(failed: CameraCaptureSession) {
                        onResult(
                            Result.failure(
                                IllegalStateException("A câmera não aceitou esta combinação de saídas e resolução"),
                            ),
                        )
                    }
                },
                handler,
            )
        } catch (e: Exception) {
            onResult(Result.failure(e))
        }
    }

    fun stop() {
        runCatching { session?.close() }
        session = null
        runCatching { device?.close() }
        device = null
        runCatching { previewSurface?.release() }
        previewSurface = null
        runCatching { entry?.release() }
        entry = null
        encoderSurface = null
        preview = null
        thread?.quitSafely()
        thread = null
        handler = null
    }
}
