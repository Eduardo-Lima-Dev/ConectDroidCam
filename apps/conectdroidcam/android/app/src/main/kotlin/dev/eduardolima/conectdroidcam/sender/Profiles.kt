package dev.eduardolima.conectdroidcam.sender

import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.util.Size

/** Os três perfis do protocolo, com os bitrates iniciais de projeto (ponto médio da faixa). */
enum class Profile(val id: String, val width: Int, val height: Int, val bitrateKbps: Int) {
    HD("hd", 1280, 720, 3_000),
    FULL_HD("fullHd", 1920, 1080, 6_000),
    QHD("qhd", 2560, 1440, 9_000);

    companion object {
        fun fromId(id: String): Profile? = entries.firstOrNull { it.id == id }
    }
}

const val STREAM_FPS = 30

object CodecSupport {
    private fun isHardware(info: MediaCodecInfo): Boolean =
        if (Build.VERSION.SDK_INT >= 29) {
            info.isHardwareAccelerated
        } else {
            !info.name.startsWith("OMX.google.") && !info.name.startsWith("c2.android.")
        }

    /** Codificador H.264 por hardware que aceita o tamanho a 30 FPS, ou `null`. */
    fun findEncoder(width: Int, height: Int, fps: Int = STREAM_FPS): MediaCodecInfo? {
        val infos = MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos
        return infos.firstOrNull { info ->
            info.isEncoder &&
                MediaFormat.MIMETYPE_VIDEO_AVC in info.supportedTypes &&
                isHardware(info) &&
                runCatching {
                    val video = info.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC).videoCapabilities
                    // O Android exige largura e altura múltiplas do alinhamento do codificador
                    // (16, em geral). 1080 não é, mas todo codificador aceita 1080p cortando as
                    // linhas extras do bloco; por isso testamos o tamanho arredondado para cima.
                    video.areSizeAndRateSupported(
                        alignUp(width, video.widthAlignment),
                        alignUp(height, video.heightAlignment),
                        fps.toDouble(),
                    )
                }.getOrDefault(false)
        }
    }

    /** Menor múltiplo de [alignment] que não é menor que [value]. */
    internal fun alignUp(value: Int, alignment: Int): Int =
        if (alignment <= 1) value else (value + alignment - 1) / alignment * alignment

    fun supportsCbr(info: MediaCodecInfo): Boolean = runCatching {
        info.getCapabilitiesForType(MediaFormat.MIMETYPE_VIDEO_AVC)
            .encoderCapabilities
            .isBitrateModeSupported(MediaCodecInfo.EncoderCapabilities.BITRATE_MODE_CBR)
    }.getOrDefault(false)

    /** Disponibilidade de cada perfil, com o motivo em português quando não dá. */
    fun availability(cameraSizes: List<Size>): List<Map<String, Any?>> =
        Profile.entries.map { profile ->
            val cameraOk = cameraSizes.any { it.width == profile.width && it.height == profile.height }
            val reason = when {
                !cameraOk -> "a câmera não oferece ${profile.width}×${profile.height}"
                findEncoder(profile.width, profile.height) == null ->
                    "sem codificador H.264 por hardware para ${profile.width}×${profile.height} a $STREAM_FPS FPS"
                else -> null
            }
            mapOf(
                "profile" to profile.id,
                "width" to profile.width,
                "height" to profile.height,
                "available" to (reason == null),
                "reason" to reason,
            )
        }
}
