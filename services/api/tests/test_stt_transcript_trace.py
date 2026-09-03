import json

from app.core.config import Settings
from app.realtime.stt_transcript_trace import (
    create_stt_transcript_trace,
    get_stt_transcript_trace_factory,
)


def decode_trace_line(line: str) -> dict[str, object]:
    prefix = "STT_TRANSCRIPT_TRACE "
    assert line.startswith(prefix)
    return json.loads(line[len(prefix) :])


def test_transcript_trace_configuration_defaults_off_and_parses_environment(
    monkeypatch,
):
    monkeypatch.delenv("STT_TRANSCRIPT_TRACE", raising=False)
    assert Settings(_env_file=None).stt_transcript_trace is False

    monkeypatch.setenv("STT_TRANSCRIPT_TRACE", "true")
    assert Settings(_env_file=None).stt_transcript_trace is True


def test_disabled_transcript_trace_does_not_touch_sink():
    lines: list[str] = []

    trace = create_stt_transcript_trace(enabled=False, sink=lines.append)

    assert trace is None
    assert lines == []


def test_enabled_transcript_trace_emits_provider_and_websocket_json_lines():
    lines: list[str] = []
    trace = create_stt_transcript_trace(enabled=True, sink=lines.append)
    assert trace is not None

    trace.record_provider_result(
        kind="interim",
        text="xin",
        language="vi",
        provider_segment_metadata={
            "normalized_segment_id": "seg_001",
            "start": 0.0,
            "duration": 0.8,
            "speech_final": False,
            "from_finalize": False,
            "channel_index": [0, 1],
        },
    )
    trace.record_websocket_transcript_sent(
        segment_id="seg_001",
        kind="interim",
        text="xin",
        language="vi",
    )

    assert [decode_trace_line(line) for line in lines] == [
        {
            "category": "stt_transcript_trace",
            "source": "backend",
            "event": "provider_result",
            "provider_sequence": 1,
            "kind": "interim",
            "text": "xin",
            "text_length": 3,
            "language": "vi",
            "provider_segment_metadata": {
                "normalized_segment_id": "seg_001",
                "start": 0.0,
                "duration": 0.8,
                "speech_final": False,
                "from_finalize": False,
                "channel_index": [0, 1],
            },
        },
        {
            "category": "stt_transcript_trace",
            "source": "backend",
            "event": "websocket_transcript_sent",
            "sequence": 1,
            "segment_id": "seg_001",
            "kind": "interim",
            "text": "xin",
            "language": "vi",
        },
    ]


def test_runtime_factory_is_disabled_by_default(monkeypatch):
    monkeypatch.setattr(
        "app.realtime.stt_transcript_trace.settings.stt_transcript_trace",
        False,
    )

    factory = get_stt_transcript_trace_factory()

    assert factory() is None
