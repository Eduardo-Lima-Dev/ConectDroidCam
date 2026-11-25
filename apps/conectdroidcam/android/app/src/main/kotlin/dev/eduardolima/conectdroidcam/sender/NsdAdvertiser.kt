package dev.eduardolima.conectdroidcam.sender

import android.content.Context
import android.net.nsd.NsdManager
import android.net.nsd.NsdServiceInfo
import android.net.wifi.WifiManager
import android.os.Build

class NsdAdvertiser(context: Context) {
    private val manager = context.getSystemService(Context.NSD_SERVICE) as NsdManager
    private val wifi = context.applicationContext.getSystemService(Context.WIFI_SERVICE) as? WifiManager

    private var multicastLock: WifiManager.MulticastLock? = null
    private var listener: NsdManager.RegistrationListener? = null

    fun start(port: Int, version: String, onResult: (name: String?, error: String?) -> Unit) {
        stop()
        multicastLock = runCatching {
            wifi?.createMulticastLock("conectdroidcam-mdns")?.apply {
                setReferenceCounted(false)
                acquire()
            }
        }.getOrNull()
        val info = NsdServiceInfo().apply {
            serviceName = "ConectDroidCam ${Build.MODEL ?: "Android"}"
            serviceType = SERVICE_TYPE
            setPort(port)
            setAttribute("version", version)
            setAttribute("protocol", "1")
        }
        val registration = object : NsdManager.RegistrationListener {
            override fun onServiceRegistered(registered: NsdServiceInfo) = onResult(registered.serviceName, null)

            override fun onRegistrationFailed(failed: NsdServiceInfo, errorCode: Int) =
                onResult(null, "código $errorCode")

            override fun onServiceUnregistered(unregistered: NsdServiceInfo) = Unit

            override fun onUnregistrationFailed(failed: NsdServiceInfo, errorCode: Int) = Unit
        }
        listener = registration
        try {
            manager.registerService(info, NsdManager.PROTOCOL_DNS_SD, registration)
        } catch (e: Exception) {
            listener = null
            onResult(null, e.message ?: e.javaClass.simpleName)
        }
    }

    fun stop() {
        runCatching { multicastLock?.takeIf { it.isHeld }?.release() }
        multicastLock = null
        val current = listener ?: return
        listener = null
        runCatching { manager.unregisterService(current) }
    }

    companion object {
        const val SERVICE_TYPE = "_conectdroidcam._tcp."
    }
}
