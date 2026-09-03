import 'package:ai_live_translator_mobile/translation/translation_domain.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> configured({String streamId = 'stream_A'}) => {
  'type': 'translation.configured',
  'stream_id': streamId,
  'source_language': 'vi',
  'target_language': 'en',
};

Map<String, Object?> pending({
  String streamId = 'stream_A',
  String utteranceId = 'utt_000001',
}) => {
  'type': 'translation.pending',
  'stream_id': streamId,
  'utterance_id': utteranceId,
  'source_segment_ids': ['seg_1', 'seg_2'],
  'source_text': 'Xin chao the gioi.',
  'source_language': 'vi',
  'target_language': 'en',
};

Map<String, Object?> finalEvent({
  String streamId = 'stream_A',
  String utteranceId = 'utt_000001',
}) => {
  ...pending(streamId: streamId, utteranceId: utteranceId),
  'type': 'translation.final',
  'translated_text': 'Hello world.',
};

Map<String, Object?> utteranceError({
  String streamId = 'stream_A',
  String utteranceId = 'utt_000001',
  String code = 'provider_error',
}) => {
  ...pending(streamId: streamId, utteranceId: utteranceId),
  'type': 'translation.error',
  'scope': 'utterance',
  'code': code,
  'message': 'Translation unavailable.',
};

void main() {
  group('strict Translation parser', () {
    test('parses configured, pending, final, and both error scopes', () {
      final configuredEvent = parseTranslationEvent(configured());
      final pendingEvent = parseTranslationEvent(pending());
      final translated = parseTranslationEvent(finalEvent());
      final failed = parseTranslationEvent(utteranceError());
      final sessionError = parseTranslationEvent({
        'type': 'translation.error',
        'scope': 'session',
        'stream_id': 'stream_A',
        'source_language': 'vi',
        'target_language': 'en',
        'code': 'provider_unavailable',
        'message': 'Translation is unavailable.',
      });

      expect(configuredEvent, isA<TranslationConfiguredEvent>());
      expect(pendingEvent, isA<TranslationPendingEvent>());
      expect(translated, isA<TranslationFinalEvent>());
      expect(failed, isA<TranslationUtteranceErrorEvent>());
      expect(sessionError, isA<TranslationSessionErrorEvent>());
      expect((pendingEvent as TranslationPendingEvent).sourceSegmentIds, [
        'seg_1',
        'seg_2',
      ]);
    });

    test('rejects malformed Translation events and ignores unknown types', () {
      expect(
        parseTranslationEvent({
          ...pending(),
          'source_segment_ids': [''],
        }),
        isNull,
      );
      expect(
        parseTranslationEvent({...configured(), 'target_language': 'xx'}),
        isNull,
      );
      expect(parseTranslationEvent({'type': 'translation.future'}), isNull);
    });
  });

  group('Translation reducer', () {
    test('pending creates one utterance and final updates it in place', () {
      var state = const TranslationState();
      state = state.apply(parseTranslationEvent(pending())!);
      final pendingIdentity = state.utterances.single.identity;
      state = state.apply(parseTranslationEvent(finalEvent())!);

      expect(state.utterances, hasLength(1));
      expect(state.utterances.single.identity, pendingIdentity);
      expect(state.utterances.single.status, TranslationStatus.finalResult);
      expect(state.utterances.single.translatedText, 'Hello world.');
      expect(state.utterances.single.sourceSegmentIds, ['seg_1', 'seg_2']);
    });

    test('utterance failure updates pending in place', () {
      var state = const TranslationState()
          .apply(parseTranslationEvent(pending())!)
          .apply(parseTranslationEvent(utteranceError())!);

      expect(state.utterances, hasLength(1));
      expect(state.utterances.single.status, TranslationStatus.failed);
      expect(state.utterances.single.errorCode, 'provider_error');
    });

    test('duplicates are idempotent and completed states are monotonic', () {
      final pendingEvent = parseTranslationEvent(pending())!;
      final translated = parseTranslationEvent(finalEvent())!;
      final staleError = parseTranslationEvent(utteranceError())!;
      var state = const TranslationState()
          .apply(pendingEvent)
          .apply(pendingEvent)
          .apply(translated);
      final completed = state;

      state = state.apply(translated).apply(pendingEvent).apply(staleError);

      expect(state, same(completed));
      expect(state.utterances, hasLength(1));
      expect(state.utterances.single.status, TranslationStatus.finalResult);
    });

    test('repeated error is idempotent', () {
      final error = parseTranslationEvent(utteranceError())!;
      final once = const TranslationState().apply(error);
      final twice = once.apply(error);

      expect(twice, same(once));
      expect(twice.utterances, hasLength(1));
    });

    test('same utterance ID on different streams remains distinct', () {
      final state = const TranslationState()
          .apply(parseTranslationEvent(pending(streamId: 'stream_A'))!)
          .apply(parseTranslationEvent(pending(streamId: 'stream_B'))!);

      expect(state.utterances, hasLength(2));
      expect(state.utterances.map((item) => item.identity.streamId), {
        'stream_A',
        'stream_B',
      });
    });

    test('configured state and session errors are idempotent', () {
      final event = parseTranslationEvent(configured())!;
      final once = const TranslationState().apply(event);
      expect(once.apply(event), same(once));

      final error = parseTranslationEvent({
        'type': 'translation.error',
        'scope': 'session',
        'stream_id': 'stream_A',
        'source_language': 'vi',
        'target_language': 'en',
        'code': 'provider_unavailable',
        'message': 'Unavailable.',
      })!;
      final failed = once.apply(error);
      expect(failed.apply(error), same(failed));
      expect(failed.sessionErrors, hasLength(1));
    });
  });

  test('approved target choices are exact and default to English', () {
    expect(TranslationTargetLanguage.values.map((value) => value.code), [
      'en',
      'ja',
      'ko',
      'zh-CN',
      'th',
      'fr',
      'de',
      'es',
    ]);
    expect(defaultTranslationTarget, TranslationTargetLanguage.english);
  });
}
