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
 * durante a transmissão, a superfície do codificador (na resolução do perfil).
 *
 * Callbacks chegam na thread da câmera; quem chama é responsável por voltar à
 * thread principal quando precisar.
 */
class CameraController(
    context: Context,
    private val textures: TextureRegistry,
    private val onFatal: (String) -> Unit,
) {
    data class Preview(val textureId: Long, val width: Int, val height: Int)

    private val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
    val cameraId: String = pickCameraId()
    private val characteristics = manager.getCameraCharacteristics(cameraId)

    private var thread: HandlerThread? = null
    private var handler: Handler? = null
    private var device: CameraDevice? = null
    private var session: CameraCaptureSession? = null
    private var entry: TextureRegistry.SurfaceTextureEntry? = null
    private var previewSurface: Surface? = null
    private var encoderSurface: Surface? = null
    private var preview: Preview? = null

    private fun pickCameraId(): String {
        val ids = manager.cameraIdList
        return ids.firstOrNull {
            manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) ==
                CameraCharacteristics.LENS_FACING_BACK
        } ?: ids.firstOrNull() ?: throw IllegalStateException("Este aparelho não tem câmera")
    }

    /** Tamanhos que a câmera entrega para um codificador. */
    fun encoderSizes(): List<Size> {
        val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP) ?: return emptyList()
        val sizes = map.getOutputSizes(MediaCodec::class.java)
            ?: map.getOutputSizes(SurfaceTexture::class.java)
        return sizes?.toList() ?: emptyList()
    }

    private fun choosePreviewSize(): Size {
        val map = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val sizes = map?.getOutputSizes(SurfaceTexture::class.java)?.toList() ?: emptyList()
        val sixteenNine = sizes.filter { it.width <= 1280 && it.width * 9 == it.height * 16 }
        return sixteenNine.maxByOrNull { it.width * it.height }
            ?: sizes.filter { it.width <= 1280 }.maxByOrNull { it.width * it.height }
            ?: Size(640, 480)
    }

    private fun chooseFpsRange(): Range<Int>? {
        val ranges = characteristics.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
            ?: return null
        // Prefere 30 fixo; senão, o intervalo que chega a 30 com o menor piso possível acima.
        return ranges.filter { it.upper == STREAM_FPS }.maxByOrNull { it.lower }
            ?: ranges.filter { it.upper >= STREAM_FPS }.minByOrNull { it.upper }
    }

    @SuppressLint("MissingPermission")
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
        val info = Preview(textureEntry.id(), size.width, size.height)

        try {
            manager.openCamera(
                cameraId,
                object : CameraDevice.StateCallback() {
                    override fun onOpened(camera: CameraDevice) {
                        device = camera
                        rebuildSession { result ->
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

                    override fun onDisconnected(camera: CameraDevice) {
                        camera.close()
                        device = null
                        onFatal("A câmera foi desconectada. Outro app pode estar usando, ou este foi para segundo plano.")
                    }

                    override fun onError(camera: CameraDevice, error: Int) {
                        camera.close()
                        device = null
                        onFatal("Erro da câmera (código $error)")
                    }
                },
                cameraHandler,
            )
        } catch (e: Exception) {
            stop()
            onResult(Result.failure(e))
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
                            val template = if (encoderSurface != null) {
                                CameraDevice.TEMPLATE_RECORD
                            } else {
                                CameraDevice.TEMPLATE_PREVIEW
                            }
                            val request = camera.createCaptureRequest(template).apply {
                                surfaces.forEach { addTarget(it) }
                                val afModes = characteristics.get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES)
                                if (afModes?.contains(CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO) == true) {
                                    set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
                                }
                                chooseFpsRange()?.let { set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, it) }
                            }.build()
                            configured.setRepeatingRequest(request, null, handler)
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
