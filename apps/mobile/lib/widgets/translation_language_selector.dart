import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
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
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 150),
      opacity: enabled ? 1 : 0.68,
      child: Container(
        key: const Key('translation_selector_card'),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppColors.card,
          borderRadius: BorderRadius.circular(AppRadii.card),
          border: Border.all(color: AppColors.border),
          boxShadow: const [
            BoxShadow(
              color: Color(0x083444CD),
              blurRadius: 16,
              offset: Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            const Expanded(
              child: _LanguageField(label: 'Source', value: 'Vietnamese'),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: Icon(
                Icons.arrow_forward_rounded,
                size: 20,
                color: AppColors.secondaryText,
              ),
            ),
            Expanded(
              child: Container(
                key: const Key('translation_target_field'),
                padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                decoration: BoxDecoration(
                  color: AppColors.lavenderSoft,
                  borderRadius: BorderRadius.circular(AppRadii.control),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Target',
                      style: Theme.of(context).textTheme.labelMedium?.copyWith(
                        color: AppColors.secondaryText,
                      ),
                    ),
                    DropdownButtonHideUnderline(
                      child: DropdownButton<TranslationTargetLanguage>(
                        key: const Key('translation_target_selector'),
                        value: selectedTarget,
                        isExpanded: true,
                        isDense: true,
                        borderRadius: BorderRadius.circular(AppRadii.control),
                        icon: const Icon(Icons.expand_more_rounded),
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
                                child: Text(
                                  '${language.label} \u00b7 ${language.code}',
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            )
                            .toList(growable: false),
                      ),
                    ),
                  ],
                ),
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
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: AppColors.secondaryText),
          ),
          const SizedBox(height: 10),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
          ),
        ],
      ),
    );
  }
}
