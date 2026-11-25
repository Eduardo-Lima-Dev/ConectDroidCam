package dev.eduardolima.conectdroidcam.sender

import android.media.MediaCodec
import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.view.Surface

class VideoEncoder(
    private val width: Int,
    private val height: Int,
    private val fps: Int,
    private val bitrateKbps: Int,
    private val listener: Listener,
) {
    interface Listener {
        fun onConfig(data: ByteArray)

        fun onFrame(data: ByteArray, ptsUs: Long, keyframe: Boolean)

        fun onError(error: Exception)
    }

    private var thread: HandlerThread? = null
    private var codec: MediaCodec? = null

    lateinit var inputSurface: Surface
        private set

    fun start() {
        val info = CodecSupport.findEncoder(width, height, fps)
            ?: throw IllegalStateException(
                "Sem codificador H.264 por hardware para $width×$height",
            )
        val format = MediaFormat.createVideoFormat(MediaFormat.MIMETYPE_VIDEO_AVC, width, height).apply {
            setInteger(MediaFormat.KEY_COLOR_FORMAT, MediaCodecInfo.CodecCapabilities.COLOR_FormatSurface)
            setInteger(MediaFormat.KEY_BIT_RATE, bitrateKbps * 1000)
            setInteger(MediaFormat.KEY_FRAME_RATE, fps)
            setInteger(MediaFormat.KEY_I_FRAME_INTERVAL, 1)
            setInteger(
                MediaFormat.KEY_BITRATE_MODE,
                if (CodecSupport.supportsCbr(info)) {
                    MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR
                } else {
                    MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_VBR
                },
            )
            setInteger("prepend-sps-pps-to-idr-frames", 1)
            if (Build.VERSION.SDK_INT >= 23) setInteger(MediaFormat.KEY_PRIORITY, 0)
            if (Build.VERSION.SDK_INT >= 30) setInteger(MediaFormat.KEY_LATENCY, 1)
        }

        val handlerThread = HandlerThread("cdc-encoder").also { it.start() }
        thread = handlerThread
        val mediaCodec = MediaCodec.createByCodecName(info.name)
        mediaCodec.setCallback(
            object : MediaCodec.Callback() {
                override fun onInputBufferAvailable(codec: MediaCodec, index: Int) = Unit

                override fun onOutputBufferAvailable(codec: MediaCodec, index: Int, info: MediaCodec.BufferInfo) {
                    try {
                        val buffer = codec.getOutputBuffer(index)
                        if (buffer != null && info.size > 0) {
                            val data = ByteArray(info.size)
                            buffer.position(info.offset)
                            buffer.limit(info.offset + info.size)
                            buffer.get(data)
                            if (info.flags and MediaCodec.BUFFER_FLAG_CODEC_CONFIG != 0) {
                                listener.onConfig(data)
                            } else {
                                listener.onFrame(
                                    data,
                                    info.presentationTimeUs,
                                    info.flags and MediaCodec.BUFFER_FLAG_KEY_FRAME != 0,
                                )
                            }
                        }
                    } finally {
                        runCatching { codec.releaseOutputBuffer(index, false) }
                    }
                }

                override fun onError(codec: MediaCodec, e: MediaCodec.CodecException) = listener.onError(e)

                override fun onOutputFormatChanged(codec: MediaCodec, format: MediaFormat) = Unit
            },
            Handler(handlerThread.looper),
        )
        try {
            mediaCodec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE)
            inputSurface = mediaCodec.createInputSurface()
            mediaCodec.start()
        } catch (e: Exception) {
            mediaCodec.release()
            handlerThread.quitSafely()
            throw e
        }
        codec = mediaCodec
    }

    fun requestKeyframe() {
        runCatching {
            codec?.setParameters(Bundle().apply { putInt(MediaCodec.PARAMETER_KEY_REQUEST_SYNC_FRAME, 0) })
        }
    }

    fun stop() {
        val mediaCodec = codec
        codec = null
        runCatching { mediaCodec?.stop() }
        runCatching { mediaCodec?.release() }
        if (::inputSurface.isInitialized) runCatching { inputSurface.release() }
        thread?.quitSafely()
        thread = null
    }
}
