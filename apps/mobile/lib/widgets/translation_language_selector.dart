import 'package:flutter/material.dart';

import '../translation/translation_domain.dart';

class TranslationLanguageSelector extends StatelessWidget {
  const TranslationLanguageSelector({
    super.key,
    required this.selectedTarget,
    required this.enabled,
    required this.onChanged,
  });

  final TranslationTargetLanguage selectedTarget;
  final bool enabled;
  final ValueChanged<TranslationTargetLanguage> onChanged;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Expanded(
              child: _LanguageField(label: 'Source', value: 'Vietnamese'),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(10, 26, 10, 0),
              child: Icon(Icons.arrow_forward, size: 18),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Target',
                    style: Theme.of(context).textTheme.labelMedium,
                  ),
                  const SizedBox(height: 4),
                  DropdownButton<TranslationTargetLanguage>(
                    key: const Key('translation_target_selector'),
                    value: selectedTarget,
                    isExpanded: true,
                    onChanged: enabled
                        ? (value) {
                            if (value != null) {
                              onChanged(value);
                            }
                          }
                        : null,
                    items: TranslationTargetLanguage.values
                        .map(
                          (language) => DropdownMenuItem(
                            value: language,
                            child: Text('${language.label} · ${language.code}'),
                          ),
                        )
                        .toList(growable: false),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LanguageField extends StatelessWidget {
  const _LanguageField({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 12),
        Text(value, style: Theme.of(context).textTheme.bodyLarge),
      ],
    );
  }
}
