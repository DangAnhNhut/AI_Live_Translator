package com.example.ai_live_translator_mobile

import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

internal object SystemAudioCaptureBridge {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null
    private var pendingStart: MethodChannel.Result? = null
    private val pendingStops = mutableListOf<MethodChannel.Result>()
    private var service: SystemAudioCaptureService? = null
    private var active = false

    fun attachEventSink(sink: EventChannel.EventSink?) {
        eventSink = sink
    }

    fun beginStart(result: MethodChannel.Result): Boolean {
        if (pendingStart != null || active || service != null) {
            result.error("capture_already_active", "System Audio capture is already active.", null)
            return false
        }
        pendingStart = result
        return true
    }

    fun isStartPending(): Boolean = pendingStart != null

    fun registerService(captureService: SystemAudioCaptureService) {
        service = captureService
    }

    fun captureReady() {
        mainHandler.post {
            active = true
            pendingStart?.success(null)
            pendingStart = null
        }
    }

    fun failStart(code: String) {
        mainHandler.post {
            pendingStart?.error(code, userMessageFor(code), null)
            pendingStart = null
            active = false
            service = null
            completeStops()
        }
    }

    fun requestStop(result: MethodChannel.Result) {
        pendingStops.add(result)
        val captureService = service
        if (captureService == null) {
            pendingStart?.error("capture_cancelled", "System Audio capture was cancelled.", null)
            pendingStart = null
            active = false
            completeStops()
            return
        }
        captureService.requestStop()
    }

    fun emitPcm(bytes: ByteArray) {
        mainHandler.post {
            if (active) {
                eventSink?.success(mapOf("type" to "pcm", "data" to bytes))
            }
        }
    }

    fun captureFinished(unexpected: Boolean, errorCode: String? = null) {
        mainHandler.post {
            val wasActive = active
            active = false
            service = null
            if (pendingStart != null) {
                val code = errorCode ?: "capture_failed"
                pendingStart?.error(code, userMessageFor(code), null)
                pendingStart = null
            } else if (wasActive && unexpected) {
                if (errorCode != null) {
                    eventSink?.success(mapOf("type" to "error", "code" to errorCode))
                }
                eventSink?.success(mapOf("type" to "ended", "reason" to "projection_stopped"))
            }
            completeStops()
        }
    }

    private fun completeStops() {
        val results = pendingStops.toList()
        pendingStops.clear()
        results.forEach { it.success(null) }
    }

    private fun userMessageFor(code: String): String =
        when (code) {
            "unsupported" -> "System Audio requires Android 10 or later."
            "projection_cancelled" -> "System Audio permission was cancelled."
            "foreground_service_failed" -> "Unable to start protected System Audio capture."
            "projection_failed" -> "Unable to start System Audio sharing."
            "unsupported_capture_format" ->
                "This device cannot provide 16 kHz mono System Audio."
            "audio_record_failed" -> "Unable to start System Audio capture."
            else -> "System Audio capture failed."
        }
}
