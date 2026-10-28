package com.shater.app

import androidx.core.view.ViewCompat
import androidx.core.view.WindowCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.WindowInsetsControllerCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "sa.shatarah/display")
            .setMethodCallHandler { call, result ->
                if (call.method == "immersive") {
                    hideSystemBars()
                    result.success(null)
                } else {
                    result.notImplemented()
                }
            }
    }

    override fun onPostResume() {
        super.onPostResume()
        window.decorView.post { hideSystemBars() }
    }

    override fun onFlutterUiDisplayed() {
        super.onFlutterUiDisplayed()
        window.decorView.post { hideSystemBars() }
    }

    override fun onWindowFocusChanged(hasFocus: Boolean) {
        super.onWindowFocusChanged(hasFocus)
        if (hasFocus) window.decorView.post { hideSystemBars() }
    }

    private fun hideSystemBars() {
        if (isFinishing || isDestroyed || !window.decorView.hasWindowFocus()) return
        val insets = ViewCompat.getRootWindowInsets(window.decorView)
        // Never fight the keyboard or consume Flutter's layout insets.
        if (insets?.isVisible(WindowInsetsCompat.Type.ime()) == true) return
        val controller = WindowCompat.getInsetsController(window, window.decorView)
        controller.systemBarsBehavior =
            WindowInsetsControllerCompat.BEHAVIOR_SHOW_TRANSIENT_BARS_BY_SWIPE
        controller.hide(WindowInsetsCompat.Type.systemBars())
    }
}
