import {
  HOST_SOURCE_LANGUAGE,
  HOST_TARGET_LANGUAGE_OPTIONS,
  type HostTranslationSelection,
} from "@/lib/host/host-translation";
import { getLanguageLabel } from "@/lib/realtime/translation-presentation";
import type {
  TargetLanguage,
  TranslationConfiguration,
} from "@/lib/realtime/translation";

type TranslationLanguagePanelProps = {
  selection: HostTranslationSelection;
  activeConfiguration: TranslationConfiguration | null;
  onTargetChange: (target: TargetLanguage) => void;
};

export function TranslationLanguagePanel({
  selection,
  activeConfiguration,
  onTargetChange,
}: TranslationLanguagePanelProps) {
  return (
    <section className="rounded-2xl border border-border-default bg-white p-5 shadow-[0_10px_24px_-20px_rgba(17,24,39,0.18)]">
      <p className="text-xs font-semibold uppercase tracking-[0.05em] text-brand-primary">
        Realtime Translation
      </p>
      <h2 className="mt-2 font-display text-lg font-semibold text-text-primary">
        Language pair
      </h2>

      <div className="mt-4 grid gap-4">
        <div>
          <label
            htmlFor="host-source-language"
            className="text-xs font-semibold uppercase tracking-[0.05em] text-text-secondary"
          >
            Source
          </label>
          <input
            id="host-source-language"
            value={HOST_SOURCE_LANGUAGE.label}
            readOnly
            aria-readonly="true"
            className="mt-1.5 min-h-11 w-full rounded-lg border border-border-default bg-slate-50 px-3 text-sm font-medium text-text-primary"
          />
        </div>

        <div>
          <label
            htmlFor="host-target-language"
            className="text-xs font-semibold uppercase tracking-[0.05em] text-text-secondary"
          >
            Target
          </label>
          <select
            id="host-target-language"
            value={selection.targetLanguage}
            disabled={selection.locked}
            onChange={(event) =>
              onTargetChange(event.target.value as TargetLanguage)
            }
            className="mt-1.5 min-h-11 w-full rounded-lg border border-border-default bg-white px-3 text-sm font-medium text-text-primary disabled:cursor-not-allowed disabled:bg-slate-50 disabled:text-text-secondary"
          >
            {HOST_TARGET_LANGUAGE_OPTIONS.map((option) => (
              <option key={option.code} value={option.code}>
                {option.label} ({option.code})
              </option>
            ))}
          </select>
        </div>
      </div>

      <p className="mt-4 border-t border-border-default pt-4 text-xs leading-5 text-text-secondary">
        {activeConfiguration === null
          ? selection.locked
            ? "Waiting for the Backend to confirm this language pair."
            : "The target is locked after the live stream starts."
          : `Backend confirmed: ${getLanguageLabel(activeConfiguration.sourceLanguage)} → ${getLanguageLabel(activeConfiguration.targetLanguage)}`}
      </p>
    </section>
  );
}
