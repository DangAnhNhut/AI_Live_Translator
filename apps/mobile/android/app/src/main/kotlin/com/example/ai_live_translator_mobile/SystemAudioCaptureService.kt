package com.example.ai_live_translator_mobile

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFormat
import android.media.AudioRecord
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import java.util.concurrent.ExecutorService
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.max

class SystemAudioCaptureService : Service() {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var mediaProjection: MediaProjection? = null
    private var audioRecord: AudioRecord? = null
    private var captureExecutor: ExecutorService? = null
    private val stopGuard = CaptureStopGuard()
    private val captureRunning = AtomicBoolean(false)
    private var deliberateStop = false
    private var emittedChunks = 0L
    private var emittedBytes = 0L

    private val projectionCallback = object : MediaProjection.Callback() {
        override fun onStop() {
            finishCapture(unexpected = !deliberateStop)
        }
    }

    override fun onCreate() {
        super.onCreate()
        SystemAudioCaptureBridge.registerService(this)
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> startCapture(intent)
            ACTION_STOP -> requestStop()
        }
        return START_NOT_STICKY
    }

    fun requestStop() {
        deliberateStop = true
        finishCapture(unexpected = false)
    }

    override fun onDestroy() {
        finishCapture(unexpected = !deliberateStop)
        super.onDestroy()
    }

    private fun startCapture(intent: Intent) {
        if (!SystemAudioCaptureContract.isSupported(Build.VERSION.SDK_INT)) {
            failStart("unsupported")
            return
        }

        try {
            startProjectionForegroundService()
        } catch (error: RuntimeException) {
            Log.w(TAG, "Unable to enter mediaProjection foreground state", error)
            failStart("foreground_service_failed")
            return
        }

        val resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, Int.MIN_VALUE)
        val resultData = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            intent.getParcelableExtra(EXTRA_RESULT_DATA, Intent::class.java)
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(EXTRA_RESULT_DATA)
        }
        if (resultCode == Int.MIN_VALUE || resultData == null) {
            failStart("projection_failed")
            return
        }

        val projection = try {
            val manager = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
            manager.getMediaProjection(resultCode, resultData)
        } catch (error: RuntimeException) {
            Log.w(TAG, "Unable to create MediaProjection", error)
            null
        }
        if (projection == null) {
            failStart("projection_failed")
            return
        }
        mediaProjection = projection
        projection.registerCallback(projectionCallback, mainHandler)

        val record = try {
            createAudioRecord(projection)
        } catch (error: RuntimeException) {
            Log.w(TAG, "Unable to create playback AudioRecord", error)
            failStart("audio_record_failed")
            return
        }

        val exactFormat = SystemAudioCaptureContract.isExactFormat(
            initialized = record.state == AudioRecord.STATE_INITIALIZED,
            sampleRate = record.sampleRate,
            channelCount = record.channelCount,
            encoding = record.audioFormat,
        )
        if (!exactFormat) {
            Log.w(
                TAG,
                "Unsupported capture format: state=${record.state}, " +
                    "rate=${record.sampleRate}, channels=${record.channelCount}, " +
                    "encoding=${record.audioFormat}",
            )
            record.release()
            failStart("unsupported_capture_format")
            return
        }

        audioRecord = record
        try {
            record.startRecording()
        } catch (error: RuntimeException) {
            Log.w(TAG, "Unable to begin playback AudioRecord", error)
            failStart("audio_record_failed")
            return
        }
        if (record.recordingState != AudioRecord.RECORDSTATE_RECORDING) {
            failStart("audio_record_failed")
            return
        }

        captureRunning.set(true)
        SystemAudioCaptureBridge.captureReady()
        Log.i(
            TAG,
            "System Audio ready: rate=${record.sampleRate}, channels=${record.channelCount}, " +
                "encoding=${record.audioFormat}",
        )
        captureExecutor = Executors.newSingleThreadExecutor { runnable ->
            Thread(runnable, "system-audio-capture").apply { isDaemon = true }
        }.also { executor ->
            executor.execute { captureLoop(record) }
        }
    }

    private fun createAudioRecord(projection: MediaProjection): AudioRecord {
        val playbackConfig = android.media.AudioPlaybackCaptureConfiguration.Builder(projection)
            .addMatchingUsage(AudioAttributes.USAGE_MEDIA)
            .addMatchingUsage(AudioAttributes.USAGE_GAME)
            .addMatchingUsage(AudioAttributes.USAGE_UNKNOWN)
            .build()
        val minBufferSize = AudioRecord.getMinBufferSize(
            TARGET_SAMPLE_RATE,
            AudioFormat.CHANNEL_IN_MONO,
            AudioFormat.ENCODING_PCM_16BIT,
        )
        if (minBufferSize <= 0) {
            throw IllegalStateException("16 kHz mono PCM16 AudioRecord is unsupported")
        }
        val format = AudioFormat.Builder()
            .setEncoding(AudioFormat.ENCODING_PCM_16BIT)
            .setSampleRate(TARGET_SAMPLE_RATE)
            .setChannelMask(AudioFormat.CHANNEL_IN_MONO)
            .build()
        return AudioRecord.Builder()
            .setAudioPlaybackCaptureConfig(playbackConfig)
            .setAudioFormat(format)
            .setBufferSizeInBytes(max(minBufferSize, PCM_CHUNK_BYTES * 4))
            .build()
    }

    private fun captureLoop(record: AudioRecord) {
        val samples = ShortArray(PCM_SAMPLES_PER_CHUNK)
        var filledSamples = 0
        while (captureRunning.get() && !Thread.currentThread().isInterrupted) {
            val read = record.read(
                samples,
                filledSamples,
                samples.size - filledSamples,
                AudioRecord.READ_BLOCKING,
            )
            when {
                read > 0 -> {
                    filledSamples += read
                    if (filledSamples == samples.size) {
                        val bytes = SystemAudioCaptureContract.toLittleEndian(samples, filledSamples)
                        emittedChunks++
                        emittedBytes += bytes.size
                        SystemAudioCaptureBridge.emitPcm(bytes)
                        filledSamples = 0
                    }
                }
                read == AudioRecord.ERROR_INVALID_OPERATION ||
                    read == AudioRecord.ERROR_BAD_VALUE ||
                    read == AudioRecord.ERROR_DEAD_OBJECT -> {
                    mainHandler.post {
                        finishCapture(unexpected = true, errorCode = "pcm_stream_failed")
                    }
                    return
                }
            }
        }
    }

    private fun failStart(code: String) {
        deliberateStop = true
        finishCapture(unexpected = false, errorCode = code)
    }

    private fun finishCapture(unexpected: Boolean, errorCode: String? = null) {
        if (!stopGuard.beginStop()) {
            return
        }
        captureRunning.set(false)
        val record = audioRecord
        audioRecord = null
        try {
            if (record?.recordingState == AudioRecord.RECORDSTATE_RECORDING) {
                record.stop()
            }
        } catch (_: RuntimeException) {
            // Release remains mandatory even after a platform stop failure.
        }
        record?.release()

        val projection = mediaProjection
        mediaProjection = null
        if (projection != null) {
            try {
                projection.unregisterCallback(projectionCallback)
            } catch (_: RuntimeException) {
                // Projection may already have been revoked by Android.
            }
            if (!unexpected) {
                try {
                    projection.stop()
                } catch (_: RuntimeException) {
                    // Projection may already be stopped.
                }
            }
        }

        captureExecutor?.shutdownNow()
        captureExecutor = null
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
        Log.i(TAG, "System Audio stopped: chunks=$emittedChunks, bytes=$emittedBytes")
        SystemAudioCaptureBridge.captureFinished(unexpected, errorCode)
    }

    private fun startProjectionForegroundService() {
        val manager = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        manager.createNotificationChannel(
            NotificationChannel(
                NOTIFICATION_CHANNEL_ID,
                "System Audio capture",
                NotificationManager.IMPORTANCE_LOW,
            ),
        )
        val activityIntent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(
            this,
            0,
            activityIntent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val notification = Notification.Builder(this, NOTIFICATION_CHANNEL_ID)
            .setSmallIcon(applicationInfo.icon)
            .setContentTitle("AI Live Translator")
            .setContentText("Capturing System Audio")
            .setCategory(Notification.CATEGORY_SERVICE)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
        startForeground(
            NOTIFICATION_ID,
            notification,
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION,
        )
    }

    companion object {
        const val ACTION_START =
            "com.example.ai_live_translator_mobile.action.START_SYSTEM_AUDIO"
        const val ACTION_STOP =
            "com.example.ai_live_translator_mobile.action.STOP_SYSTEM_AUDIO"
        const val EXTRA_RESULT_CODE = "media_projection_result_code"
        const val EXTRA_RESULT_DATA = "media_projection_result_data"

        private const val TAG = "SystemAudioCapture"
        private const val NOTIFICATION_CHANNEL_ID = "system_audio_capture"
        private const val NOTIFICATION_ID = 15001
        private const val TARGET_SAMPLE_RATE = 16000
        private const val PCM_SAMPLES_PER_CHUNK = 320
        private const val PCM_CHUNK_BYTES = PCM_SAMPLES_PER_CHUNK * Short.SIZE_BYTES
    }
}
