import {
  buildBilingualTranscriptBlockView,
} from "@/lib/realtime/translation-presentation";
import type { TranslationUtteranceState } from "@/lib/realtime/translation";

type BilingualTranscriptBlockProps = {
  utterance: TranslationUtteranceState;
};

export function BilingualTranscriptBlock({
  utterance,
}: BilingualTranscriptBlockProps) {
  const view = buildBilingualTranscriptBlockView(utterance);
  const pending = view.status === "pending";
  const failed = view.status === "failed";

  return (
    <li className="overflow-hidden rounded-2xl border border-border-default bg-white shadow-[0_8px_24px_-20px_rgba(17,24,39,0.24)]">
      <section className="px-4 py-4 sm:px-5">
        <p className="text-xs font-semibold uppercase tracking-[0.05em] text-text-secondary">
          {view.sourceLabel}
        </p>
        <p className="mt-2 break-words text-[16px] leading-6 text-text-primary sm:text-[18px] sm:leading-7">
          {view.sourceText}
        </p>
      </section>

      <section
        className={`border-t px-4 py-4 sm:px-5 ${
          failed
            ? "border-red-200 bg-red-50/80"
            : "border-brand-primary/10 bg-brand-primary/[0.035]"
        }`}
      >
        <p
          className={`text-xs font-semibold uppercase tracking-[0.05em] ${
            failed ? "text-[#93000a]" : "text-brand-primary-strong"
          }`}
        >
          {view.translationLabel}
        </p>
        <p
          className={`mt-2 break-words text-[16px] leading-6 sm:text-[18px] sm:leading-7 ${
            pending
              ? "text-text-secondary"
              : failed
                ? "font-medium text-[#93000a]"
                : "text-text-primary"
          }`}
          role={pending ? "status" : undefined}
        >
          {view.translationText}
        </p>
        {failed ? (
          <p className="mt-1.5 text-xs leading-5 text-[#93000a]/80">
            {view.secondaryHint}
          </p>
        ) : null}
      </section>
    </li>
  );
}
