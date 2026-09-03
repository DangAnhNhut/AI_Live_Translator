from app.realtime.translation_protocol import (
    translation_configured_event,
    translation_final_event,
    translation_pending_event,
    translation_session_error_event,
    translation_utterance_error_event,
)


def test_translation_configured_event_identifies_stream_and_language_pair():
    assert translation_configured_event(
        stream_id="stream_123",
        source_language="vi",
        target_language="en",
    ) == {
        "type": "translation.configured",
        "stream_id": "stream_123",
        "source_language": "vi",
        "target_language": "en",
    }


def test_translation_pending_event_carries_source_mapping():
    assert translation_pending_event(
        stream_id="stream_123",
        utterance_id="utt_000001",
        source_segment_ids=("seg_001", "seg_002"),
        source_text="Xin chào mọi người.",
        source_language="vi",
        target_language="en",
    ) == {
        "type": "translation.pending",
        "stream_id": "stream_123",
        "utterance_id": "utt_000001",
        "source_segment_ids": ["seg_001", "seg_002"],
        "source_text": "Xin chào mọi người.",
        "source_language": "vi",
        "target_language": "en",
    }


def test_translation_final_event_carries_source_and_translated_text():
    assert translation_final_event(
        stream_id="stream_123",
        utterance_id="utt_000001",
        source_segment_ids=("seg_001", "seg_002"),
        source_text="Xin chào mọi người.",
        translated_text="Hello everyone.",
        source_language="vi",
        target_language="en",
    ) == {
        "type": "translation.final",
        "stream_id": "stream_123",
        "utterance_id": "utt_000001",
        "source_segment_ids": ["seg_001", "seg_002"],
        "source_text": "Xin chào mọi người.",
        "translated_text": "Hello everyone.",
        "source_language": "vi",
        "target_language": "en",
    }


def test_utterance_translation_error_is_safe_and_mapped_to_source():
    assert translation_utterance_error_event(
        stream_id="stream_123",
        utterance_id="utt_000001",
        source_segment_ids=("seg_001",),
        source_text="Xin chào.",
        source_language="vi",
        target_language="en",
        code="provider_error",
        message="Translation failed for this passage.",
    ) == {
        "type": "translation.error",
        "scope": "utterance",
        "stream_id": "stream_123",
        "utterance_id": "utt_000001",
        "source_segment_ids": ["seg_001"],
        "source_text": "Xin chào.",
        "source_language": "vi",
        "target_language": "en",
        "code": "provider_error",
        "message": "Translation failed for this passage.",
    }


def test_session_translation_error_has_no_fake_utterance_mapping():
    assert translation_session_error_event(
        stream_id="stream_123",
        source_language="vi",
        target_language="en",
        code="provider_unavailable",
        message="Translation is unavailable.",
    ) == {
        "type": "translation.error",
        "scope": "session",
        "stream_id": "stream_123",
        "source_language": "vi",
        "target_language": "en",
        "code": "provider_unavailable",
        "message": "Translation is unavailable.",
    }
