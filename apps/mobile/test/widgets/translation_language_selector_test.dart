import 'package:ai_live_translator_mobile/translation/translation_domain.dart';
import 'package:ai_live_translator_mobile/widgets/translation_language_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows read-only Vietnamese source and exactly eight targets', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TranslationLanguageSelector(
            selectedTarget: TranslationTargetLanguage.english,
            enabled: true,
            onChanged: (_) {},
          ),
        ),
      ),
    );

    expect(find.text('Source'), findsOneWidget);
    expect(find.text('Vietnamese'), findsOneWidget);
    final dropdown = tester.widget<DropdownButton<TranslationTargetLanguage>>(
      find.byKey(const Key('translation_target_selector')),
    );
    expect(dropdown.items, hasLength(8));
    expect(
      dropdown.items!.map((item) => item.value),
      TranslationTargetLanguage.values,
    );
    expect(dropdown.value, TranslationTargetLanguage.english);
  });

  testWidgets('is disabled while the session is active', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: TranslationLanguageSelector(
            selectedTarget: TranslationTargetLanguage.english,
            enabled: false,
            onChanged: (_) {},
          ),
        ),
      ),
    );

    final dropdown = tester.widget<DropdownButton<TranslationTargetLanguage>>(
      find.byKey(const Key('translation_target_selector')),
    );
    expect(dropdown.onChanged, isNull);
    expect(find.textContaining('🇺🇸'), findsNothing);
    expect(find.textContaining('🇻🇳'), findsNothing);
  });
}
