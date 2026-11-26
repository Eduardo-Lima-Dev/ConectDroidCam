package dev.eduardolima.conectdroidcam.sender

import android.annotation.SuppressLint
import android.content.Context
import android.graphics.Rect
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraMetadata
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraDevice.StateCallback.ERROR_CAMERA_DISABLED
import android.hardware.camera2.CameraDevice.StateCallback.ERROR_CAMERA_IN_USE
import android.hardware.camera2.CameraDevice.StateCallback.ERROR_CAMERA_SERVICE
import android.hardware.camera2.CameraDevice.StateCallback.ERROR_MAX_CAMERAS_IN_USE
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.params.MeteringRectangle
import android.media.MediaCodec
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Range
import android.util.Size
import android.view.Surface
import io.flutter.view.TextureRegistry

class CameraController(
    context: Context,
    private val textures: TextureRegistry,
    private val onFatal: (message: String, recoverable: Boolean) -> Unit,
) {
    data class Preview(
        val textureId: Long,
        val width: Int,
        val height: Int,
        val sensorOrientation: Int,
        val isFront: Boolean,
        val canSwitch: Boolean,
    )

    private val manager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager

    var cameraId: String = pickCameraId(front = false)
        private set
    private var characteristics: CameraCharacteristics = manager.getCameraCharacteristics(cameraId)

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

    @Volatile
    var targetFps: Int = DEFAULT_FPS

    data class Controls(
        val zoom: Float = 1f,
        val focusX: Float? = null,
        val focusY: Float? = null,
        val exposure: Int = 0,
        val aeLock: Boolean = false,
        val awbLock: Boolean = false,
        val torch: Boolean = false,
    )

    @Volatile
    private var controls = Controls()

    private fun orientationOf(c: CameraCharacteristics) = c.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90

    private fun isFront(c: CameraCharacteristics) =
        c.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_FRONT

    private fun fpsRangesOf(c: CameraCharacteristics): Array<Range<Int>> =
        c.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES) ?: emptyArray()

    private fun pickCameraId(front: Boolean): String {
        val ids = manager.cameraIdList
        val wanted = if (front) CameraCharacteristics.LENS_FACING_FRONT else CameraCharacteristics.LENS_FACING_BACK
        return ids.firstOrNull { manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) == wanted }
            ?: ids.firstOrNull()
            ?: throw IllegalStateException("Este aparelho não tem câmera")
    }

    private fun idFor(front: Boolean): String? {
        val wanted = if (front) CameraCharacteristics.LENS_FACING_FRONT else CameraCharacteristics.LENS_FACING_BACK
        return manager.cameraIdList.firstOrNull {
            manager.getCameraCharacteristics(it).get(CameraCharacteristics.LENS_FACING) == wanted
        }
    }

    fun canSwitch(): Boolean = idFor(front = true) != null && idFor(front = false) != null

    private fun bind(id: String) {
        cameraId = id
        characteristics = manager.getCameraCharacteristics(id)
        sensorOrientation = orientationOf(characteristics)
        isFrontFacing = isFront(characteristics)
        aeRanges = fpsRangesOf(characteristics)
        controls = Controls()
    }

    private fun zoomRange(): Pair<Float, Float> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            characteristics.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE)?.let {
                return it.lower to it.upper
            }
        }
        val max = characteristics.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM) ?: 1f
        return 1f to max.coerceAtLeast(1f)
    }

    private fun usesZoomRatio(): Boolean =
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            characteristics.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE) != null

    private fun canFocus(): Boolean =
        (characteristics.get(CameraCharacteristics.CONTROL_MAX_REGIONS_AF) ?: 0) > 0 &&
            characteristics.get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES)
                ?.contains(CaptureRequest.CONTROL_AF_MODE_AUTO) == true

    private fun canMeter(): Boolean = (characteristics.get(CameraCharacteristics.CONTROL_MAX_REGIONS_AE) ?: 0) > 0

    fun controlsMap(): Map<String, Any?> {
        val (zoomMin, zoomMax) = zoomRange()
        val ev = characteristics.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE)
        val step = characteristics.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_STEP)
        val c = controls
        return mapOf(
            "zoomMin" to zoomMin.toDouble(),
            "zoomMax" to zoomMax.toDouble(),
            "zoom" to c.zoom.toDouble(),
            "focusSupported" to (canFocus() || canMeter()),
            "focusLocked" to (c.focusX != null),
            "exposureMin" to (ev?.lower ?: 0),
            "exposureMax" to (ev?.upper ?: 0),
            "exposureStep" to (step?.toDouble() ?: 0.0),
            "exposure" to c.exposure,
            "aeLockSupported" to (characteristics.get(CameraCharacteristics.CONTROL_AE_LOCK_AVAILABLE) == true),
            "aeLock" to c.aeLock,
            "awbLockSupported" to (characteristics.get(CameraCharacteristics.CONTROL_AWB_LOCK_AVAILABLE) == true),
            "awbLock" to c.awbLock,
            "torchSupported" to (characteristics.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true),
            "torch" to c.torch,
        )
    }

    fun updateControls(change: (Controls) -> Controls, onResult: (Result<Unit>) -> Unit) {
        val (zoomMin, zoomMax) = zoomRange()
        val ev = characteristics.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE)
        val next = change(controls).let {
            it.copy(
                zoom = it.zoom.coerceIn(zoomMin, zoomMax),
                exposure = if (ev == null) 0 else it.exposure.coerceIn(ev.lower, ev.upper),
                focusX = it.focusX?.coerceIn(0f, 1f),
                focusY = it.focusY?.coerceIn(0f, 1f),
            )
        }
        val trigger = next.focusX != null && (next.focusX != controls.focusX || next.focusY != controls.focusY)
        controls = next
        val camera = device
        val active = session
        val worker = handler
        if (camera == null || active == null || worker == null) return onResult(Result.success(Unit))
        worker.post {
            try {
                applyRequest(camera, active, trigger)
                onResult(Result.success(Unit))
            } catch (e: Exception) {
                onResult(Result.failure(e))
            }
        }
    }

    private fun activeArray(): Rect =
        characteristics.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE) ?: Rect(0, 0, 1, 1)

    private fun cropFor(zoom: Float): Rect {
        val active = activeArray()
        if (zoom <= 1f) return Rect(0, 0, active.width(), active.height())
        val w = (active.width() / zoom).toInt()
        val h = (active.height() / zoom).toInt()
        val left = (active.width() - w) / 2
        val top = (active.height() - h) / 2
        return Rect(left, top, left + w, top + h)
    }

    private fun meteringFor(x: Float, y: Float): MeteringRectangle {
        val active = activeArray()
        val field = if (usesZoomRatio()) Rect(0, 0, active.width(), active.height()) else cropFor(controls.zoom)
        val p = preview
        val previewAspect = if (p != null && p.height > 0) p.width.toFloat() / p.height else field.width().toFloat() / field.height()
        val fieldAspect = field.width().toFloat() / field.height()
        val visible = if (previewAspect > fieldAspect) {
            val h = (field.width() / previewAspect).toInt()
            val top = field.top + (field.height() - h) / 2
            Rect(field.left, top, field.right, top + h)
        } else {
            val w = (field.height() * previewAspect).toInt()
            val left = field.left + (field.width() - w) / 2
            Rect(left, field.top, left + w, field.bottom)
        }
        val cx = visible.left + (x * visible.width()).toInt()
        val cy = visible.top + (y * visible.height()).toInt()
        val half = (minOf(visible.width(), visible.height()) * FOCUS_AREA / 2).toInt().coerceAtLeast(1)
        val rect = Rect(
            (cx - half).coerceIn(0, active.width() - 1),
            (cy - half).coerceIn(0, active.height() - 1),
            (cx + half).coerceIn(1, active.width()),
            (cy + half).coerceIn(1, active.height()),
        )
        return MeteringRectangle(rect, MeteringRectangle.METERING_WEIGHT_MAX - 1)
    }

    private fun streamMap() = characteristics.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)

    fun encoderSizes(): List<Size> = encoderSizesOf(characteristics)

    private fun encoderSizesOf(c: CameraCharacteristics): List<Size> {
        val map = c.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP) ?: return emptyList()
        val sizes = map.getOutputSizes(MediaCodec::class.java)
            ?: map.getOutputSizes(SurfaceTexture::class.java)
        return sizes?.toList() ?: emptyList()
    }

    fun maxFps(size: Size): Int = maxFpsOf(characteristics, size)

    private fun maxFpsOf(c: CameraCharacteristics, size: Size): Int {
        val map = c.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP) ?: return DEFAULT_FPS
        val nanos = runCatching { map.getOutputMinFrameDuration(MediaCodec::class.java, size) }
            .getOrElse { map.getOutputMinFrameDuration(SurfaceTexture::class.java, size) }
        return if (nanos > 0) (1_000_000_000.0 / nanos).toInt() else DEFAULT_FPS
    }

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
                        onFatal(CAMERA_LOST, true)
                    }

                    override fun onError(camera: CameraDevice, error: Int) {
                        camera.close()
                        if (device === camera) device = null
                        when (error) {
                            ERROR_CAMERA_IN_USE, ERROR_MAX_CAMERAS_IN_USE ->
                                onFatal("Outro app está usando a câmera. Feche-o e toque em Tentar de novo.", false)
                            ERROR_CAMERA_DISABLED -> onFatal(CAMERA_LOST, true)
                            ERROR_CAMERA_SERVICE ->
                                onFatal("O serviço de câmera do Android falhou. Toque em Tentar de novo; se continuar, reinicie o celular.", false)
                            else ->
                                onFatal("A câmera parou de responder (código $error). Toque em Tentar de novo; se continuar, reinicie o celular.", false)
                        }
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
                        bind(oldId)
                        openCurrent(worker) { volta ->
                            volta.onFailure { onFatal("Não consegui trocar de câmera nem voltar à anterior.", false) }
                            onResult(Result.failure(erro))
                        }
                    },
                )
            }
        }
    }

    fun attachEncoder(surface: Surface, onResult: (Result<Unit>) -> Unit) {
        encoderSurface = surface
        rebuildSession(onResult)
    }

    fun detachEncoder(onResult: (Result<Unit>) -> Unit = {}) {
        if (encoderSurface == null) return onResult(Result.success(Unit))
        encoderSurface = null
        rebuildSession(onResult)
    }

    fun setFps(fps: Int, onResult: (Result<Unit>) -> Unit) {
        targetFps = fps
        val camera = device
        val active = session
        val worker = handler
        if (camera == null || active == null || worker == null) return onResult(Result.success(Unit))
        worker.post {
            try {
                applyRequest(camera, active, false)
                onResult(Result.success(Unit))
            } catch (e: Exception) {
                onResult(Result.failure(e))
            }
        }
    }

    private fun applyRequest(camera: CameraDevice, active: CameraCaptureSession, triggerFocus: Boolean) {
        val surfaces = listOfNotNull(previewSurface, encoderSurface)
        val template = if (encoderSurface != null) CameraDevice.TEMPLATE_RECORD else CameraDevice.TEMPLATE_PREVIEW
        val c = controls
        val focusPoint = if (c.focusX != null && c.focusY != null) meteringFor(c.focusX, c.focusY) else null
        val builder = camera.createCaptureRequest(template).apply {
            surfaces.forEach { addTarget(it) }
            val afModes = characteristics.get(CameraCharacteristics.CONTROL_AF_AVAILABLE_MODES)
            if (focusPoint != null && canFocus()) {
                set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_AUTO)
                set(CaptureRequest.CONTROL_AF_REGIONS, arrayOf(focusPoint))
            } else if (afModes?.contains(CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO) == true) {
                set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
            }
            if (focusPoint != null && canMeter()) {
                set(CaptureRequest.CONTROL_AE_REGIONS, arrayOf(focusPoint))
            }
            fpsRangeFor(targetFps)?.let { set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, it) }
            if (usesZoomRatio()) {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) set(CaptureRequest.CONTROL_ZOOM_RATIO, c.zoom)
            } else if (c.zoom > 1f) {
                set(CaptureRequest.SCALER_CROP_REGION, cropFor(c.zoom))
            }
            set(CaptureRequest.CONTROL_AE_EXPOSURE_COMPENSATION, c.exposure)
            if (characteristics.get(CameraCharacteristics.CONTROL_AE_LOCK_AVAILABLE) == true) {
                set(CaptureRequest.CONTROL_AE_LOCK, c.aeLock)
            }
            if (characteristics.get(CameraCharacteristics.CONTROL_AWB_LOCK_AVAILABLE) == true) {
                set(CaptureRequest.CONTROL_AWB_LOCK, c.awbLock)
            }
            if (characteristics.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) == true) {
                set(CaptureRequest.CONTROL_AE_MODE, CaptureRequest.CONTROL_AE_MODE_ON)
                set(
                    CaptureRequest.FLASH_MODE,
                    if (c.torch) CameraMetadata.FLASH_MODE_TORCH else CameraMetadata.FLASH_MODE_OFF,
                )
            }
        }
        active.setRepeatingRequest(builder.build(), null, handler)
        if (triggerFocus && focusPoint != null && canFocus()) {
            builder.set(CaptureRequest.CONTROL_AF_TRIGGER, CameraMetadata.CONTROL_AF_TRIGGER_START)
            active.capture(builder.build(), null, handler)
        }
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
                            applyRequest(camera, configured, controls.focusX != null)
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

    companion object {
        private const val FOCUS_AREA = 0.15f

        const val CAMERA_LOST =
            "A câmera parou porque o app saiu da tela ou outro app passou a usá-la. " +
                "Ela volta sozinha quando você abrir o ConectDroidCam de novo."
    }
}
