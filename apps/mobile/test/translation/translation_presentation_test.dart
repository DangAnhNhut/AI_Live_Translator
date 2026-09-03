import 'package:ai_live_translator_mobile/translation/translation_domain.dart';
import 'package:ai_live_translator_mobile/translation/translation_presentation.dart';
import 'package:flutter_test/flutter_test.dart';

TranslationUtterance utterance({
  String streamId = 'stream_A',
  List<String> sourceSegmentIds = const ['seg_1', 'seg_2'],
}) => TranslationUtterance(
  identity: TranslationUtteranceIdentity(streamId, 'utt_000001'),
  sourceSegmentIds: sourceSegmentIds,
  sourceText: 'Canonical backend source.',
  sourceLanguage: 'vi',
  targetLanguage: TranslationTargetLanguage.english,
  status: TranslationStatus.pending,
);

void main() {
  test('unclaimed finals and interim remain in Live Speech', () {
    const segments = [
      LiveTranscriptSegment(
        streamId: 'stream_A',
        segmentId: 'seg_1',
        text: 'Final one',
        isFinal: true,
      ),
      LiveTranscriptSegment(
        streamId: 'stream_A',
        segmentId: 'seg_live',
        text: 'Interim words',
        isFinal: false,
      ),
    ];

    final presentation = buildTranslationPresentation(segments, const []);

    expect(presentation.liveSpeechSegments, segments);
  });

  test('pending claims multiple source IDs without text matching', () {
    const segments = [
      LiveTranscriptSegment(
        streamId: 'stream_A',
        segmentId: 'seg_1',
        text: 'This deliberately does not match',
        isFinal: true,
      ),
      LiveTranscriptSegment(
        streamId: 'stream_A',
        segmentId: 'seg_2',
        text: 'the canonical grouping.',
        isFinal: true,
      ),
      LiveTranscriptSegment(
        streamId: 'stream_A',
        segmentId: 'seg_live',
        text: 'Still speaking',
        isFinal: false,
      ),
    ];

    final presentation = buildTranslationPresentation(segments, [utterance()]);

    expect(
      presentation.utterances.single.sourceText,
      'Canonical backend source.',
    );
    expect(
      presentation.liveSpeechSegments.map((segment) => segment.segmentId),
      ['seg_live'],
    );
  });

  test('same segment ID on another stream is not claimed', () {
    const segments = [
      LiveTranscriptSegment(
        streamId: 'stream_A',
        segmentId: 'seg_1',
        text: 'Claimed',
        isFinal: true,
      ),
      LiveTranscriptSegment(
        streamId: 'stream_B',
        segmentId: 'seg_1',
        text: 'Different stream',
        isFinal: true,
      ),
    ];

    final presentation = buildTranslationPresentation(segments, [
      utterance(sourceSegmentIds: const ['seg_1']),
    ]);

    expect(presentation.liveSpeechSegments, hasLength(1));
    expect(presentation.liveSpeechSegments.single.streamId, 'stream_B');
  });

  test('view text follows pending, final, and failed states', () {
    final pending = buildBilingualTranscriptBlockView(utterance());
    final finalView = buildBilingualTranscriptBlockView(
      utterance().copyWith(
        status: TranslationStatus.finalResult,
        translatedText: 'Translated.',
      ),
    );
    final failed = buildBilingualTranscriptBlockView(
      utterance().copyWith(
        status: TranslationStatus.failed,
        errorCode: 'provider_error',
        errorMessage: 'Safe message.',
      ),
    );

    expect(pending.translationText, 'Translating...');
    expect(finalView.translationText, 'Translated.');
    expect(failed.translationText, 'Translation unavailable');
    expect(failed.sourceText, 'Canonical backend source.');
  });
}
