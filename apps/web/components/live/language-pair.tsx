import { getLanguageLabel } from "@/lib/realtime/translation-presentation";
import type { TranslationConfiguration } from "@/lib/realtime/translation";

type LanguagePairProps = {
  configuration: TranslationConfiguration | null;
};

export function LanguagePair({ configuration }: LanguagePairProps) {
  return (
    <div role="status" aria-live="polite" className="min-w-0">
      <p className="text-xs font-semibold uppercase tracking-[0.05em] text-text-secondary">
        Language pair
      </p>
      {configuration === null ? (
        <p className="mt-1 text-sm text-text-secondary">
          Waiting for Translation configuration…
        </p>
      ) : (
        <p className="mt-1 text-sm font-semibold text-text-primary">
          {getLanguageLabel(configuration.sourceLanguage)}{" "}
          <span aria-hidden="true">→</span>{" "}
          {getLanguageLabel(configuration.targetLanguage)}
        </p>
      )}
    </div>
  );
}
