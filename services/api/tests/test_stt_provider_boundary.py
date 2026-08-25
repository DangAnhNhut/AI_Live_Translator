import asyncio

import pytest

from app.ai.stt import (
    ProviderUnavailableError,
    SttProviderStream,
    SttTranscript,
    get_stt_provider_factory,
    unconfigured_stt_provider_factory,
)
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


def test_default_factory_is_explicitly_unconfigured():
    with pytest.raises(ProviderUnavailableError, match="not configured"):
        unconfigured_stt_provider_factory()

    assert get_stt_provider_factory() is unconfigured_stt_provider_factory


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
