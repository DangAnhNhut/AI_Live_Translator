import 'translation_domain.dart';

class TranscriptSegmentIdentity {
  const TranscriptSegmentIdentity(this.streamId, this.segmentId);

  final String? streamId;
  final String segmentId;

  @override
  bool operator ==(Object other) =>
      other is TranscriptSegmentIdentity &&
      other.streamId == streamId &&
      other.segmentId == segmentId;

  @override
  int get hashCode => Object.hash(streamId, segmentId);
}

class LiveTranscriptSegment {
  const LiveTranscriptSegment({
    required this.streamId,
    required this.segmentId,
    required this.text,
    required this.isFinal,
  });

  final String? streamId;
  final String segmentId;
  final String text;
  final bool isFinal;

  TranscriptSegmentIdentity get identity =>
      TranscriptSegmentIdentity(streamId, segmentId);
}

class TranslationPresentation {
  const TranslationPresentation({
    required this.utterances,
    required this.liveSpeechSegments,
  });

  final List<TranslationUtterance> utterances;
  final List<LiveTranscriptSegment> liveSpeechSegments;
}

TranslationPresentation buildTranslationPresentation(
  List<LiveTranscriptSegment> segments,
  List<TranslationUtterance> utterances,
) {
  final claimed = <TranscriptSegmentIdentity>{};
  for (final utterance in utterances) {
    for (final segmentId in utterance.sourceSegmentIds) {
      claimed.add(
        TranscriptSegmentIdentity(utterance.identity.streamId, segmentId),
      );
    }
  }
  return TranslationPresentation(
    utterances: List.unmodifiable(utterances),
    liveSpeechSegments: List.unmodifiable(
      segments.where(
        (segment) => !segment.isFinal || !claimed.contains(segment.identity),
      ),
    ),
  );
}

class BilingualTranscriptBlockView {
  const BilingualTranscriptBlockView({
    required this.sourceLabel,
    required this.sourceText,
    required this.translationLabel,
    required this.translationText,
    required this.status,
    required this.secondaryHint,
  });

  final String sourceLabel;
  final String sourceText;
  final String translationLabel;
  final String translationText;
  final TranslationStatus status;
  final String? secondaryHint;
}

BilingualTranscriptBlockView buildBilingualTranscriptBlockView(
  TranslationUtterance utterance,
) {
  final translationText = switch (utterance.status) {
    TranslationStatus.pending => 'Translating...',
    TranslationStatus.finalResult => utterance.translatedText ?? '',
    TranslationStatus.failed => 'Translation unavailable',
  };
  return BilingualTranscriptBlockView(
    sourceLabel: 'ORIGINAL · ${utterance.sourceLanguage.toUpperCase()}',
    sourceText: utterance.sourceText,
    translationLabel:
        'TRANSLATION · ${utterance.targetLanguage.code.toUpperCase()}',
    translationText: translationText,
    status: utterance.status,
    secondaryHint: utterance.status == TranslationStatus.failed
        ? 'Original transcript is still available.'
        : null,
  );
}

const translationUnavailableWarning =
    'Translation is unavailable. Original transcript will continue.';
