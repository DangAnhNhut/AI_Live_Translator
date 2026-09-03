import asyncio
from dataclasses import FrozenInstanceError

import pytest

from app.ai.tts import (
    InvalidSynthesizedAudio,
    SpeechSynthesizer,
    SynthesizedAudio,
    TtsProviderError,
)
from tests.fakes.tts import FakeSpeechSynthesizer


def test_synthesized_audio_is_provider_neutral_immutable_and_valid():
    result = SynthesizedAudio(
        audio_bytes=b"audio",
        mime_type="audio/mpeg",
        sample_rate_hz=24000,
    )

    assert result.audio_bytes == b"audio"
    assert result.mime_type == "audio/mpeg"
    assert result.sample_rate_hz == 24000
    with pytest.raises(FrozenInstanceError):
        result.mime_type = "audio/wav"


def test_synthesized_audio_allows_unknown_sample_rate():
    result = SynthesizedAudio(
        audio_bytes=b"audio",
        mime_type="audio/mpeg",
    )

    assert result.sample_rate_hz is None


@pytest.mark.parametrize(
    "kwargs",
    (
        {"audio_bytes": b"", "mime_type": "audio/mpeg"},
        {"audio_bytes": bytearray(b"audio"), "mime_type": "audio/mpeg"},
        {"audio_bytes": b"audio", "mime_type": ""},
        {"audio_bytes": b"audio", "mime_type": "   "},
        {"audio_bytes": b"audio", "mime_type": "audio/mpeg", "sample_rate_hz": 0},
        {"audio_bytes": b"audio", "mime_type": "audio/mpeg", "sample_rate_hz": -1},
        {"audio_bytes": b"audio", "mime_type": "audio/mpeg", "sample_rate_hz": True},
        {"audio_bytes": b"audio", "mime_type": "audio/mpeg", "sample_rate_hz": 1.5},
    ),
)
def test_synthesized_audio_rejects_invalid_provider_neutral_data(kwargs):
    with pytest.raises(InvalidSynthesizedAudio):
        SynthesizedAudio(**kwargs)


def test_fake_synthesizer_records_successful_call():
    async def exercise():
        expected = SynthesizedAudio(b"speech", "audio/wav", 16000)
        fake = FakeSpeechSynthesizer(outcomes=(expected,))
        result = await fake.synthesize(
            text="Hello.",
            language="en",
            voice="voice-a",
        )
        return fake, result

    fake, result = asyncio.run(exercise())

    assert result.audio_bytes == b"speech"
    assert fake.calls[0].text == "Hello."
    assert fake.calls[0].language == "en"
    assert fake.calls[0].voice == "voice-a"
    assert fake.maximum_active_calls == 1
    assert isinstance(fake, SpeechSynthesizer)


def test_fake_synthesizer_uses_deterministic_default_audio():
    async def exercise():
        fake = FakeSpeechSynthesizer()
        result = await fake.synthesize(text="Hello.", language="en")
        return fake, result

    fake, result = asyncio.run(exercise())

    assert result == SynthesizedAudio(b"audio:Hello.", "audio/wav", 16000)
    assert len(fake.calls) == 1


def test_fake_synthesizer_raises_controlled_provider_failure():
    async def exercise():
        fake = FakeSpeechSynthesizer(
            outcomes=(TtsProviderError("controlled detail"),)
        )
        with pytest.raises(TtsProviderError):
            await fake.synthesize(text="Hello.", language="en")
        return fake

    fake = asyncio.run(exercise())

    assert len(fake.calls) == 1
    assert fake.active_calls == 0


def test_fake_synthesizer_gate_supports_hang_and_cancellation():
    async def exercise():
        gate = asyncio.Event()
        fake = FakeSpeechSynthesizer(gates=(gate,))
        task = asyncio.create_task(
            fake.synthesize(text="Hello.", language="en")
        )
        await fake.call_started.wait()
        task.cancel()
        with pytest.raises(asyncio.CancelledError):
            await task
        return fake

    fake = asyncio.run(exercise())

    assert fake.cancelled_calls == 1
    assert fake.active_calls == 0
