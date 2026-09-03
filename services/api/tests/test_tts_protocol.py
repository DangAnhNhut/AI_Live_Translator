from app.realtime.tts_protocol import (
    tts_audio_event,
    tts_configured_event,
    tts_pending_event,
    tts_session_error_event,
    tts_utterance_error_event,
)


def test_tts_configured_omits_absent_voice_and_includes_selected_voice():
    assert tts_configured_event(
        stream_id="stream_123",
        target_language="en",
    ) == {
        "type": "tts.configured",
        "stream_id": "stream_123",
        "target_language": "en",
    }
    assert tts_configured_event(
        stream_id="stream_123",
        target_language="en",
        voice="voice-a",
    ) == {
        "type": "tts.configured",
        "stream_id": "stream_123",
        "target_language": "en",
        "voice": "voice-a",
    }


def test_tts_pending_uses_translation_identity():
    assert tts_pending_event(
        stream_id="stream_123",
        utterance_id="utt_000001",
        target_language="en",
    ) == {
        "type": "tts.pending",
        "stream_id": "stream_123",
        "utterance_id": "utt_000001",
        "target_language": "en",
    }


def test_tts_audio_is_metadata_only_and_omits_unknown_sample_rate():
    event = tts_audio_event(
        stream_id="stream_123",
        utterance_id="utt_000001",
        audio_id="audio_000001",
        target_language="en",
        mime_type="audio/mpeg",
        byte_length=6,
        sample_rate_hz=None,
    )

    assert event == {
        "type": "tts.audio",
        "stream_id": "stream_123",
        "utterance_id": "utt_000001",
        "audio_id": "audio_000001",
        "target_language": "en",
        "mime_type": "audio/mpeg",
        "byte_length": 6,
    }
    assert "audio_bytes" not in event
    assert "audio" not in event
    assert "base64" not in event


def test_tts_audio_includes_known_sample_rate():
    event = tts_audio_event(
        stream_id="stream_123",
        utterance_id="utt_000001",
        audio_id="audio_000001",
        target_language="en",
        mime_type="audio/wav",
        byte_length=6,
        sample_rate_hz=16000,
    )

    assert event["sample_rate_hz"] == 16000


def test_tts_error_schemas_keep_session_and_utterance_scopes_distinct():
    utterance = tts_utterance_error_event(
        stream_id="stream_123",
        utterance_id="utt_000001",
        target_language="en",
        code="provider_error",
        message="Speech synthesis failed for this passage.",
    )
    session = tts_session_error_event(
        stream_id="stream_123",
        target_language="en",
        code="provider_unavailable",
        message="Speech synthesis is unavailable.",
    )

    assert utterance == {
        "type": "tts.error",
        "scope": "utterance",
        "stream_id": "stream_123",
        "utterance_id": "utt_000001",
        "target_language": "en",
        "code": "provider_error",
        "message": "Speech synthesis failed for this passage.",
    }
    assert session == {
        "type": "tts.error",
        "scope": "session",
        "stream_id": "stream_123",
        "target_language": "en",
        "code": "provider_unavailable",
        "message": "Speech synthesis is unavailable.",
    }
