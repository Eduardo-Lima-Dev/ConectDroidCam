package dev.eduardolima.conectdroidcam.sender

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.math.BigInteger
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.MessageDigest
import java.security.cert.X509Certificate
import java.security.spec.ECGenParameterSpec
import java.util.Date
import javax.net.ssl.KeyManagerFactory
import javax.net.ssl.SSLContext
import javax.net.ssl.X509TrustManager
import javax.security.auth.x500.X500Principal

class PhoneSecurity(context: Context) {
    val store = PairingStore(context)

    private val certificate: X509Certificate = loadOrCreateCertificate()

    val ownFingerprint: String = fingerprint(certificate.encoded)

    val sslContext: SSLContext = SSLContext.getInstance("TLS").also { ctx ->
        val keyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        val factory = KeyManagerFactory.getInstance(KeyManagerFactory.getDefaultAlgorithm())
        factory.init(keyStore, null)
        ctx.init(factory.keyManagers, arrayOf(AcceptAnyClient), null)
    }

    private val failures = ArrayDeque<Long>()

    @Synchronized
    private fun recentFailures(): Int {
        val limit = System.currentTimeMillis() - LOCK_WINDOW_MS
        while (failures.isNotEmpty() && failures.first() < limit) failures.removeFirst()
        return failures.size
    }

    @Synchronized
    fun recordPairingFailure() {
        failures.addLast(System.currentTimeMillis())
    }

    fun pairingLocked(): Boolean = recentFailures() >= MAX_FAILURES

    private fun loadOrCreateCertificate(): X509Certificate {
        val keyStore = KeyStore.getInstance(KEYSTORE).apply { load(null) }
        if (!keyStore.containsAlias(ALIAS)) {
            val now = System.currentTimeMillis()
            val spec = KeyGenParameterSpec.Builder(
                ALIAS,
                KeyProperties.PURPOSE_SIGN or KeyProperties.PURPOSE_VERIFY,
            )
                .setAlgorithmParameterSpec(ECGenParameterSpec("secp256r1"))
                .setDigests(
                    KeyProperties.DIGEST_NONE,
                    KeyProperties.DIGEST_SHA256,
                    KeyProperties.DIGEST_SHA384,
                    KeyProperties.DIGEST_SHA512,
                )
                .setCertificateSubject(X500Principal("CN=conectdroidcam.local"))
                .setCertificateSerialNumber(BigInteger.valueOf(now))
                .setCertificateNotBefore(Date(now - DAY_MS))
                .setCertificateNotAfter(Date(now + 20 * 365 * DAY_MS))
                .build()
            KeyPairGenerator.getInstance(KeyProperties.KEY_ALGORITHM_EC, KEYSTORE).run {
                initialize(spec)
                generateKeyPair()
            }
        }
        return keyStore.getCertificate(ALIAS) as X509Certificate
    }

    private object AcceptAnyClient : X509TrustManager {
        override fun checkClientTrusted(chain: Array<X509Certificate>, authType: String) = Unit

        override fun checkServerTrusted(chain: Array<X509Certificate>, authType: String) = Unit

        override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()
    }

    companion object {
        private const val KEYSTORE = "AndroidKeyStore"
        private const val ALIAS = "conectdroidcam-identity"
        private const val DAY_MS = 24L * 60 * 60 * 1000
        private const val MAX_FAILURES = 5
        private const val LOCK_WINDOW_MS = 10L * 60 * 1000

        fun fingerprint(der: ByteArray): String =
            MessageDigest.getInstance("SHA-256").digest(der).joinToString("") { "%02x".format(it) }

        fun pairingCode(phoneFingerprint: String, computerFingerprint: String, nonce: String): String {
            val hash = MessageDigest.getInstance("SHA-256")
            hash.update("conectdroidcam-pairing-v1\u0000".toByteArray(Charsets.UTF_8))
            for (part in listOf(phoneFingerprint, computerFingerprint, nonce)) {
                val bytes = part.toByteArray(Charsets.UTF_8)
                hash.update(
                    byteArrayOf(
                        (bytes.size ushr 24).toByte(),
                        (bytes.size ushr 16).toByte(),
                        (bytes.size ushr 8).toByte(),
                        bytes.size.toByte(),
                    ),
                )
                hash.update(bytes)
            }
            val d = hash.digest()
            val n = ((d[0].toLong() and 0xff) shl 24) or ((d[1].toLong() and 0xff) shl 16) or
                ((d[2].toLong() and 0xff) shl 8) or (d[3].toLong() and 0xff)
            return "%06d".format(n % 1_000_000)
        }
    }
}

class PairingStore(context: Context) {
    data class Computer(val fingerprint: String, val name: String, val since: Long)

    private val prefs = context.getSharedPreferences("cdc_pairing", Context.MODE_PRIVATE)

    @Synchronized
    fun list(): List<Computer> =
        (prefs.getStringSet(KEY, emptySet()) ?: emptySet()).mapNotNull { line ->
            val parts = line.split('\t')
            if (parts.size < 3) null else Computer(parts[0], parts[1], parts[2].toLongOrNull() ?: 0L)
        }.sortedByDescending { it.since }

    @Synchronized
    fun isPaired(fingerprint: String): Boolean = list().any { it.fingerprint == fingerprint }

    @Synchronized
    fun add(fingerprint: String, name: String) {
        val others = list().filter { it.fingerprint != fingerprint }
        save(others + Computer(fingerprint, name.replace('\t', ' '), System.currentTimeMillis()))
    }

    @Synchronized
    fun remove(fingerprint: String) {
        save(list().filter { it.fingerprint != fingerprint })
    }

    private fun save(computers: List<Computer>) {
        prefs.edit()
            .putStringSet(KEY, computers.map { "${it.fingerprint}\t${it.name}\t${it.since}" }.toSet())
            .apply()
    }

    private companion object {
        const val KEY = "paired"
    }
}
