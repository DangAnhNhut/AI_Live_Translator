"use client";

import { useEffect, useMemo, useRef } from "react";

import type { TranscriptSegment } from "@/lib/realtime/transcript";
import { groupTranscriptSegments } from "@/lib/realtime/transcript-blocks";
import {
  buildTranslationPresentation,
  getTranslationSessionWarning,
  shouldUseBilingualPresentation,
} from "@/lib/realtime/translation-presentation";
import {
  getActiveTranslationConfiguration,
  translationUtteranceKey,
  type TranslationState,
} from "@/lib/realtime/translation";

import { BilingualTranscriptBlock } from "./bilingual-transcript-block";
import { TranscriptBlock } from "./transcript-block";
import { TranscriptPanel } from "./transcript-panel";

type TranslationTranscriptPanelProps = {
  segments: readonly TranscriptSegment[];
  translationState: TranslationState;
  translationExpected: boolean;
  emptyTitle?: string;
  emptyDescription?: string;
};

export function TranslationTranscriptPanel({
  segments,
  translationState,
  translationExpected,
  emptyTitle = "Waiting for speech…",
  emptyDescription = "Recognized speech and translations will appear here.",
}: TranslationTranscriptPanelProps) {
  const endRef = useRef<HTMLDivElement>(null);
  const bilingual = shouldUseBilingualPresentation(
    translationExpected,
    translationState,
  );
  const presentation = useMemo(
    () =>
      buildTranslationPresentation(segments, translationState.utterances),
    [segments, translationState.utterances],
  );
  const liveBlocks = useMemo(
    () => groupTranscriptSegments(presentation.liveSegments),
    [presentation.liveSegments],
  );
  const activeConfiguration =
    getActiveTranslationConfiguration(translationState);
  const warning = getTranslationSessionWarning(
    translationState.sessionErrors,
    activeConfiguration?.streamId ?? null,
  );
  const latestTranslation = translationState.utterances.at(-1);
  const latestLiveText = liveBlocks.at(-1)?.text;

  useEffect(() => {
    if (!bilingual || (presentation.utterances.length === 0 && liveBlocks.length === 0)) {
      return;
    }
    const timer = window.setTimeout(() => {
      endRef.current?.scrollIntoView({ behavior: "smooth", block: "end" });
    }, 120);
    return () => window.clearTimeout(timer);
  }, [
    bilingual,
    latestLiveText,
    latestTranslation?.status,
    latestTranslation?.translatedText,
    liveBlocks.length,
    presentation.utterances.length,
  ]);

  if (!bilingual) {
    return (
      <TranscriptPanel
        segments={segments}
        emptyTitle={emptyTitle}
        emptyDescription={emptyDescription}
      />
    );
  }

  const empty = presentation.utterances.length === 0 && liveBlocks.length === 0;

  return (
    <div className="flex min-h-[420px] flex-1 flex-col overflow-hidden bg-[#fbfbff] sm:min-h-[500px] lg:max-h-[620px]">
      <div className="border-b border-border-default/70 bg-white/75 px-4 py-3 backdrop-blur-sm sm:px-6">
        <p className="text-xs font-semibold uppercase tracking-[0.05em] text-text-secondary">
          Live transcript
        </p>
        <p className="mt-0.5 text-sm font-semibold text-text-primary">
          Vietnamese speech with realtime Translation
        </p>
      </div>

      <div
        className="flex-1 overflow-y-auto px-4 py-6 sm:px-6 sm:py-8"
        aria-live="polite"
        aria-relevant="additions text"
      >
        {warning ? (
          <p
            className="mb-5 rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 text-sm leading-6 text-amber-900"
            role="status"
          >
            {warning}
          </p>
        ) : null}

        {empty ? (
          <div className="flex min-h-[330px] flex-col items-center justify-center text-center sm:min-h-[390px]">
            <div
              className="flex size-16 items-center justify-center rounded-2xl border border-brand-primary/15 bg-brand-primary/[0.06] text-brand-primary"
              aria-hidden="true"
            >
              <svg
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="1.8"
                strokeLinecap="round"
                strokeLinejoin="round"
                className="size-8"
              >
                <path d="M4 12v2a4 4 0 0 0 4 4h1" />
                <path d="M15 10v4" />
                <path d="M12 7v10" />
                <path d="M9 10v4" />
                <path d="M18 8v8" />
              </svg>
            </div>
            <h2 className="mt-5 font-display text-xl font-semibold text-text-primary">
              {emptyTitle}
            </h2>
            <p className="mt-2 max-w-sm text-sm leading-6 text-text-secondary">
              {emptyDescription}
            </p>
          </div>
        ) : (
          <div className="space-y-6">
            {presentation.utterances.length > 0 ? (
              <ol className="space-y-5" aria-label="Translated utterances">
                {presentation.utterances.map((utterance) => (
                  <BilingualTranscriptBlock
                    key={translationUtteranceKey(
                      utterance.streamId,
                      utterance.utteranceId,
                    )}
                    utterance={utterance}
                  />
                ))}
              </ol>
            ) : null}

            {liveBlocks.length > 0 ? (
              <section
                className="rounded-2xl border border-dashed border-brand-primary/25 bg-brand-primary/[0.025] p-4 sm:p-5"
                aria-label="Live Speech"
              >
                <div className="mb-4">
                  <p className="text-xs font-semibold uppercase tracking-[0.05em] text-brand-primary-strong">
                    Live Speech
                  </p>
                  <p className="mt-1 text-xs leading-5 text-text-secondary">
                    Recognized speech waiting for its Translation boundary.
                  </p>
                </div>
                <ol className="space-y-4">
                  {liveBlocks.map((block) => (
                    <TranscriptBlock key={block.id} block={block} />
                  ))}
                </ol>
              </section>
            ) : null}
          </div>
        )}
        <div ref={endRef} aria-hidden="true" />
      </div>
    </div>
  );
}
