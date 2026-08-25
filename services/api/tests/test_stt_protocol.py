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
