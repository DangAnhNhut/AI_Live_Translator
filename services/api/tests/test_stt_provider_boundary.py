import asyncio

import pytest
from pydantic import ValidationError

import app.ai.stt as stt_module
from app.ai.stt import (
    ProviderUnavailableError,
    SttProviderStream,
    SttTranscript,
    get_stt_provider_factory,
    unconfigured_stt_provider_factory,
)
from app.core.config import Settings
from app.realtime.stt_protocol import AudioConfig
from tests.fakes.stt import FakeSttProviderStream


def test_fake_satisfies_provider_stream_protocol():
    assert isinstance(FakeSttProviderStream(), SttProviderStream)


def test_transcript_value_is_provider_neutral():
    transcript = SttTranscript(
        kind="interim",
        segment_id="seg_001",
        text="xin chào",
        language="vi",
    )

    assert transcript.kind == "interim"
    assert transcript.segment_id == "seg_001"
    assert transcript.text == "xin chào"
    assert transcript.language == "vi"


def test_default_factory_is_explicitly_unconfigured(monkeypatch):
    unconfigured = Settings(
        _env_file=None,
        stt_provider=None,
        deepgram_api_key=None,
    )
    monkeypatch.setattr(stt_module, "settings", unconfigured)

    with pytest.raises(ProviderUnavailableError, match="not configured"):
        unconfigured_stt_provider_factory()

    assert get_stt_provider_factory() is unconfigured_stt_provider_factory


def test_factory_selects_deepgram_when_explicitly_configured(monkeypatch):
    configured = Settings(
        _env_file=None,
        stt_provider="deepgram",
        deepgram_api_key="test-deepgram-key",
    )
    monkeypatch.setattr(stt_module, "settings", configured, raising=False)

    stream = get_stt_provider_factory()()

    from app.ai.deepgram import DeepgramSttStream

    assert isinstance(stream, DeepgramSttStream)
    assert isinstance(stream, SttProviderStream)


def test_factory_keeps_deepgram_unavailable_without_api_key(monkeypatch):
    configured = Settings(
        _env_file=None,
        stt_provider="deepgram",
        deepgram_api_key="",
    )
    monkeypatch.setattr(stt_module, "settings", configured, raising=False)

    with pytest.raises(ProviderUnavailableError, match="not configured"):
        get_stt_provider_factory()()


def test_deepgram_configuration_rejects_non_vietnamese_language():
    with pytest.raises(ValidationError):
        Settings(
            _env_file=None,
            stt_provider="deepgram",
            deepgram_api_key="test-deepgram-key",
            deepgram_language="en",
        )


def test_fake_records_audio_and_cleanup():
    stream = FakeSttProviderStream()
    audio = AudioConfig(
        encoding="pcm_s16le",
        sample_rate_hz=16000,
        channels=1,
    )

    async def exercise_stream():
        await stream.start(audio, "vi")
        await stream.send_audio(b"\x00\x00")
        await stream.finish_input()
        await stream.close()

    asyncio.run(exercise_stream())

    assert stream.start_calls == [(audio, "vi")]
    assert stream.audio_chunks == [b"\x00\x00"]
    assert stream.finish_calls == 1
    assert stream.close_calls == 1
