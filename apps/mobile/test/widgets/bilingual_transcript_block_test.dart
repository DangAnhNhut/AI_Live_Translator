import 'package:ai_live_translator_mobile/translation/translation_domain.dart';
import 'package:ai_live_translator_mobile/widgets/bilingual_transcript_block.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

TranslationUtterance utterance(TranslationStatus status) =>
    TranslationUtterance(
      identity: const TranslationUtteranceIdentity('stream_A', 'utt_000001'),
      sourceSegmentIds: const ['seg_1'],
      sourceText: 'Chung ta bat dau.',
      sourceLanguage: 'vi',
      targetLanguage: TranslationTargetLanguage.english,
      status: status,
      translatedText: status == TranslationStatus.finalResult
          ? 'We will begin.'
          : null,
      errorCode: status == TranslationStatus.failed ? 'provider_error' : null,
      errorMessage: status == TranslationStatus.failed ? 'Unavailable.' : null,
    );

void main() {
  Future<void> pump(WidgetTester tester, TranslationStatus status) {
    return tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BilingualTranscriptBlock(utterance: utterance(status)),
        ),
      ),
    );
  }

  testWidgets('pending shows source and Translating', (tester) async {
    await pump(tester, TranslationStatus.pending);

    expect(find.text('ORIGINAL · VI'), findsOneWidget);
    expect(find.text('Chung ta bat dau.'), findsOneWidget);
    expect(find.text('TRANSLATION · EN'), findsOneWidget);
    expect(find.text('Translating...'), findsOneWidget);
  });

  testWidgets('final shows translated text in the same component', (
    tester,
  ) async {
    await pump(tester, TranslationStatus.pending);
    await pump(tester, TranslationStatus.finalResult);

    expect(find.byType(BilingualTranscriptBlock), findsOneWidget);
    expect(find.text('We will begin.'), findsOneWidget);
    expect(find.text('Translating...'), findsNothing);
  });

  testWidgets('failed state remains local and keeps source visible', (
    tester,
  ) async {
    await pump(tester, TranslationStatus.failed);

    expect(find.text('Chung ta bat dau.'), findsOneWidget);
    expect(find.text('Translation unavailable'), findsOneWidget);
    expect(
      find.text('Original transcript is still available.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('translation_failed_surface')), findsOneWidget);
  });
}
