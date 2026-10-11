package com.player.m3u.projeto_tv

import android.app.UiModeManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.player.m3u/device"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            if (call.method == "isTvDevice") {
                val uiModeManager = getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
                val isTvUi = uiModeManager?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
                val hasLeanback = packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
                val hasTelevision = packageManager.hasSystemFeature("android.hardware.type.television")
                result.success(isTvUi || hasLeanback || hasTelevision)
            } else {
                result.notImplemented()
            }
        }
    }
}
