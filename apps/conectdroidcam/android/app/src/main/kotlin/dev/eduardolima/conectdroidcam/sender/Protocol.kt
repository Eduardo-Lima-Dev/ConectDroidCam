package dev.eduardolima.conectdroidcam.sender

import org.json.JSONException
import org.json.JSONObject
import java.io.EOFException
import java.io.IOException
import java.io.InputStream
import java.io.OutputStream
import java.nio.ByteBuffer

/**
 * Protocolo v1 (ver docs/protocol-v1.md). Espelha o crate Rust `cdc-protocol`:
 * as mesmas regras de validação valem nos dois lados.
 */
object Protocol {
    const val VERSION = 1
    const val HEADER_LEN = 14
    const val MAX_PAYLOAD = 8 * 1024 * 1024
    const val MAX_CONTROL_PAYLOAD = 64 * 1024
    const val FLAG_KEYFRAME = 1

    const val TYPE_CONTROL = 0
    const val TYPE_VIDEO_CONFIG = 1
    const val TYPE_VIDEO = 2
    const val TYPE_AUDIO_CONFIG = 3
    const val TYPE_AUDIO = 4

    class ProtocolException(message: String) : IOException(message)

    class Frame(val type: Int, val flags: Int, val ptsUs: Long, val payload: ByteArray) {
        val isKeyframe: Boolean get() = flags and FLAG_KEYFRAME != 0
    }

    private fun maxPayload(type: Int) = if (type == TYPE_CONTROL) MAX_CONTROL_PAYLOAD else MAX_PAYLOAD

    private fun validate(type: Int, flags: Int, length: Long) {
        if (type !in TYPE_CONTROL..TYPE_AUDIO) throw ProtocolException("tipo de frame desconhecido: $type")
        val allowedFlags = if (type == TYPE_VIDEO) FLAG_KEYFRAME else 0
        if (flags and allowedFlags.inv() != 0) throw ProtocolException("flags inválidas: $flags")
        if (length < 0 || length > maxPayload(type)) throw ProtocolException("payload de $length bytes excede o limite")
    }

    fun write(out: OutputStream, frame: Frame) {
        validate(frame.type, frame.flags, frame.payload.size.toLong())
        val header = ByteBuffer.allocate(HEADER_LEN) // big-endian por padrão
        header.put(frame.type.toByte())
        header.put(frame.flags.toByte())
        header.putLong(frame.ptsUs)
        header.putInt(frame.payload.size)
        out.write(header.array())
        out.write(frame.payload)
        out.flush()
    }

    /** Lê um frame. Devolve `null` se a conexão fechou limpa antes do primeiro byte. */
    fun read(input: InputStream): Frame? {
        val raw = ByteArray(HEADER_LEN)
        var got = 0
        while (got < HEADER_LEN) {
            val n = input.read(raw, got, HEADER_LEN - got)
            if (n < 0) {
                if (got == 0) return null
                throw EOFException("conexão encerrada no meio de um frame")
            }
            got += n
        }
        val buf = ByteBuffer.wrap(raw)
        val type = buf.get().toInt() and 0xff
        val flags = buf.get().toInt() and 0xff
        val pts = buf.long
        val length = buf.int.toLong() and 0xffffffffL
        // Valida antes de alocar: um tamanho hostil não pode causar alocação gigante.
        validate(type, flags, length)
        val payload = ByteArray(length.toInt())
        var read = 0
        while (read < payload.size) {
            val n = input.read(payload, read, payload.size - read)
            if (n < 0) throw EOFException("conexão encerrada no meio de um frame")
            read += n
        }
        return Frame(type, flags, pts, payload)
    }

    fun control(type: String, fill: JSONObject.() -> Unit = {}): Frame {
        val json = JSONObject()
        json.put("protocolVersion", VERSION)
        json.put("type", type)
        json.fill()
        return Frame(TYPE_CONTROL, 0, 0, json.toString().toByteArray(Charsets.UTF_8))
    }

    /** Interpreta um frame de controle; `null` se for inválido ou de outra versão. */
    fun parseControl(frame: Frame): JSONObject? {
        if (frame.type != TYPE_CONTROL) return null
        return try {
            val json = JSONObject(String(frame.payload, Charsets.UTF_8))
            if (json.optInt("protocolVersion", -1) != VERSION) null else json
        } catch (_: JSONException) {
            null
        }
    }
}
