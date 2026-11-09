package dev.eduardolima.conectdroidcam.sender

import android.media.MediaCodecInfo
import android.media.MediaCodecList
import android.media.MediaFormat
import android.os.Build
import android.util.Size
import kotlin.math.roundToInt

/** FPS padrão e teto: o modo normal da câmera não passa de 30 FPS neste aparelho. */
const val DEFAULT_FPS = 30

/** Menor FPS oferecido ao usuário. */
const val MIN_FPS_OPTION = 15

/** Piso de 720p: nada abaixo disso é oferecido (lado maior ≥ 1280 e lado menor ≥ 720). */
private const val MIN_LONG_EDGE = 1280
private const val MIN_SHORT_EDGE = 720

/** Perfis nomeados do protocolo v1 e seus tamanhos. */
val NAMED_PROFILES = listOf(
    "hd" to Size(1280, 720),
    "fullHd" to Size(1920, 1080),
    "qhd" to Size(2560, 1440),
)

/**
 * Bitrate de vídeo inicial em kb/s. Os três perfis nomeados usam o ponto médio da faixa
 * de projeto; os demais, cerca de 0,1 bit por pixel a 30 FPS, entre 1,5 e 20 Mb/s.
 * São pontos de partida a validar em aparelhos reais, não garantias de qualidade.
 */
fun bitrateFor(width: Int, height: Int): Int = when {
    width == 1280 && height == 720 -> 3_000
    width == 1920 && height == 1080 -> 6_000
    width == 2560 && height == 1440 -> 9_000
    else -> {
        val kbps = width.toDouble() * height * 30 * 0.1 / 1000
        ((kbps / 500).roundToInt() * 500).coerceIn(1_500, 20_000)
    }
}

object CodecSupport {
    private fun isHardware(info: MediaCodecInfo): Boolean =
        if (Build.VERSION.SDK_INT >= 29) {
            info.isHardwareAccelerated
        } else {
            !info.name.startsWith("OMX.google.") && !info.name.startsWith("c2.android.")
        }

    /** Codificador H.264 por hardware que aceita o tamanho no FPS pedido, ou `null`. */
    fun findEncoder(width: Int, height: Int, fps: Int = DEFAULT_FPS): MediaCodecInfo? {
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

    /**
     * Resoluções que este aparelho oferece: o que a câmera entrega para um codificador,
     * cruzado com o que o codificador H.264 por hardware aceita. Cada item diz se está
     * disponível e, quando não está, o motivo em português.
     *
     * [maxFpsOf] devolve o FPS máximo que a câmera sustenta no tamanho.
     */
    fun modes(sizes: List<Size>, maxFpsOf: (Size) -> Int): List<Map<String, Any?>> =
        sizes
            .filter { maxOf(it.width, it.height) >= MIN_LONG_EDGE && minOf(it.width, it.height) >= MIN_SHORT_EDGE }
            .distinctBy { it.width to it.height }
            .sortedBy { it.width.toLong() * it.height }
            .map { size ->
                val cameraFps = maxFpsOf(size)
                val fps = minOf(cameraFps, DEFAULT_FPS)
                val reason = when {
                    fps < MIN_FPS_OPTION ->
                        "a câmera entrega no máximo $cameraFps FPS em ${size.width}×${size.height}"
                    findEncoder(size.width, size.height, fps) == null ->
                        "sem codificador H.264 por hardware para ${size.width}×${size.height}"
                    else -> null
                }
                mapOf(
                    "id" to "${size.width}x${size.height}",
                    "width" to size.width,
                    "height" to size.height,
                    "available" to (reason == null),
                    "reason" to reason,
                    "maxFps" to fps,
                )
            }

    /** Disponibilidade dos três perfis nomeados do protocolo, a partir da lista de resoluções. */
    fun namedAvailability(modes: List<Map<String, Any?>>): List<Map<String, Any?>> =
        NAMED_PROFILES.map { (id, size) ->
            val mode = modes.firstOrNull { it["width"] == size.width && it["height"] == size.height }
            mapOf(
                "profile" to id,
                "available" to (mode?.get("available") == true),
                // O motivo só existe quando NÃO está disponível: com `?:`, um perfil disponível
                // (motivo nulo) receberia a mensagem de "a câmera não oferece" por engano.
                "reason" to if (mode == null) "a câmera não oferece ${size.width}×${size.height}" else mode["reason"],
            )
        }
}
