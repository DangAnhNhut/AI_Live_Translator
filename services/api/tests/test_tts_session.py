import asyncio
from collections.abc import Callable

import pytest

from app.ai.tts import (
    InvalidSynthesizedAudio,
    SynthesizedAudio,
    TtsProviderError,
    TtsProviderUnavailable,
)
from app.realtime.tts_session import TtsSession
from tests.fakes.tts import FakeSpeechSynthesizer


async def wait_until(predicate: Callable[[], bool], turns: int = 1000):
    for _ in range(turns):
        if predicate():
            return
        await asyncio.sleep(0)
    raise AssertionError("condition was not reached")


def make_session(*, synthesizer, outputs, queue_max_size=8, timeout=1.0):
    async def publish_event(event):
        outputs.append(("json", event))

    async def publish_audio(event, audio_bytes):
        outputs.append(("audio", event, audio_bytes))

    return TtsSession(
        synthesizer=synthesizer,
        stream_id="stream_123",
        target_language="en",
        publish_event=publish_event,
        publish_audio=publish_audio,
        voice="voice-a",
        queue_max_size=queue_max_size,
        request_timeout_seconds=timeout,
    )


async def submit(session, utterance_id, text):
    await session.submit(
        stream_id="stream_123",
        utterance_id=utterance_id,
        source_segment_ids=(f"seg_{utterance_id[-1]}",),
        translated_text=text,
        target_language="en",
    )


def test_unique_utterance_emits_pending_then_metadata_and_raw_bytes():
    async def exercise():
        outputs = []
        result = SynthesizedAudio(b"speech", "audio/wav", 16000)
        fake = FakeSpeechSynthesizer(outcomes=(result,))
        session = make_session(synthesizer=fake, outputs=outputs)
        await session.start()
        await session.start()
        await submit(session, "utt_000001", "Hello.")
        assert await session.flush_and_drain(timeout_seconds=1.0)
        await session.close()
        return outputs, fake

    outputs, fake = asyncio.run(exercise())

    assert outputs[0][0] == "json"
    assert outputs[0][1] == {
        "type": "tts.pending",
        "stream_id": "stream_123",
        "utterance_id": "utt_000001",
        "target_language": "en",
    }
    assert outputs[1][0] == "audio"
    assert outputs[1][1] == {
        "type": "tts.audio",
        "stream_id": "stream_123",
        "utterance_id": "utt_000001",
        "audio_id": "audio_000001",
        "target_language": "en",
        "mime_type": "audio/wav",
        "byte_length": 6,
        "sample_rate_hz": 16000,
    }
    assert "audio_bytes" not in outputs[1][1]
    assert outputs[1][2] == b"speech"
    assert len(fake.calls) == 1
    assert fake.calls[0].voice == "voice-a"


def test_two_utterances_synthesize_sequentially_in_submission_order():
    async def exercise():
        outputs = []
        first_gate = asyncio.Event()
        fake = FakeSpeechSynthesizer(
            outcomes=(
                SynthesizedAudio(b"one", "audio/wav", 16000),
                SynthesizedAudio(b"two", "audio/wav", 16000),
            ),
            gates=(first_gate, None),
        )
        session = make_session(synthesizer=fake, outputs=outputs)
        await session.start()
        await submit(session, "utt_000001", "One")
        await submit(session, "utt_000002", "Two")
        await wait_until(lambda: len(fake.calls) == 1)
        assert fake.maximum_active_calls == 1
        assert [item[1]["type"] for item in outputs] == ["tts.pending"]
        first_gate.set()
        assert await session.flush_and_drain(timeout_seconds=1.0)
        await session.close()
        return outputs, fake

    outputs, fake = asyncio.run(exercise())

    assert [call.text for call in fake.calls] == ["One", "Two"]
    assert fake.maximum_active_calls == 1
    assert [item[1]["utterance_id"] for item in outputs] == [
        "utt_000001",
        "utt_000001",
        "utt_000002",
        "utt_000002",
    ]
    assert [
        item[1]["audio_id"] for item in outputs if item[0] == "audio"
    ] == ["audio_000001", "audio_000002"]


def test_duplicate_identity_is_permanently_ignored():
    async def exercise():
        outputs = []
        fake = FakeSpeechSynthesizer()
        session = make_session(synthesizer=fake, outputs=outputs)
        await session.start()
        await submit(session, "utt_000001", "First")
        await submit(session, "utt_000001", "Changed duplicate")
        assert await session.flush_and_drain(timeout_seconds=1.0)
        await session.close()
        return outputs, fake

    outputs, fake = asyncio.run(exercise())

    assert len(fake.calls) == 1
    assert fake.calls[0].text == "First"
    assert [item[1]["type"] for item in outputs] == [
        "tts.pending",
        "tts.audio",
    ]


def test_default_queue_size_is_eight():
    async def exercise():
        outputs = []
        gate = asyncio.Event()
        fake = FakeSpeechSynthesizer(gates=(gate,))
        session = make_session(synthesizer=fake, outputs=outputs)
        await session.start()
        await submit(session, "utt_000001", "One")
        await fake.call_started.wait()
        for number in range(2, 10):
            await submit(session, f"utt_{number:06d}", str(number))
        await submit(session, "utt_000010", "Dropped")
        await session.abort()
        await session.close()
        return outputs, fake

    outputs, fake = asyncio.run(exercise())

    overflow = [
        item[1]
        for item in outputs
        if item[0] == "json" and item[1].get("code") == "queue_overflow"
    ]
    assert len(overflow) == 1
    assert overflow[0]["utterance_id"] == "utt_000010"
    assert [call.text for call in fake.calls] == ["One"]


def test_queue_overflow_drops_identity_permanently_and_later_unique_continues():
    async def exercise():
        outputs = []
        first_gate = asyncio.Event()
        fake = FakeSpeechSynthesizer(
            outcomes=(
                SynthesizedAudio(b"one", "audio/wav", 16000),
                SynthesizedAudio(b"two", "audio/wav", 16000),
                SynthesizedAudio(b"four", "audio/wav", 16000),
            ),
            gates=(first_gate, None, None),
        )
        session = make_session(
            synthesizer=fake,
            outputs=outputs,
            queue_max_size=1,
        )
        await session.start()
        await submit(session, "utt_000001", "One")
        await wait_until(lambda: len(fake.calls) == 1)
        await submit(session, "utt_000002", "Two")
        await submit(session, "utt_000003", "Dropped")
        await submit(session, "utt_000003", "Duplicate dropped")

        overflow_events = [
            item[1]
            for item in outputs
            if item[0] == "json"
            and item[1].get("code") == "queue_overflow"
        ]
        assert len(overflow_events) == 1
        assert overflow_events[0]["utterance_id"] == "utt_000003"
        assert [call.text for call in fake.calls] == ["One"]

        first_gate.set()
        await wait_until(lambda: len(fake.calls) == 2)
        await wait_until(
            lambda: any(
                item[0] == "audio"
                and item[1]["utterance_id"] == "utt_000002"
                for item in outputs
            )
        )
        await submit(session, "utt_000004", "Four")
        assert await session.flush_and_drain(timeout_seconds=1.0)
        await session.close()
        return outputs, fake

    outputs, fake = asyncio.run(exercise())

    assert [call.text for call in fake.calls] == ["One", "Two", "Four"]
    assert all(call.text != "Dropped" for call in fake.calls)
    assert all(call.text != "Duplicate dropped" for call in fake.calls)
    assert any(
        item[0] == "audio"
        and item[1]["utterance_id"] == "utt_000004"
        for item in outputs
    )


@pytest.mark.parametrize(
    ("failure", "code"),
    (
        (TtsProviderUnavailable("secret unavailable detail"), "provider_unavailable"),
        (TtsProviderError("secret provider detail"), "provider_error"),
        (RuntimeError("secret internal detail"), "internal_error"),
    ),
)
def test_provider_failure_is_safe_and_worker_continues(failure, code):
    async def exercise():
        outputs = []
        fake = FakeSpeechSynthesizer(
            outcomes=(
                failure,
                SynthesizedAudio(b"two", "audio/wav", 16000),
            )
        )
        session = make_session(synthesizer=fake, outputs=outputs)
        await session.start()
        await submit(session, "utt_000001", "One")
        await submit(session, "utt_000002", "Two")
        assert await session.flush_and_drain(timeout_seconds=1.0)
        await session.close()
        return outputs, fake

    outputs, fake = asyncio.run(exercise())

    errors = [item[1] for item in outputs if item[1]["type"] == "tts.error"]
    assert len(errors) == 1
    assert errors[0]["utterance_id"] == "utt_000001"
    assert errors[0]["code"] == code
    assert "secret" not in errors[0]["message"]
    assert any(
        item[0] == "audio"
        and item[1]["utterance_id"] == "utt_000002"
        for item in outputs
    )
    assert len(fake.calls) == 2


def test_provider_timeout_cancels_request_and_worker_continues_without_retry():
    async def exercise():
        outputs = []
        gate = asyncio.Event()
        fake = FakeSpeechSynthesizer(gates=(gate, None))
        session = make_session(
            synthesizer=fake,
            outputs=outputs,
            timeout=0.01,
        )
        await session.start()
        await submit(session, "utt_000001", "One")
        await wait_until(
            lambda: any(
                item[0] == "json"
                and item[1].get("code") == "request_timeout"
                for item in outputs
            )
        )
        await submit(session, "utt_000001", "Duplicate one")
        await submit(session, "utt_000002", "Two")
        assert await session.flush_and_drain(timeout_seconds=1.0)
        await session.close()
        return outputs, fake

    outputs, fake = asyncio.run(exercise())

    assert fake.cancelled_calls == 1
    assert [call.text for call in fake.calls] == ["One", "Two"]
    assert any(
        item[0] == "audio"
        and item[1]["utterance_id"] == "utt_000002"
        for item in outputs
    )


def test_duplicate_after_provider_failure_does_not_retry():
    async def exercise():
        outputs = []
        fake = FakeSpeechSynthesizer(
            outcomes=(
                TtsProviderError("secret"),
                SynthesizedAudio(b"two", "audio/wav", 16000),
            )
        )
        session = make_session(synthesizer=fake, outputs=outputs)
        await session.start()
        await submit(session, "utt_000001", "One")
        await wait_until(
            lambda: any(
                item[0] == "json"
                and item[1].get("code") == "provider_error"
                for item in outputs
            )
        )
        await submit(session, "utt_000001", "Duplicate one")
        await submit(session, "utt_000002", "Two")
        assert await session.flush_and_drain(timeout_seconds=1.0)
        await session.close()
        return outputs, fake

    outputs, fake = asyncio.run(exercise())

    assert [call.text for call in fake.calls] == ["One", "Two"]
    assert not any(
        item[0] == "audio"
        and item[1]["utterance_id"] == "utt_000001"
        for item in outputs
    )
    assert any(
        item[0] == "audio"
        and item[1]["utterance_id"] == "utt_000002"
        for item in outputs
    )


class _InvalidThenValidSynthesizer:
    def __init__(self, *, raises_invalid_audio=False):
        self.raises_invalid_audio = raises_invalid_audio
        self.calls = []

    async def synthesize(self, *, text, language, voice=None):
        self.calls.append((text, language, voice))
        if len(self.calls) == 1:
            if self.raises_invalid_audio:
                raise InvalidSynthesizedAudio("secret invalid bytes")
            return object()
        return SynthesizedAudio(b"valid", "audio/wav", 16000)


@pytest.mark.parametrize("raises_invalid_audio", (False, True))
def test_invalid_provider_result_emits_invalid_audio_and_continues(
    raises_invalid_audio,
):
    async def exercise():
        outputs = []
        synthesizer = _InvalidThenValidSynthesizer(
            raises_invalid_audio=raises_invalid_audio
        )
        session = make_session(synthesizer=synthesizer, outputs=outputs)
        await session.start()
        await submit(session, "utt_000001", "One")
        await submit(session, "utt_000002", "Two")
        assert await session.flush_and_drain(timeout_seconds=1.0)
        await session.close()
        return outputs, synthesizer

    outputs, synthesizer = asyncio.run(exercise())

    errors = [item[1] for item in outputs if item[1]["type"] == "tts.error"]
    assert len(errors) == 1
    assert errors[0]["utterance_id"] == "utt_000001"
    assert errors[0]["code"] == "invalid_audio"
    assert "secret" not in errors[0]["message"]
    assert not any(
        item[0] == "audio"
        and item[1]["utterance_id"] == "utt_000001"
        for item in outputs
    )
    assert any(
        item[0] == "audio"
        and item[1]["utterance_id"] == "utt_000002"
        for item in outputs
    )
    assert len(synthesizer.calls) == 2


@pytest.mark.parametrize(
    "overrides",
    (
        {"stream_id": "stream_other"},
        {"target_language": "ja"},
        {"utterance_id": "   "},
        {"translated_text": "   "},
        {"source_segment_ids": ()},
        {"source_segment_ids": ("   ",)},
    ),
)
def test_submit_rejects_invalid_committed_translation_fields(overrides):
    async def exercise():
        outputs = []
        fake = FakeSpeechSynthesizer()
        session = make_session(synthesizer=fake, outputs=outputs)
        await session.start()
        arguments = {
            "stream_id": "stream_123",
            "utterance_id": "utt_000001",
            "source_segment_ids": ("seg_1",),
            "translated_text": "Hello.",
            "target_language": "en",
        }
        arguments.update(overrides)
        with pytest.raises(ValueError):
            await session.submit(**arguments)
        await session.close()
        return outputs, fake

    outputs, fake = asyncio.run(exercise())

    assert outputs == []
    assert fake.calls == []


def test_submit_requires_started_accepting_session():
    async def exercise():
        outputs = []
        fake = FakeSpeechSynthesizer()
        session = make_session(synthesizer=fake, outputs=outputs)
        with pytest.raises(RuntimeError):
            await submit(session, "utt_000001", "Before")
        await session.start()
        await submit(session, "utt_000002", "Accepted")
        assert await session.flush_and_drain(timeout_seconds=1.0)
        with pytest.raises(RuntimeError):
            await submit(session, "utt_000003", "After")
        await session.close()
        return outputs, fake

    outputs, fake = asyncio.run(exercise())

    assert len(fake.calls) == 1
    assert [item[1]["utterance_id"] for item in outputs] == [
        "utt_000002",
        "utt_000002",
    ]


@pytest.mark.parametrize(
    "kwargs",
    (
        {"queue_max_size": 0},
        {"timeout": 0},
        {"stream_id": "   "},
        {"voice": "   "},
    ),
)
def test_constructor_rejects_invalid_session_configuration(kwargs):
    outputs = []
    fake = FakeSpeechSynthesizer()
    arguments = {
        "synthesizer": fake,
        "stream_id": "stream_123",
        "target_language": "en",
        "publish_event": lambda event: None,
        "publish_audio": lambda event, audio: None,
        "voice": "voice-a",
        "queue_max_size": 8,
        "request_timeout_seconds": 1.0,
    }
    if "timeout" in kwargs:
        arguments["request_timeout_seconds"] = kwargs["timeout"]
    else:
        arguments.update(kwargs)

    with pytest.raises(ValueError):
        TtsSession(**arguments)


def test_flush_and_drain_completes_all_accepted_work_and_is_repeatable():
    async def exercise():
        outputs = []
        fake = FakeSpeechSynthesizer()
        session = make_session(synthesizer=fake, outputs=outputs)
        await session.start()
        await submit(session, "utt_000001", "One")
        await submit(session, "utt_000002", "Two")
        first = await session.flush_and_drain(timeout_seconds=1.0)
        second = await session.flush_and_drain(timeout_seconds=1.0)
        await session.close()
        return first, second, outputs

    first, second, outputs = asyncio.run(exercise())

    assert first is True
    assert second is True
    assert [item[1]["type"] for item in outputs] == [
        "tts.pending",
        "tts.audio",
        "tts.pending",
        "tts.audio",
    ]


def test_flush_and_drain_owns_one_named_drain_task():
    async def exercise():
        outputs = []
        gate = asyncio.Event()
        fake = FakeSpeechSynthesizer(gates=(gate,))
        session = make_session(synthesizer=fake, outputs=outputs)
        await session.start()
        await submit(session, "utt_000001", "One")
        await fake.call_started.wait()
        drain = asyncio.create_task(
            session.flush_and_drain(timeout_seconds=1.0)
        )
        await asyncio.sleep(0)
        has_named_drain = any(
            task is not asyncio.current_task()
            and task.get_name() == "tts-drain:stream_123"
            and not task.done()
            for task in asyncio.all_tasks()
        )
        gate.set()
        drained = await drain
        await session.close()
        return has_named_drain, drained

    has_named_drain, drained = asyncio.run(exercise())

    assert has_named_drain is True
    assert drained is True


def test_total_drain_deadline_bounds_multiple_slow_queued_requests():
    async def exercise():
        outputs = []
        gate = asyncio.Event()
        fake = FakeSpeechSynthesizer(gates=(gate, gate, gate))
        session = make_session(
            synthesizer=fake,
            outputs=outputs,
            timeout=1.0,
        )
        await session.start()
        await submit(session, "utt_000001", "One")
        await submit(session, "utt_000002", "Two")
        await submit(session, "utt_000003", "Three")
        await fake.call_started.wait()
        drained = await asyncio.wait_for(
            session.flush_and_drain(timeout_seconds=0.01),
            timeout=0.2,
        )
        await session.close()
        return drained, fake

    drained, fake = asyncio.run(exercise())

    assert drained is False
    assert fake.cancelled_calls == 1
    assert fake.active_calls == 0
    assert [call.text for call in fake.calls] == ["One"]


def test_drain_timeout_validation_and_lifecycle_states():
    async def exercise():
        outputs = []
        fake = FakeSpeechSynthesizer()
        session = make_session(synthesizer=fake, outputs=outputs)
        with pytest.raises(ValueError):
            await session.flush_and_drain(timeout_seconds=0)
        with pytest.raises(RuntimeError):
            await session.flush_and_drain(timeout_seconds=1.0)
        await session.start()
        await session.close()
        assert await session.flush_and_drain(timeout_seconds=1.0) is False
        with pytest.raises(RuntimeError):
            await session.start()

    asyncio.run(exercise())


def test_abort_and_close_are_idempotent_and_leave_no_owned_tasks():
    async def exercise():
        outputs = []
        gate = asyncio.Event()
        fake = FakeSpeechSynthesizer(gates=(gate,))
        session = make_session(synthesizer=fake, outputs=outputs)
        await session.start()
        await submit(session, "utt_000001", "One")
        await fake.call_started.wait()
        await session.abort()
        await session.abort()
        await session.close()
        await session.close()
        owned = [
            task
            for task in asyncio.all_tasks()
            if task is not asyncio.current_task()
            and task.get_name().startswith("tts-")
            and not task.done()
        ]
        return fake, owned

    fake, owned = asyncio.run(exercise())

    assert fake.cancelled_calls == 1
    assert fake.active_calls == 0
    assert owned == []


def test_abort_discards_queued_work_without_queue_join_hanging():
    async def exercise():
        outputs = []
        gate = asyncio.Event()
        fake = FakeSpeechSynthesizer(gates=(gate, None))
        session = make_session(synthesizer=fake, outputs=outputs)
        await session.start()
        await submit(session, "utt_000001", "One")
        await submit(session, "utt_000002", "Two")
        await fake.call_started.wait()
        await session.abort()
        await asyncio.wait_for(session.close(), timeout=0.1)
        return fake

    fake = asyncio.run(exercise())

    assert fake.cancelled_calls == 1
    assert [call.text for call in fake.calls] == ["One"]


@pytest.mark.parametrize("failure_point", ("pending", "audio"))
def test_publisher_failure_makes_drain_false_and_stops_later_work(
    failure_point,
):
    async def exercise():
        outputs = []
        fake = FakeSpeechSynthesizer()

        async def publish_event(event):
            if failure_point == "pending" and event["type"] == "tts.pending":
                raise RuntimeError("publisher secret")
            outputs.append(("json", event))

        async def publish_audio(event, audio_bytes):
            if failure_point == "audio":
                raise RuntimeError("publisher secret")
            outputs.append(("audio", event, audio_bytes))

        session = TtsSession(
            synthesizer=fake,
            stream_id="stream_123",
            target_language="en",
            publish_event=publish_event,
            publish_audio=publish_audio,
            request_timeout_seconds=1.0,
        )
        await session.start()
        await submit(session, "utt_000001", "One")
        await submit(session, "utt_000002", "Two")
        drained = await session.flush_and_drain(timeout_seconds=1.0)
        await session.close()
        owned = [
            task
            for task in asyncio.all_tasks()
            if task is not asyncio.current_task()
            and task.get_name().startswith("tts-")
            and not task.done()
        ]
        return drained, fake, owned

    drained, fake, owned = asyncio.run(exercise())

    assert drained is False
    assert len(fake.calls) == (0 if failure_point == "pending" else 1)
    assert all(call.text != "Two" for call in fake.calls)
    assert owned == []
