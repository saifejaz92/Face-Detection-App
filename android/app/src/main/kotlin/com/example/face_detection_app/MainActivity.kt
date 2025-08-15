package com.example.face_detection_app

import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import androidx.annotation.NonNull // ✅ Correct import

class MainActivity : FlutterActivity() {
    private fun _getNativeLibDir(): String {
        return applicationInfo.nativeLibraryDir
    }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) { // ✅ Correct keyword
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                if (call.method == "getNativeLibDir") {
                    val nativeLibDir: String = _getNativeLibDir()
                    result.success(nativeLibDir)
                } else {
                    result.notImplemented()
                }
            }
    }

    companion object {
        init {
            System.loadLibrary("facerec")
        }

        private const val CHANNEL: String = "samples.flutter.dev/facesdk"
    }
}
