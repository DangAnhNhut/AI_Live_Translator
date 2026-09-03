package com.example.ai_live_translator_mobile

import java.util.concurrent.atomic.AtomicBoolean

internal object SystemAudioCaptureContract {
    private const val MIN_SUPPORTED_API = 29
    private const val TARGET_SAMPLE_RATE = 16000
    private const val TARGET_CHANNEL_COUNT = 1
    private const val PCM_16_BIT_ENCODING = 2

    fun isSupported(apiLevel: Int): Boolean = apiLevel >= MIN_SUPPORTED_API

    fun isExactFormat(
        initialized: Boolean,
        sampleRate: Int,
        channelCount: Int,
        encoding: Int,
    ): Boolean =
        initialized &&
            sampleRate == TARGET_SAMPLE_RATE &&
            channelCount == TARGET_CHANNEL_COUNT &&
            encoding == PCM_16_BIT_ENCODING

    fun toLittleEndian(samples: ShortArray, sampleCount: Int): ByteArray {
        require(sampleCount in 0..samples.size)
        val bytes = ByteArray(sampleCount * Short.SIZE_BYTES)
        for (index in 0 until sampleCount) {
            val value = samples[index].toInt()
            bytes[index * 2] = (value and 0xFF).toByte()
            bytes[index * 2 + 1] = ((value ushr 8) and 0xFF).toByte()
        }
        return bytes
    }
}

internal class CaptureStopGuard {
    private val stopping = AtomicBoolean(false)

    fun beginStop(): Boolean = stopping.compareAndSet(false, true)
}
