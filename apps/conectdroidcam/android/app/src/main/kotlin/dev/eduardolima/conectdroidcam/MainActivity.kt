package dev.eduardolima.conectdroidcam

import android.content.res.Configuration
import dev.eduardolima.conectdroidcam.sender.SenderBridge
import dev.eduardolima.conectdroidcam.update.UpdaterBridge
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine

class MainActivity : FlutterActivity() {
    private var bridge: SenderBridge? = null
    private var updater: UpdaterBridge? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        bridge = SenderBridge(this, flutterEngine)
        updater = UpdaterBridge(this, flutterEngine)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        bridge?.onPermissionResult(requestCode, grantResults)
    }

    override fun onConfigurationChanged(newConfig: Configuration) {
        super.onConfigurationChanged(newConfig)
        bridge?.onConfigurationChanged()
    }

    override fun onDestroy() {
        bridge?.stopAll()
        updater?.dispose()
        super.onDestroy()
    }
}
