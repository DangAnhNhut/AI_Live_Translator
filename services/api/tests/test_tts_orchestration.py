import asyncio

import pytest

from app.realtime.translation_protocol import (
    translation_final_event,
    translation_pending_event,
    translation_utterance_error_event,
)
from app.realtime.tts_orchestration import TranslationFinalTtsBridge


class RecordingTtsSession:
    def __init__(
        self,
        *,
        submit_error: BaseException | None = None,
        recorder: list[tuple[str, object]] | None = None,
    ) -> None:
        self.submit_error = submit_error
        self.recorder = recorder
        self.submissions: list[dict[str, object]] = []
        self.abort_calls = 0

    async def submit(self, **kwargs: object) -> None:
        self.submissions.append(kwargs)
        if self.recorder is not None:
            self.recorder.append(("submit", kwargs))
        if self.submit_error is not None:
            raise self.submit_error

    async def abort(self) -> None:
        self.abort_calls += 1


def translation_final(*, utterance_id: str = "utt_000001") -> dict[str, object]:
    return translation_final_event(
        stream_id="stream_123",
        utterance_id=utterance_id,
        source_segment_ids=["seg_000001"],
        source_text="Xin chao",
        translated_text="Hello",
        source_language="vi",
        target_language="en",
    )


def make_bridge(*, publish_event, tts_session: RecordingTtsSession):
    return TranslationFinalTtsBridge(
        publish_event=publish_event,
        tts_session=tts_session,
        stream_id="stream_123",
        target_language="en",
    )


def test_bridge_publishes_translation_final_before_exact_tts_submission():
    async def exercise():
        calls: list[tuple[str, object]] = []
        tts = RecordingTtsSession(recorder=calls)

        async def publish_event(event):
            calls.append(("publish", event))

        bridge = make_bridge(publish_event=publish_event, tts_session=tts)
        event = translation_final()
        await bridge.publish(event)
        return calls

    calls = asyncio.run(exercise())

    assert calls == [
        ("publish", translation_final()),
        (
            "submit",
            {
                "stream_id": "stream_123",
                "utterance_id": "utt_000001",
                "source_segment_ids": ["seg_000001"],
                "translated_text": "Hello",
                "target_language": "en",
            },
        ),
    ]


@pytest.mark.parametrize(
    "event",
    [
        translation_pending_event(
            stream_id="stream_123",
            utterance_id="utt_000001",
            source_segment_ids=["seg_000001"],
            source_text="Xin chao",
            source_language="vi",
            target_language="en",
        ),
        translation_utterance_error_event(
            stream_id="stream_123",
            utterance_id="utt_000001",
            source_segment_ids=["seg_000001"],
            source_text="Xin chao",
            source_language="vi",
            target_language="en",
            code="provider_error",
            message="Translation failed for this passage.",
        ),
    ],
)
def test_bridge_does_not_submit_non_final_translation_events(event):
    async def exercise():
        published: list[dict[str, object]] = []
        tts = RecordingTtsSession()

        async def publish_event(published_event):
            published.append(published_event)

        bridge = make_bridge(publish_event=publish_event, tts_session=tts)
        await bridge.publish(event)
        return published, tts.submissions

    published, submissions = asyncio.run(exercise())

    assert published == [event]
    assert submissions == []


def test_one_final_event_causes_one_submit():
    async def exercise():
        tts = RecordingTtsSession()

        async def publish_event(event):
            return None

        bridge = make_bridge(publish_event=publish_event, tts_session=tts)
        await bridge.publish(translation_final())
        return tts.submissions

    assert len(asyncio.run(exercise())) == 1


def test_base_publication_failure_prevents_tts_submission():
    async def exercise():
        tts = RecordingTtsSession()

        async def publish_event(event):
            raise RuntimeError("publisher unavailable")

        bridge = make_bridge(publish_event=publish_event, tts_session=tts)
        with pytest.raises(RuntimeError, match="publisher unavailable"):
            await bridge.publish(translation_final())
        return tts.submissions

    assert asyncio.run(exercise()) == []


def test_unexpected_submit_failure_aborts_tts_emits_one_safe_session_error_and_keeps_translation_publisher_usable():
    async def exercise():
        published: list[dict[str, object]] = []
        tts = RecordingTtsSession(submit_error=RuntimeError("secret submit detail"))

        async def publish_event(event):
            published.append(event)

        bridge = make_bridge(publish_event=publish_event, tts_session=tts)
        await bridge.publish(translation_final())
        await bridge.publish(translation_final(utterance_id="utt_000002"))
        return published, tts

    published, tts = asyncio.run(exercise())

    assert tts.abort_calls == 1
    assert len(tts.submissions) == 1
    assert [event["type"] for event in published] == [
        "translation.final",
        "tts.error",
        "translation.final",
    ]
    assert published[-1]["utterance_id"] == "utt_000002"
    assert published[1]["scope"] == "session"
    assert published[1]["code"] == "internal_error"
    assert "secret" not in published[1]["message"]


def test_safe_error_publication_failure_is_swallowed_without_logging_raw_exception_text(caplog):
    async def exercise():
        published: list[dict[str, object]] = []
        tts = RecordingTtsSession(submit_error=RuntimeError("secret submit detail"))

        async def publish_event(event):
            if event["type"] == "tts.error":
                raise RuntimeError("secret error publication detail")
            published.append(event)

        bridge = make_bridge(publish_event=publish_event, tts_session=tts)
        await bridge.publish(translation_final())
        return published, tts

    published, tts = asyncio.run(exercise())

    assert published == [translation_final()]
    assert tts.abort_calls == 1
    assert "secret submit detail" not in caplog.text
    assert "secret error publication detail" not in caplog.text


def test_submit_cancellation_propagates_without_fabricating_session_error():
    async def exercise():
        published: list[dict[str, object]] = []
        tts = RecordingTtsSession(submit_error=asyncio.CancelledError())

        async def publish_event(event):
            published.append(event)

        bridge = make_bridge(publish_event=publish_event, tts_session=tts)
        with pytest.raises(asyncio.CancelledError):
            await bridge.publish(translation_final())
        return published, tts

    published, tts = asyncio.run(exercise())

    assert published == [translation_final()]
    assert tts.abort_calls == 0
