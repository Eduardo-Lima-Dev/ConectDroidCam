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
import javax.net.ssl.SSLServerSocket
import javax.net.ssl.SSLSocket
import java.util.ArrayDeque
import java.util.concurrent.atomic.AtomicLong

class StreamServer(
    private val port: Int,
    private val appVersion: String,
    private val security: PhoneSecurity,
    private val listener: Listener,
) {
    interface Listener {
        fun onClientConnected(peer: String)

        fun onClientDisconnected()

        fun onKeyframeNeeded()

        fun onCommand(type: String, message: JSONObject)

        fun onPairingRequest(code: String, computerName: String)

        fun onPairingEnded(paired: Boolean, computerName: String, reason: String?)
    }

    data class Counters(val frames: Long, val bytes: Long, val dropped: Long, val clientConnected: Boolean)

    private var serverSocket: ServerSocket? = null
    private var acceptThread: Thread? = null
    @Volatile private var client: Client? = null

    private val framesSent = AtomicLong()
    private val bytesSent = AtomicLong()
    private val framesDropped = AtomicLong()

    @Volatile private var info = StreamInfo(0, 0, 0, 0, 0)
    @Volatile private var videoConfig: ByteArray? = null
    @Volatile private var profiles: List<Map<String, Any?>> = emptyList()

    @Volatile private var capabilities: Protocol.Frame? = null
    private var basePtsUs = -1L

    private data class StreamInfo(
        val width: Int,
        val height: Int,
        val fps: Int,
        val bitrateKbps: Int,
        val rotation: Int,
    )

    fun setStream(width: Int, height: Int, fps: Int, bitrateKbps: Int, rotation: Int) {
        info = StreamInfo(width, height, fps, bitrateKbps, rotation)
        videoConfig = null
        basePtsUs = -1L
        client?.enqueueControl(profileActualFrame())
    }

    fun clearStream() {
        info = StreamInfo(0, 0, 0, 0, 0)
        videoConfig = null
        basePtsUs = -1L
    }

    fun setCapabilities(frame: Protocol.Frame) {
        capabilities = frame
        client?.enqueueControl(frame)
    }

    fun sendError(message: String) {
        client?.enqueueControl(
            Protocol.control("error") {
                put("code", "COMMAND_FAILED")
                put("message", message)
            },
        )
    }

    fun updateFps(fps: Int) {
        info = info.copy(fps = fps)
        client?.enqueueControl(profileActualFrame())
    }

    fun updateRotation(rotation: Int) {
        if (info.rotation == rotation) return
        info = info.copy(rotation = rotation)
        client?.enqueueControl(profileActualFrame())
    }

    private fun profileActualFrame() = Protocol.control("profile.actual") {
        put("width", info.width)
        put("height", info.height)
        put("fps", info.fps)
        put("bitrateKbps", info.bitrateKbps)
        put("rotation", info.rotation)
    }

    fun setProfiles(list: List<Map<String, Any?>>) {
        profiles = list
    }

    @Throws(IOException::class)
    fun start() {
        val socket = security.sslContext.serverSocketFactory.createServerSocket() as SSLServerSocket
        socket.needClientAuth = true
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
                runCatching { accepted.close() }
                continue
            }
            val newClient = Client(accepted as SSLSocket)
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

    fun counters() = Counters(
        framesSent.get(),
        bytesSent.get(),
        framesDropped.get(),
        client?.authorized == true,
    )

    fun pairingDecision(accept: Boolean) {
        client?.localDecision(accept)
    }

    fun disconnectComputer(fingerprint: String) {
        client?.takeIf { it.peerFingerprint == fingerprint }?.close()
    }

    fun stop() {
        runCatching { serverSocket?.close() }
        serverSocket = null
        client?.close()
        client = null
        acceptThread = null
    }

    private inner class Client(private val socket: SSLSocket) {
        private val lock = Object()
        private val controlQueue = ArrayDeque<Protocol.Frame>()
        private val videoQueue = ArrayDeque<Protocol.Frame>()
        private var waitingKeyframe = true
        @Volatile private var closed = false
        private val peer = socket.remoteSocketAddress.toString().trimStart('/')

        @Volatile var peerFingerprint: String = ""
            private set

        @Volatile var authorized = false
            private set

        @Volatile private var computerName = "computador"
        @Volatile private var announced = false

        private var pairNonce: String? = null
        private var pairLocal: Boolean? = null
        private var pairRemote: Boolean? = null
        private var pairing = false

        fun start() {
            Thread({ negotiate() }, "cdc-session").start()
        }

        private fun negotiate() {
            try {
                socket.soTimeout = HANDSHAKE_TIMEOUT_MS
                socket.startHandshake()
                socket.soTimeout = 0
                val cert = socket.session.peerCertificates.firstOrNull()
                    ?: throw IOException("o computador não apresentou certificado")
                peerFingerprint = PhoneSecurity.fingerprint(cert.encoded)
                runCatching {
                    socket.tcpNoDelay = true
                    socket.keepAlive = true
                }
            } catch (_: Exception) {
                close()
                return
            }
            enqueueControl(
                Protocol.control("hello") {
                    put("deviceName", Build.MODEL ?: "Android")
                    put("platform", "android")
                    put("appVersion", appVersion)
                },
                force = true,
            )
            Thread({ writeLoop() }, "cdc-writer").start()
            if (security.store.isPaired(peerFingerprint)) {
                authorize()
            } else {
                enqueueControl(
                    Protocol.control("error") {
                        put("code", "AUTH_FAILED")
                        put("message", "Este computador ainda não está pareado com este celular")
                    },
                    force = true,
                )
                pairing = true
                Thread({
                    Thread.sleep(PAIRING_TTL_MS)
                    if (!authorized && !closed) denyPairing("O pareamento expirou", sendToComputer = true)
                }, "cdc-pair-ttl").also { it.isDaemon = true }.start()
            }
            readLoop()
        }

        private fun authorize() {
            authorized = true
            capabilities?.let { enqueueControl(it) }
            if (info.width > 0) enqueueControl(profileActualFrame())
            videoConfig?.let { enqueueControl(Protocol.Frame(Protocol.TYPE_VIDEO_CONFIG, 0, 0, it)) }
            announced = true
            listener.onClientConnected(peer)
            listener.onKeyframeNeeded()
        }

        fun enqueueControl(frame: Protocol.Frame, force: Boolean = false) {
            if (!authorized && !force) return
            synchronized(lock) {
                controlQueue.add(frame)
                lock.notifyAll()
            }
        }

        fun enqueueVideo(frame: Protocol.Frame, keyframe: Boolean) {
            if (!authorized) return
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

        private fun onPairRequest(nonce: String) {
            if (authorized) return
            if (security.pairingLocked()) {
                denyPairing("Muitas tentativas de pareamento. Tente de novo em alguns minutos.", true, countFailure = false)
                return
            }
            synchronized(lock) {
                pairNonce = nonce
                pairLocal = null
                pairRemote = null
            }
            val code = PhoneSecurity.pairingCode(security.ownFingerprint, peerFingerprint, nonce)
            listener.onPairingRequest(code, computerName)
        }

        private fun onPairConfirm(nonce: String, confirmed: Boolean) {
            if (authorized) return
            synchronized(lock) {
                if (pairNonce == null || nonce != pairNonce) return
                pairRemote = confirmed
            }
            evaluatePairing()
        }

        fun localDecision(accept: Boolean) {
            synchronized(lock) {
                if (pairNonce == null || authorized) return
                pairLocal = accept
            }
            evaluatePairing()
        }

        private fun evaluatePairing() {
            val local: Boolean?
            val remote: Boolean?
            val nonce: String?
            synchronized(lock) {
                local = pairLocal
                remote = pairRemote
                nonce = pairNonce
            }
            when {
                local == false -> denyPairing("Recusado no celular", sendToComputer = true)
                remote == false -> denyPairing("Recusado no computador", sendToComputer = false)
                local == true && remote == true && nonce != null -> {
                    security.store.add(peerFingerprint, computerName)
                    enqueueControl(
                        Protocol.control("pair.confirm") {
                            put("nonce", nonce)
                            put("confirmed", true)
                        },
                        force = true,
                    )
                    pairing = false
                    listener.onPairingEnded(true, computerName, null)
                    authorize()
                }
            }
        }

        private fun denyPairing(reason: String, sendToComputer: Boolean, countFailure: Boolean = true) {
            if (authorized || !pairing) return
            pairing = false
            if (countFailure) security.recordPairingFailure()
            if (sendToComputer) {
                enqueueControl(
                    Protocol.control("pair.denied") { put("reason", reason) },
                    force = true,
                )
                Thread({
                    Thread.sleep(300)
                    close()
                }, "cdc-pair-close").start()
            } else {
                close()
            }
            listener.onPairingEnded(false, computerName, reason)
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
                    val type = message.optString("type")
                    if (type == "session.stop") break
                    if (type == "hello") {
                        message.optString("deviceName").takeIf { it.isNotBlank() }?.let { computerName = it.take(60) }
                        continue
                    }
                    if (!authorized) {
                        when (type) {
                            "pair.request" -> onPairRequest(message.optString("nonce"))
                            "pair.confirm" -> onPairConfirm(
                                message.optString("nonce"),
                                message.optBoolean("confirmed", false),
                            )
                        }
                        continue
                    }
                    when (type) {
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
                        "stream.start", "stream.stop", "fps.set", "camera.switch" ->
                            listener.onCommand(type, message)
                    }
                }
            } catch (_: Exception) {
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
            if (pairing && !authorized) {
                pairing = false
                listener.onPairingEnded(false, computerName, "A conexão foi interrompida")
            }
            if (announced) listener.onClientDisconnected()
        }
    }

    private companion object {
        const val MAX_PENDING_VIDEO = 6
        const val HANDSHAKE_TIMEOUT_MS = 10_000

        const val PAIRING_TTL_MS = 120_000L
    }
}
