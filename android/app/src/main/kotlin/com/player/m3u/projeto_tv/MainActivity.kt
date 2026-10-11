package com.player.m3u.projeto_tv

import android.app.PictureInPictureParams
import android.app.UiModeManager
import android.content.Context
import android.content.pm.PackageManager
import android.content.res.Configuration
import android.os.Build
import android.util.Rational
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val CHANNEL = "com.player.m3u/device"
    private var methodChannel: MethodChannel? = null
    private var isPipEnabledForPlayback: Boolean = false
    private var pipAspectNumerator: Int = 16
    private var pipAspectDenominator: Int = 9

    private fun isTvDevice(): Boolean {
        val uiModeManager = getSystemService(Context.UI_MODE_SERVICE) as? UiModeManager
        val isTvUi = uiModeManager?.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION
        val hasLeanback = packageManager.hasSystemFeature(PackageManager.FEATURE_LEANBACK)
        val hasTelevision = packageManager.hasSystemFeature("android.hardware.type.television")
        return isTvUi || hasLeanback || hasTelevision
    }

    private fun getRationalAspectRatio(): Rational {
        var num = pipAspectNumerator
        var den = pipAspectDenominator
        if (num <= 0 || den <= 0) {
            num = 16
            den = 9
        }
        val ratio = num.toDouble() / den.toDouble()
        return if (ratio < 0.41841) {
            Rational(1000, 2390)
        } else if (ratio > 2.39) {
            Rational(2390, 1000)
        } else {
            Rational(num, den)
        }
    }

    private fun updatePipParams() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (isTvDevice()) return
            if (!packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)) return

            try {
                val rational = getRationalAspectRatio()
                val builder = PictureInPictureParams.Builder().setAspectRatio(rational)

                // Android 12+ (API 31+): transição suave de gesto Home para PiP
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    builder.setAutoEnterEnabled(isPipEnabledForPlayback)
                }

                setPictureInPictureParams(builder.build())
            } catch (_: Exception) {
            }
        }
    }

    private fun enterPipMode(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            if (isTvDevice()) return false
            if (!packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)) return false

            return try {
                val rational = getRationalAspectRatio()
                val builder = PictureInPictureParams.Builder().setAspectRatio(rational)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    builder.setAutoEnterEnabled(true)
                }
                enterPictureInPictureMode(builder.build())
            } catch (_: Exception) {
                false
            }
        }
        return false
    }

    private var isKeepScreenOnEnabled: Boolean = false

    private fun applyKeepScreenOn(enable: Boolean) {
        try {
            if (enable) {
                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                findViewById<android.view.View>(android.R.id.content)?.keepScreenOn = true
            } else {
                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
                findViewById<android.view.View>(android.R.id.content)?.keepScreenOn = false
            }
        } catch (_: Exception) {
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        methodChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "isTvDevice" -> {
                        result.success(isTvDevice())
                    }
                    "keepScreenOn" -> {
                        val enable = call.argument<Boolean>("enable") ?: true
                        isKeepScreenOnEnabled = enable
                        applyKeepScreenOn(enable)
                        result.success(true)
                    }
                    "isPipSupported" -> {
                        val supported = !isTvDevice() &&
                            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                            packageManager.hasSystemFeature(PackageManager.FEATURE_PICTURE_IN_PICTURE)
                        result.success(supported)
                    }
                    "setPipState" -> {
                        val enabled = call.argument<Boolean>("enabled") ?: false
                        val num = call.argument<Int>("aspectNumerator") ?: 16
                        val den = call.argument<Int>("aspectDenominator") ?: 9
                        isPipEnabledForPlayback = enabled
                        pipAspectNumerator = num
                        pipAspectDenominator = den
                        updatePipParams()
                        result.success(true)
                    }
                    "enterPip" -> {
                        val entered = enterPipMode()
                        result.success(entered)
                    }
                    "isInPip" -> {
                        val inPip = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                            isInPictureInPictureMode
                        } else {
                            false
                        }
                        result.success(inPip)
                    }
                    else -> {
                        result.notImplemented()
                    }
                }
            }
        }
    }

    override fun onResume() {
        super.onResume()
        if (isKeepScreenOnEnabled) {
            applyKeepScreenOn(true)
        }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus && isKeepScreenOnEnabled) {
            applyKeepScreenOn(true)
        }
    }

    override fun onUserLeaveHint() {
        super.onUserLeaveHint()
        if (isPipEnabledForPlayback && !isTvDevice()) {
            enterPipMode()
        }
    }

    override fun onPictureInPictureModeChanged(isInPictureInPictureMode: Boolean, newConfig: Configuration) {
        super.onPictureInPictureModeChanged(isInPictureInPictureMode, newConfig)
        methodChannel?.invokeMethod("onPipModeChanged", isInPictureInPictureMode)
    }
}
