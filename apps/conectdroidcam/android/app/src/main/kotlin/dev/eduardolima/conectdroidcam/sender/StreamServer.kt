package dev.eduardolima.conectdroidcam.sender

import android.os.Build
import org.json.JSONArray
import org.json.JSONObject
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.IOException
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.ArrayDeque
import java.util.concurrent.atomic.AtomicLong

/**
 * Servidor do protocolo v1. O celular escuta e o computador conecta; assim o mesmo
 * fluxo serve Wi-Fi e USB (`adb forward`).
 *
 * Aceita um cliente por vez. Sem cliente, os frames do codificador são descartados.
 * Com cliente, a fila de vídeo tem limite: se o cliente não acompanha, descarta o que
 * está na fila e só volta a enviar a partir do próximo keyframe (latência acima de
 * completude, como em docs/protocol-v1.md).
 *
 * ATENÇÃO: ainda não há TLS nem pareamento. Qualquer aparelho da rede que chegue
 * à porta recebe o vídeo. Isso é provisório, até as fases de segurança.
 */
class StreamServer(
    private val port: Int,
    private val appVersion: String,
    private val listener: Listener,
) {
    interface Listener {
        fun onClientConnected(peer: String)

        fun onClientDisconnected()

        /** O cliente pediu, ou o descarte exige, um novo IDR. */
        fun onKeyframeNeeded()
    }

    data class Counters(val frames: Long, val bytes: Long, val dropped: Long, val clientConnected: Boolean)

    private var serverSocket: ServerSocket? = null
    private var acceptThread: Thread? = null
    @Volatile private var client: Client? = null

    private val framesSent = AtomicLong()
    private val bytesSent = AtomicLong()
    private val framesDropped = AtomicLong()

    @Volatile private var info = StreamInfo(0, 0, 0, 0)
    @Volatile private var videoConfig: ByteArray? = null
    @Volatile private var profiles: List<Map<String, Any?>> = emptyList()
    private var basePtsUs = -1L

    private data class StreamInfo(val width: Int, val height: Int, val fps: Int, val bitrateKbps: Int)

    fun setStream(profile: Profile) {
        info = StreamInfo(profile.width, profile.height, STREAM_FPS, profile.bitrateKbps)
        videoConfig = null
        basePtsUs = -1L
    }

    fun setProfiles(list: List<Map<String, Any?>>) {
        profiles = list
    }

    @Throws(IOException::class)
    fun start() {
        val socket = ServerSocket()
        socket.reuseAddress = true
        socket.bind(InetSocketAddress(port))
        serverSocket = socket
        acceptThread = Thread({ acceptLoop(socket) }, "cdc-accept").also { it.start() }
    }

    private fun acceptLoop(socket: ServerSocket) {
        while (!socket.isClosed) {
            val accepted = try {
                socket.accept()
            } catch (_: IOException) {
                return
            }
            if (client != null) {
                // Uma sessão por vez.
                runCatching { accepted.close() }
                continue
            }
            val newClient = Client(accepted)
            client = newClient
            newClient.start()
        }
    }

    fun onConfig(data: ByteArray) {
        videoConfig = data
        client?.enqueueControl(Protocol.Frame(Protocol.TYPE_VIDEO_CONFIG, 0, 0, data))
    }

    fun onVideo(data: ByteArray, ptsUs: Long, keyframe: Boolean) {
        val current = client ?: return
        if (basePtsUs < 0) basePtsUs = ptsUs
        val flags = if (keyframe) Protocol.FLAG_KEYFRAME else 0
        current.enqueueVideo(Protocol.Frame(Protocol.TYPE_VIDEO, flags, ptsUs - basePtsUs, data), keyframe)
    }

    fun counters() = Counters(framesSent.get(), bytesSent.get(), framesDropped.get(), client != null)

    fun stop() {
        runCatching { serverSocket?.close() }
        serverSocket = null
        client?.close()
        client = null
        acceptThread = null
    }

    private inner class Client(private val socket: Socket) {
        private val lock = Object()
        private val controlQueue = ArrayDeque<Protocol.Frame>()
        private val videoQueue = ArrayDeque<Protocol.Frame>()
        private var waitingKeyframe = true
        @Volatile private var closed = false
        private val peer = socket.remoteSocketAddress.toString().trimStart('/')

        fun start() {
            basePtsUs = -1L
            runCatching {
                socket.tcpNoDelay = true
                socket.keepAlive = true
            }
            enqueueControl(
                Protocol.control("hello") {
                    put("deviceName", Build.MODEL ?: "Android")
                    put("platform", "android")
                    put("appVersion", appVersion)
                },
            )
            enqueueControl(
                Protocol.control("profile.actual") {
                    put("width", info.width)
                    put("height", info.height)
                    put("fps", info.fps)
                    put("bitrateKbps", info.bitrateKbps)
                },
            )
            videoConfig?.let { enqueueControl(Protocol.Frame(Protocol.TYPE_VIDEO_CONFIG, 0, 0, it)) }
            listener.onClientConnected(peer)
            listener.onKeyframeNeeded()
            Thread({ writeLoop() }, "cdc-writer").start()
            Thread({ readLoop() }, "cdc-reader").start()
        }

        fun enqueueControl(frame: Protocol.Frame) {
            synchronized(lock) {
                controlQueue.add(frame)
                lock.notifyAll()
            }
        }

        fun enqueueVideo(frame: Protocol.Frame, keyframe: Boolean) {
            var needKeyframe = false
            synchronized(lock) {
                if (waitingKeyframe) {
                    if (!keyframe) {
                        framesDropped.incrementAndGet()
                        return
                    }
                    waitingKeyframe = false
                }
                if (videoQueue.size >= MAX_PENDING_VIDEO) {
                    framesDropped.addAndGet(videoQueue.size.toLong() + 1)
                    videoQueue.clear()
                    waitingKeyframe = true
                    needKeyframe = true
                } else {
                    videoQueue.add(frame)
                    lock.notifyAll()
                }
            }
            if (needKeyframe) listener.onKeyframeNeeded()
        }

        private fun writeLoop() {
            try {
                val out = BufferedOutputStream(socket.getOutputStream(), 64 * 1024)
                while (!closed) {
                    val frame = synchronized(lock) {
                        while (!closed && controlQueue.isEmpty() && videoQueue.isEmpty()) lock.wait()
                        controlQueue.pollFirst() ?: videoQueue.pollFirst()
                    } ?: break
                    Protocol.write(out, frame)
                    if (frame.type == Protocol.TYPE_VIDEO) {
                        framesSent.incrementAndGet()
                        bytesSent.addAndGet(frame.payload.size.toLong())
                    }
                }
            } catch (_: Exception) {
                // Cliente saiu ou a rede caiu: encerra a sessão.
            } finally {
                close()
            }
        }

        private fun readLoop() {
            try {
                val input = BufferedInputStream(socket.getInputStream())
                while (!closed) {
                    val frame = Protocol.read(input) ?: break
                    val message = Protocol.parseControl(frame) ?: continue
                    when (message.optString("type")) {
                        "keyframe.request" -> listener.onKeyframeNeeded()
                        "profile.query" -> enqueueControl(
                            Protocol.control("profile.list") {
                                put(
                                    "profiles",
                                    JSONArray().also { array ->
                                        profiles.forEach { p ->
                                            array.put(
                                                JSONObject().apply {
                                                    put("profile", p["profile"])
                                                    put("available", p["available"])
                                                    p["reason"]?.let { put("reason", it) }
                                                },
                                            )
                                        }
                                    },
                                )
                            },
                        )
                        "session.stop" -> break
                    }
                }
            } catch (_: Exception) {
                // Mensagem inválida ou conexão encerrada.
            } finally {
                close()
            }
        }

        fun close() {
            val wasOpen: Boolean
            synchronized(lock) {
                wasOpen = !closed
                closed = true
                lock.notifyAll()
            }
            if (!wasOpen) return
            runCatching { socket.close() }
            if (client === this) client = null
            listener.onClientDisconnected()
        }
    }

    private companion object {
        /** Cerca de 200 ms de vídeo a 30 FPS. */
        const val MAX_PENDING_VIDEO = 6
    }
}
