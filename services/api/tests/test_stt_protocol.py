import json

import pytest

from app.realtime.stt_protocol import (
    ConnectionState,
    ProtocolViolation,
    SttStart,
    SttStateMachine,
    closed_event,
    error_event,
    parse_control_message,
    ready_event,
    transcript_event,
)


VALID_START = """{
  "type": "stt.start",
  "audio": {
    "encoding": "pcm_s16le",
    "sample_rate_hz": 16000,
    "channels": 1
  },
  "language": "vi"
}"""


def test_parse_valid_start_contract():
    message = parse_control_message(VALID_START)

    assert isinstance(message, SttStart)
    assert message.type == "stt.start"
    assert message.audio.encoding == "pcm_s16le"
    assert message.audio.sample_rate_hz == 16000
    assert message.audio.channels == 1
    assert message.language == "vi"
    assert message.session_id is None
    assert message.translation is None
    assert message.tts is None


def test_parse_valid_start_with_session_id():
    payload = json.loads(VALID_START)
    payload["session_id"] = "demo-001"

    message = parse_control_message(json.dumps(payload))

    assert isinstance(message, SttStart)
    assert message.session_id == "demo-001"


def test_parse_valid_start_with_translation_target():
    payload = json.loads(VALID_START)
    payload["translation"] = {"target_language": "en"}

    message = parse_control_message(json.dumps(payload))

    assert isinstance(message, SttStart)
    assert message.translation is not None
    assert message.translation.target_language == "en"
    assert message.tts is None


def test_parse_valid_start_with_disabled_tts_preserves_stt_only_contract():
    payload = json.loads(VALID_START)
    payload["tts"] = {"enabled": False}

    message = parse_control_message(json.dumps(payload))

    assert message.tts is not None
    assert message.tts.enabled is False
    assert message.tts.voice is None
    assert message.translation is None


def test_parse_valid_start_with_translation_and_enabled_tts():
    payload = json.loads(VALID_START)
    payload["translation"] = {"target_language": "en"}
    payload["tts"] = {"enabled": True, "voice": "voice-a"}

    message = parse_control_message(json.dumps(payload))

    assert message.translation is not None
    assert message.translation.target_language == "en"
    assert message.tts is not None
    assert message.tts.enabled is True
    assert message.tts.voice == "voice-a"


def test_translation_only_start_keeps_tts_omitted():
    payload = json.loads(VALID_START)
    payload["translation"] = {"target_language": "en"}

    message = parse_control_message(json.dumps(payload))

    assert message.translation is not None
    assert message.translation.target_language == "en"
    assert message.tts is None


def test_parse_valid_translation_start_with_explicit_tts_disabled():
    payload = json.loads(VALID_START)
    payload["translation"] = {"target_language": "en"}
    payload["tts"] = {"enabled": False}

    message = parse_control_message(json.dumps(payload))

    assert message.translation is not None
    assert message.translation.target_language == "en"
    assert message.tts is not None
    assert message.tts.enabled is False
    assert message.tts.voice is None


@pytest.mark.parametrize(
    "tts",
    (
        None,
        {},
        {"enabled": 1},
        {"enabled": "true"},
        {"enabled": True, "voice": "   "},
        {"enabled": True, "voice": "v" * 129},
        {"enabled": True, "provider": "vendor"},
    ),
)
def test_parse_rejects_invalid_tts_configuration(tts):
    payload = json.loads(VALID_START)
    payload["translation"] = {"target_language": "en"}
    payload["tts"] = tts

    with pytest.raises(ProtocolViolation) as error:
        parse_control_message(json.dumps(payload))

    assert error.value.code == "invalid_message"


def test_enabled_tts_requires_translation_configuration():
    payload = json.loads(VALID_START)
    payload["tts"] = {"enabled": True}

    with pytest.raises(ProtocolViolation) as error:
        parse_control_message(json.dumps(payload))

    assert error.value.code == "invalid_message"


@pytest.mark.parametrize(
    "target_language",
    ("en", "ja", "ko", "zh-CN", "th", "fr", "de", "es"),
)
def test_parse_accepts_each_approved_translation_target(target_language):
    payload = json.loads(VALID_START)
    payload["translation"] = {"target_language": target_language}

    message = parse_control_message(json.dumps(payload))

    assert isinstance(message, SttStart)
    assert message.translation is not None
    assert message.translation.target_language == target_language


@pytest.mark.parametrize(
    "translation",
    (
        None,
        {},
        {"target_language": "vi"},
        {"target_language": "pt"},
        {"target_language": "en", "enabled": True},
    ),
)
def test_parse_rejects_invalid_translation_configuration(translation):
    payload = json.loads(VALID_START)
    payload["translation"] = translation

    with pytest.raises(ProtocolViolation) as error:
        parse_control_message(json.dumps(payload))

    assert error.value.code == "invalid_message"


def test_blank_session_id_is_rejected():
    payload = json.loads(VALID_START)
    payload["session_id"] = "   "

    with pytest.raises(ProtocolViolation) as error:
        parse_control_message(json.dumps(payload))

    assert error.value.code == "invalid_message"


def test_session_id_parsing_and_serialization_preserve_value():
    payload = json.loads(VALID_START)
    payload["session_id"] = "room_01.vi-demo"

    message = parse_control_message(json.dumps(payload))

    assert message.model_dump()["session_id"] == "room_01.vi-demo"


@pytest.mark.parametrize("session_id", (None, "demo/001", "a" * 65))
def test_invalid_normalized_session_id_is_rejected(session_id):
    payload = json.loads(VALID_START)
    payload["session_id"] = session_id

    with pytest.raises(ProtocolViolation) as error:
        parse_control_message(json.dumps(payload))

    assert error.value.code == "invalid_message"


@pytest.mark.parametrize(
    ("payload", "code"),
    [
        ("not-json", "invalid_message"),
        ("[]", "invalid_message"),
        ('{"type":"unknown"}', "invalid_message"),
        ('{"type":"stt.start","audio":{},"language":"vi"}', "unsupported_audio"),
        (
            '{"type":"stt.start","audio":{"encoding":"opus",'
            '"sample_rate_hz":16000,"channels":1},"language":"vi"}',
            "unsupported_audio",
        ),
        (
            '{"type":"stt.start","audio":{"encoding":"pcm_s16le",'
            '"sample_rate_hz":48000,"channels":1},"language":"vi"}',
            "unsupported_audio",
        ),
        (
            '{"type":"stt.start","audio":{"encoding":"pcm_s16le",'
            '"sample_rate_hz":16000,"channels":2},"language":"vi"}',
            "unsupported_audio",
        ),
        (
            '{"type":"stt.start","audio":{"encoding":"pcm_s16le",'
            '"sample_rate_hz":16000,"channels":1},"language":"en"}',
            "invalid_message",
        ),
        ('{"type":"stt.stop","extra":true}', "invalid_message"),
    ],
)
def test_parse_rejects_invalid_control_messages(payload, code):
    with pytest.raises(ProtocolViolation) as error:
        parse_control_message(payload)

    assert error.value.code == code
    assert error.value.recoverable is False


def test_normalized_event_shapes_are_provider_neutral():
    assert ready_event() == {"type": "stt.ready"}
    assert transcript_event("interim", "seg_001", "xin chào", "vi") == {
        "type": "transcript.interim",
        "segment_id": "seg_001",
        "text": "xin chào",
        "language": "vi",
    }
    assert transcript_event("final", "seg_001", "Xin chào.", "vi") == {
        "type": "transcript.final",
        "segment_id": "seg_001",
        "text": "Xin chào.",
        "language": "vi",
    }
    assert error_event("invalid_state", "Invalid state.") == {
        "type": "stt.error",
        "code": "invalid_state",
        "message": "Invalid state.",
        "recoverable": False,
    }
    assert closed_event() == {"type": "stt.closed"}


def test_ready_event_includes_producer_stream_identity():
    event = ready_event(stream_id="stream_123")

    assert event == {"type": "stt.ready", "stream_id": "stream_123"}


def test_transcript_events_include_producer_stream_identity():
    event = transcript_event(
        "final",
        "seg_001",
        "Xin chào.",
        "vi",
        stream_id="stream_123",
    )

    assert event == {
        "type": "transcript.final",
        "stream_id": "stream_123",
        "segment_id": "seg_001",
        "text": "Xin chào.",
        "language": "vi",
    }


def test_state_machine_accepts_normal_lifecycle():
    state = SttStateMachine()

    state.begin_start()
    assert state.state is ConnectionState.STARTING
    state.mark_ready()
    assert state.state is ConnectionState.STREAMING
    state.require_audio_allowed()
    state.begin_stop()
    assert state.state is ConnectionState.STOPPING
    state.mark_closed()
    assert state.state is ConnectionState.CLOSED


@pytest.mark.parametrize(
    ("setup", "action"),
    [
        ((), "audio"),
        (("begin_start",), "audio"),
        (("begin_start",), "begin_start"),
        (("begin_start", "mark_ready"), "begin_start"),
        ((), "begin_stop"),
        (("begin_start",), "begin_stop"),
        (("begin_start", "mark_ready", "begin_stop"), "audio"),
    ],
)
def test_state_machine_rejects_invalid_transitions(setup, action):
    state = SttStateMachine()
    for method_name in setup:
        getattr(state, method_name)()

    with pytest.raises(ProtocolViolation) as error:
        getattr(state, "require_audio_allowed" if action == "audio" else action)()

    assert error.value.code == "invalid_state"
    assert error.value.recoverable is False


def test_error_transition_is_terminal():
    state = SttStateMachine()

    state.mark_error()
    assert state.state is ConnectionState.ERROR
    state.mark_closed()
    assert state.state is ConnectionState.CLOSED
