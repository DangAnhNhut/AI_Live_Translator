package com.example.ai_live_translator_mobile

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SystemAudioCaptureContractTest {
    @Test
    fun `playback capture support begins at API 29`() {
        assertFalse(SystemAudioCaptureContract.isSupported(apiLevel = 28))
        assertTrue(SystemAudioCaptureContract.isSupported(apiLevel = 29))
        assertTrue(SystemAudioCaptureContract.isSupported(apiLevel = 36))
    }

    @Test
    fun `only initialized 16 kHz mono PCM16 is accepted`() {
        assertTrue(
            SystemAudioCaptureContract.isExactFormat(
                initialized = true,
                sampleRate = 16000,
                channelCount = 1,
                encoding = 2,
            ),
        )
        assertFalse(
            SystemAudioCaptureContract.isExactFormat(
                initialized = false,
                sampleRate = 16000,
                channelCount = 1,
                encoding = 2,
            ),
        )
        assertFalse(
            SystemAudioCaptureContract.isExactFormat(
                initialized = true,
                sampleRate = 48000,
                channelCount = 1,
                encoding = 2,
            ),
        )
        assertFalse(
            SystemAudioCaptureContract.isExactFormat(
                initialized = true,
                sampleRate = 16000,
                channelCount = 2,
                encoding = 2,
            ),
        )
        assertFalse(
            SystemAudioCaptureContract.isExactFormat(
                initialized = true,
                sampleRate = 16000,
                channelCount = 1,
                encoding = 4,
            ),
        )
    }

    @Test
    fun `PCM16 samples are serialized signed little endian`() {
        val encoded = SystemAudioCaptureContract.toLittleEndian(
            shortArrayOf(Short.MIN_VALUE, -1, 0, 1, Short.MAX_VALUE),
            sampleCount = 5,
        )

        assertArrayEquals(
            byteArrayOf(
                0x00,
                0x80.toByte(),
                0xFF.toByte(),
                0xFF.toByte(),
                0x00,
                0x00,
                0x01,
                0x00,
                0xFF.toByte(),
                0x7F,
            ),
            encoded,
        )
    }

    @Test
    fun `stop guard permits cleanup exactly once`() {
        val guard = CaptureStopGuard()

        assertTrue(guard.beginStop())
        assertFalse(guard.beginStop())
    }
}
