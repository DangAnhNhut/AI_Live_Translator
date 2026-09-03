package com.example.ai_live_translator_mobile

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode != MEDIA_PROJECTION_REQUEST_CODE) {
            return
        }
        if (!SystemAudioCaptureBridge.isStartPending()) {
            return
        }
        if (resultCode != Activity.RESULT_OK || data == null) {
            SystemAudioCaptureBridge.failStart("projection_cancelled")
            return
        }
        try {
            val serviceIntent = Intent(this, SystemAudioCaptureService::class.java).apply {
                action = SystemAudioCaptureService.ACTION_START
                putExtra(SystemAudioCaptureService.EXTRA_RESULT_CODE, resultCode)
                putExtra(SystemAudioCaptureService.EXTRA_RESULT_DATA, data)
            }
            startForegroundService(serviceIntent)
        } catch (_: RuntimeException) {
            SystemAudioCaptureBridge.failStart("foreground_service_failed")
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            METHOD_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isSupported" -> result.success(
                    SystemAudioCaptureContract.isSupported(Build.VERSION.SDK_INT),
                )
                "start" -> startSystemAudio(result)
                "stop" -> SystemAudioCaptureBridge.requestStop(result)
                else -> result.notImplemented()
            }
        }
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            EVENT_CHANNEL,
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                SystemAudioCaptureBridge.attachEventSink(events)
            }

            override fun onCancel(arguments: Any?) {
                SystemAudioCaptureBridge.attachEventSink(null)
            }
        })
    }

    private fun startSystemAudio(result: MethodChannel.Result) {
        if (!SystemAudioCaptureContract.isSupported(Build.VERSION.SDK_INT)) {
            result.error("unsupported", "System Audio requires Android 10 or later.", null)
            return
        }
        if (!SystemAudioCaptureBridge.beginStart(result)) {
            return
        }
        val projectionManager =
            getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        try {
            @Suppress("DEPRECATION")
            startActivityForResult(
                projectionManager.createScreenCaptureIntent(),
                MEDIA_PROJECTION_REQUEST_CODE,
            )
        } catch (_: RuntimeException) {
            SystemAudioCaptureBridge.failStart("projection_failed")
        }
    }

    companion object {
        private const val METHOD_CHANNEL = "ai_live_translator/system_audio/methods"
        private const val EVENT_CHANNEL = "ai_live_translator/system_audio/events"
        private const val MEDIA_PROJECTION_REQUEST_CODE = 15002
    }
}
