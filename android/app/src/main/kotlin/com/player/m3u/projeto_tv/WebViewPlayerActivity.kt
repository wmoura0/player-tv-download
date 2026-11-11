package com.player.m3u.projeto_tv

import android.app.Activity
import android.content.pm.ActivityInfo
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.util.Log
import android.view.KeyEvent
import android.view.View
import android.view.ViewGroup
import android.view.Window
import android.view.WindowManager
import android.webkit.ConsoleMessage
import android.webkit.JavascriptInterface
import android.webkit.WebChromeClient
import android.webkit.WebResourceError
import android.webkit.WebResourceRequest
import android.webkit.WebSettings
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.FrameLayout

class WebViewPlayerActivity : Activity() {

    private val TAG = "JESSFLIX_WEBVIEW"
    private var webView: WebView? = null
    private var customView: View? = null
    private var customViewCallback: WebChromeClient.CustomViewCallback? = null
    private var fullscreenContainer: FrameLayout? = null

    // Telemetria de eventos recebidos da página
    private var isVideoPlaying: Boolean = false
    private var lastCurrentTime: Double = 0.0
    private var lastDuration: Double = 0.0

    inner class JessFlixBridge {
        @JavascriptInterface
        fun onPlay() {
            isVideoPlaying = true
            Log.i(TAG, "[EVENT] Reprodução iniciada (Play)")
        }

        @JavascriptInterface
        fun onPause() {
            isVideoPlaying = false
            Log.i(TAG, "[EVENT] Reprodução pausada (Pause)")
        }

        @JavascriptInterface
        fun onTimeUpdate(currentTime: Double, duration: Double) {
            lastCurrentTime = currentTime
            lastDuration = duration
        }

        @JavascriptInterface
        fun onEnded() {
            isVideoPlaying = false
            Log.i(TAG, "[EVENT] Reprodução concluída (Ended)")
        }

        @JavascriptInterface
        fun onError(message: String) {
            Log.e(TAG, "[EVENT_ERROR] Erro no player HTML5: $message")
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Configuração de tela cheia sem título e mantendo tela ligada
        requestWindowFeature(Window.FEATURE_NO_TITLE)
        window.setFlags(
            WindowManager.LayoutParams.FLAG_FULLSCREEN,
            WindowManager.LayoutParams.FLAG_FULLSCREEN
        )
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        requestedOrientation = ActivityInfo.SCREEN_ORIENTATION_SENSOR_LANDSCAPE

        // Layout raiz
        val rootLayout = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        }

        fullscreenContainer = FrameLayout(this).apply {
            setBackgroundColor(Color.BLACK)
            visibility = View.GONE
            layoutParams = ViewGroup.LayoutParams(
                ViewGroup.LayoutParams.MATCH_PARENT,
                ViewGroup.LayoutParams.MATCH_PARENT
            )
        }

        val wv = WebView(this).apply {
            setBackgroundColor(Color.BLACK)
            layoutParams = FrameLayout.LayoutParams(
                FrameLayout.LayoutParams.MATCH_PARENT,
                FrameLayout.LayoutParams.MATCH_PARENT
            )
        }

        setupWebSettings(wv)
        setupClients(wv)

        rootLayout.addView(wv)
        rootLayout.addView(fullscreenContainer)
        setContentView(rootLayout)

        webView = wv

        // URL a ser carregada (padrão: arquivo local em assets)
        val targetUrl = intent.getStringExtra("EXTRA_URL") ?: "file:///android_asset/poc_player.html"
        val title = intent.getStringExtra("EXTRA_TITLE") ?: "Vídeo de Teste PoC"

        Log.i(TAG, "[INIT] Carregando URL na WebView: $targetUrl | Título: $title")
        wv.loadUrl(targetUrl)
    }

    private fun setupWebSettings(wv: WebView) {
        val settings = wv.settings
        settings.javaScriptEnabled = true
        settings.domStorageEnabled = true
        settings.mediaPlaybackRequiresUserGesture = false
        settings.allowFileAccess = true
        settings.setSupportMultipleWindows(false)
        settings.javaScriptCanOpenWindowsAutomatically = false
        settings.cacheMode = WebSettings.LOAD_NO_CACHE

        // Habilita aceleração por hardware e viewport responsivo
        settings.useWideViewPort = true
        settings.loadWithOverviewMode = true

        // User-Agent padronizado
        val defaultUserAgent = settings.userAgentString
        settings.userAgentString = "$defaultUserAgent JessFlixFireTV/1.2.9"

        wv.addJavascriptInterface(JessFlixBridge(), "JessFlixBridge")
    }

    private fun setupClients(wv: WebView) {
        wv.webChromeClient = object : WebChromeClient() {
            override fun onShowCustomView(view: View?, callback: CustomViewCallback?) {
                if (customView != null) {
                    callback?.onCustomViewHidden()
                    return
                }
                customView = view
                customViewCallback = callback
                fullscreenContainer?.addView(view)
                fullscreenContainer?.visibility = View.VISIBLE
                wv.visibility = View.GONE
                Log.d(TAG, "[FULLSCREEN] Modo tela cheia nativo ativado")
            }

            override fun onHideCustomView() {
                if (customView == null) return
                fullscreenContainer?.visibility = View.GONE
                fullscreenContainer?.removeView(customView)
                customView = null
                customViewCallback?.onCustomViewHidden()
                wv.visibility = View.VISIBLE
                Log.d(TAG, "[FULLSCREEN] Modo tela cheia nativo desativado")
            }

            override fun onConsoleMessage(consoleMessage: ConsoleMessage?): Boolean {
                Log.d(TAG, "[JS_CONSOLE] ${consoleMessage?.message()} (linha ${consoleMessage?.lineNumber()})")
                return true
            }
        }

        wv.webViewClient = object : WebViewClient() {
            override fun onReceivedError(view: WebView?, request: WebResourceRequest?, error: WebResourceError?) {
                super.onReceivedError(view, request, error)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    Log.e(TAG, "[LOAD_ERROR] Falha de carregamento: ${error?.description} (${error?.errorCode})")
                }
            }

            override fun shouldOverrideUrlLoading(view: WebView?, request: WebResourceRequest?): Boolean {
                // Impede navegação para fora da página de teste autorizada
                val url = request?.url?.toString() ?: ""
                if (url.startsWith("file:///android_asset/") || url.startsWith("https://commondatastorage.googleapis.com")) {
                    return false
                }
                Log.w(TAG, "[BLOCKED_NAV] Bloqueada tentativa de navegação externa: $url")
                return true
            }
        }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (event.action == KeyEvent.ACTION_DOWN) {
            when (event.keyCode) {
                KeyEvent.KEYCODE_DPAD_CENTER,
                KeyEvent.KEYCODE_ENTER,
                KeyEvent.KEYCODE_NUMPAD_ENTER,
                KeyEvent.KEYCODE_MEDIA_PLAY_PAUSE,
                KeyEvent.KEYCODE_MEDIA_PLAY,
                KeyEvent.KEYCODE_MEDIA_PAUSE -> {
                    Log.i(TAG, "[KEY_D-PAD] Tecla Play/Pause pressionada")
                    webView?.evaluateJavascript("if (window.togglePlay) { window.togglePlay(); }", null)
                    return true
                }
                KeyEvent.KEYCODE_DPAD_LEFT,
                KeyEvent.KEYCODE_MEDIA_REWIND -> {
                    Log.i(TAG, "[KEY_D-PAD] Tecla Retroceder 10s")
                    webView?.evaluateJavascript("if (window.seekBy) { window.seekBy(-10); }", null)
                    return true
                }
                KeyEvent.KEYCODE_DPAD_RIGHT,
                KeyEvent.KEYCODE_MEDIA_FAST_FORWARD -> {
                    Log.i(TAG, "[KEY_D-PAD] Tecla Avançar 10s")
                    webView?.evaluateJavascript("if (window.seekBy) { window.seekBy(10); }", null)
                    return true
                }
                KeyEvent.KEYCODE_DPAD_UP,
                KeyEvent.KEYCODE_DPAD_DOWN -> {
                    Log.i(TAG, "[KEY_D-PAD] Tecla Cima/Baixo - Exibindo OSD")
                    webView?.evaluateJavascript("if (window.showOsd) { window.showOsd(); }", null)
                    return true
                }
                KeyEvent.KEYCODE_BACK -> {
                    Log.i(TAG, "[KEY_D-PAD] Tecla Voltar pressionada - Encerrando WebViewPlayerActivity")
                    if (customView != null) {
                        wvHideCustomView()
                    } else {
                        finish()
                    }
                    return true
                }
            }
        }
        return super.dispatchKeyEvent(event)
    }

    private fun wvHideCustomView() {
        webView?.webChromeClient?.onHideCustomView()
    }

    override fun onResume() {
        super.onResume()
        webView?.onResume()
    }

    override fun onPause() {
        webView?.onPause()
        super.onPause()
    }

    override fun onDestroy() {
        Log.i(TAG, "[DESTROY] Encerrando WebViewPlayerActivity e liberando recursos")
        try {
            webView?.stopLoading()
            webView?.loadUrl("about:blank")
            webView?.clearHistory()
            (webView?.parent as? ViewGroup)?.removeView(webView)
            webView?.destroy()
            webView = null
            fullscreenContainer = null
            customView = null
            customViewCallback = null
        } catch (e: Exception) {
            Log.e(TAG, "[DESTROY_ERROR] Erro ao destruir WebView: ${e.message}")
        }
        super.onDestroy()
    }
}
