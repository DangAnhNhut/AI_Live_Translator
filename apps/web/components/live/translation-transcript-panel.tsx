"use client";

import { useEffect, useMemo, useRef, useState } from "react";

import type { TranscriptSegment } from "@/lib/realtime/transcript";
import { groupTranscriptSegments } from "@/lib/realtime/transcript-blocks";
import {
  buildTranslationPresentation,
  getLanguageLabel,
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
  const [autoFollow, setAutoFollow] = useState(true);
  const [searchQuery, setSearchQuery] = useState("");
  const [fontScale, setFontScale] = useState<"normal" | "large">("normal");

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

  const targetLang =
    activeConfiguration?.targetLanguage ??
    presentation.utterances.at(-1)?.targetLanguage ??
    "en";
  const targetLabel = getLanguageLabel(targetLang);

  // Auto-follow scrolling
  const lastUtterance = presentation.utterances.at(-1);
  const lastTranslatedText = lastUtterance?.translatedText;
  const lastUtteranceStatus = lastUtterance?.status;

  useEffect(() => {
    if (
      !autoFollow ||
      !bilingual ||
      (presentation.utterances.length === 0 && liveBlocks.length === 0)
    ) {
      return;
    }
    const timer = window.setTimeout(() => {
      endRef.current?.scrollIntoView({ behavior: "smooth", block: "end" });
    }, 100);
    return () => window.clearTimeout(timer);
  }, [
    autoFollow,
    bilingual,
    liveBlocks.length,
    presentation.utterances.length,
    lastTranslatedText,
    lastUtteranceStatus,
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

  // Real local search filtering
  const query = searchQuery.trim().toLowerCase();
  const filteredUtterances = query
    ? presentation.utterances.filter(
        (u) =>
          u.sourceText.toLowerCase().includes(query) ||
          (u.translatedText && u.translatedText.toLowerCase().includes(query)),
      )
    : presentation.utterances;

  const empty = filteredUtterances.length === 0 && liveBlocks.length === 0;

  return (
    <div
      className={`flex flex-1 flex-col h-full overflow-hidden bg-surface ${
        fontScale === "large" ? "text-base" : "text-sm"
      }`}
      data-testid="translation-transcript-panel"
    >
      {/* 1. Utility Sub-header Bar */}
      <div className="flex-shrink-0 bg-white border-b border-slate-200 px-5 py-2.5 flex items-center justify-between gap-4 shadow-2xs">
        {/* Left: Audio Stream Status & Equalizer Indicator */}
        <div className="flex items-center gap-2.5 min-w-0">
          <div className="flex items-center gap-1.5 px-2.5 py-1 rounded-md bg-indigo-50 text-brand-primary border border-indigo-100 font-sans text-[11px] uppercase tracking-wider font-bold flex-shrink-0">
            <svg
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth="2"
              strokeLinecap="round"
              strokeLinejoin="round"
              className="size-3.5"
              aria-hidden="true"
            >
              <path d="M2 10v3" />
              <path d="M6 6v11" />
              <path d="M10 3v18" />
              <path d="M14 8v7" />
              <path d="M18 5v13" />
              <path d="M22 10v3" />
            </svg>
            <span>AUDIO STREAM</span>
          </div>

          {/* Decorative Waveform Equalizer (Activity indication only: NO fake dB) */}
          <div
            className="flex items-center gap-[3px] h-4 px-1"
            aria-hidden="true"
          >
            <span
              className="w-[2.5px] h-2 bg-indigo-400 rounded-full animate-pulse"
              style={{ animationDuration: "800ms" }}
            />
            <span
              className="w-[2.5px] h-3.5 bg-brand-primary rounded-full animate-pulse"
              style={{ animationDuration: "600ms" }}
            />
            <span
              className="w-[2.5px] h-4 bg-indigo-500 rounded-full animate-pulse"
              style={{ animationDuration: "400ms" }}
            />
            <span
              className="w-[2.5px] h-2.5 bg-indigo-300 rounded-full animate-pulse"
              style={{ animationDuration: "700ms" }}
            />
          </div>
        </div>

        {/* Right: Search, Font Zoom, Auto-Follow Controls */}
        <div className="flex items-center gap-2.5 flex-shrink-0">
          {/* Real Local Search */}
          <div className="relative flex items-center">
            <svg
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth="2"
              strokeLinecap="round"
              strokeLinejoin="round"
              className="size-3.5 absolute left-2.5 text-slate-400 pointer-events-none"
              aria-hidden="true"
            >
              <circle cx="11" cy="11" r="8" />
              <line x1="21" y1="21" x2="16.65" y2="16.65" />
            </svg>
            <input
              type="text"
              value={searchQuery}
              onChange={(e) => setSearchQuery(e.target.value)}
              placeholder="Search transcript..."
              className="h-8 pl-8 pr-2.5 text-xs bg-slate-50 border border-slate-200 rounded-lg text-slate-800 w-40 sm:w-48 placeholder-slate-400 focus:outline-none focus:bg-white focus:border-brand-primary"
            />
          </div>

          {/* Real Font Size Toggle */}
          <div className="hidden sm:flex items-center bg-slate-50 border border-slate-200 rounded-lg overflow-hidden text-xs">
            <button
              type="button"
              onClick={() => setFontScale("normal")}
              className={`px-2.5 py-1 font-medium transition ${
                fontScale === "normal"
                  ? "bg-white text-slate-900 shadow-2xs font-semibold"
                  : "text-slate-500 hover:text-slate-800"
              }`}
              title="Standard font size"
            >
              A
            </button>
            <button
              type="button"
              onClick={() => setFontScale("large")}
              className={`px-2.5 py-1 font-medium transition ${
                fontScale === "large"
                  ? "bg-white text-slate-900 shadow-2xs font-semibold"
                  : "text-slate-500 hover:text-slate-800"
              }`}
              title="Larger font size"
            >
              A+
            </button>
          </div>

          {/* Real Auto-Follow Toggle */}
          <button
            type="button"
            onClick={() => setAutoFollow((prev) => !prev)}
            className={`flex items-center gap-1.5 px-3 py-1 rounded-lg text-xs font-semibold transition ${
              autoFollow
                ? "bg-brand-primary text-white shadow-2xs hover:bg-brand-primary-strong"
                : "bg-slate-100 text-slate-600 border border-slate-200 hover:bg-slate-200"
            }`}
          >
            <svg
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth="2.5"
              strokeLinecap="round"
              strokeLinejoin="round"
              className="size-3.5"
              aria-hidden="true"
            >
              <polyline points="7 13 12 18 17 13" />
              <polyline points="7 6 12 11 17 6" />
            </svg>
            <span className="hidden sm:inline">Auto-follow</span>
            <span>{autoFollow ? "ON" : "OFF"}</span>
          </button>
        </div>
      </div>

      {/* 2. Mandatory Split Bilingual Column Headers */}
      <div
        className="grid grid-cols-2 gap-4 px-6 pt-3 pb-2 flex-shrink-0"
        data-testid="bilingual-column-headers"
      >
        {/* Left Column Header: Original VI */}
        <div className="flex items-center justify-between py-1.5 px-3 rounded-lg bg-slate-100/90 border border-slate-200 text-slate-700">
          <div className="flex items-center gap-2">
            <svg
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth="2"
              strokeLinecap="round"
              strokeLinejoin="round"
              className="size-3.5 text-slate-500"
              aria-hidden="true"
            >
              <path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3Z" />
              <path d="M19 10v2a7 7 0 0 1-14 0v-2" />
              <line x1="12" x2="12" y1="19" y2="22" />
            </svg>
            <span className="text-[11px] font-bold uppercase tracking-wider text-slate-700">
              ORIGINAL · VIETNAMESE (VI)
            </span>
          </div>
          <span className="px-2 py-0.5 rounded bg-white text-slate-600 text-[10px] font-bold border border-slate-200 shadow-2xs">
            Audio In
          </span>
        </div>

        {/* Right Column Header: Translation Target */}
        <div className="flex items-center justify-between py-1.5 px-3 rounded-lg bg-indigo-50/90 border border-indigo-100 text-brand-primary">
          <div className="flex items-center gap-2">
            <svg
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth="2"
              strokeLinecap="round"
              strokeLinejoin="round"
              className="size-3.5 text-brand-primary"
              aria-hidden="true"
            >
              <path d="m5 8 6 6" />
              <path d="m4 14 6-6 2-3" />
              <path d="M2 5h12" />
              <path d="M7 2h1" />
              <path d="m22 22-5-10-5 10" />
              <path d="M14 18h6" />
            </svg>
            <span className="text-[11px] font-bold uppercase tracking-wider text-brand-primary">
              TRANSLATION · {targetLabel.toUpperCase()} (
              {targetLang.toUpperCase()})
            </span>
          </div>
          <span className="px-2 py-0.5 rounded bg-brand-primary text-white text-[10px] font-bold shadow-2xs">
            Live Target
          </span>
        </div>
      </div>

      {/* 3. Transcript Feed & Scroll Workspace */}
      <div
        className="flex-1 overflow-y-auto px-6 py-3 space-y-3 custom-scroll"
        aria-live="polite"
        aria-relevant="additions text"
        data-testid="bilingual-transcript-feed"
      >
        {warning ? (
          <div
            className="rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 text-xs leading-5 text-amber-900"
            role="status"
          >
            {warning}
          </div>
        ) : null}

        {empty ? (
          <div className="flex min-h-[300px] flex-col items-center justify-center text-center p-8">
            <div
              className="flex size-14 items-center justify-center rounded-2xl border border-brand-primary/15 bg-brand-primary/[0.06] text-brand-primary mb-4"
              aria-hidden="true"
            >
              <svg
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="1.8"
                strokeLinecap="round"
                strokeLinejoin="round"
                className="size-7"
              >
                <path d="M4 12v2a4 4 0 0 0 4 4h1" />
                <path d="M15 10v4" />
                <path d="M12 7v10" />
                <path d="M9 10v4" />
                <path d="M18 8v8" />
              </svg>
            </div>
            <h3 className="font-display text-lg font-semibold text-slate-800">
              {query ? "No matching transcripts found" : emptyTitle}
            </h3>
            <p className="mt-1.5 max-w-sm text-xs text-slate-500 leading-relaxed">
              {query
                ? `No utterance matched "${query}". Try another search term.`
                : emptyDescription}
            </p>
          </div>
        ) : (
          <ol className="space-y-3" aria-label="Bilingual utterances feed">
            {filteredUtterances.map((utterance) => (
              <BilingualTranscriptBlock
                key={translationUtteranceKey(
                  utterance.streamId,
                  utterance.utteranceId,
                )}
                utterance={utterance}
              />
            ))}

            {/* 4. Active Live Speech Row (Interim Streaming) */}
            {liveBlocks.length > 0 ? (
              <li
                className="bg-white rounded-xl border-2 border-brand-primary/40 shadow-xs relative overflow-hidden bg-gradient-to-r from-white via-indigo-50/20 to-white"
                data-testid="live-speech-row"
                aria-label="Live Speech"
              >
                <div className="absolute top-0 left-0 right-0 h-1 bg-gradient-to-r from-brand-primary via-indigo-400 to-brand-primary" />

                {/* Header */}
                <div className="flex items-center justify-between px-4 py-2 bg-indigo-50/50 border-b border-indigo-100 text-slate-700">
                  <div className="flex items-center gap-2">
                    <span className="relative flex size-2">
                      <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-brand-primary opacity-75" />
                      <span className="relative inline-flex rounded-full size-2 bg-brand-primary" />
                    </span>
                    <span className="text-xs font-semibold text-brand-primary">
                      Streaming live speech
                    </span>
                  </div>
                  <span className="inline-flex items-center gap-1 px-2.5 py-0.5 rounded-full bg-brand-primary text-white text-[10px] font-bold shadow-2xs">
                    Live Speech
                  </span>
                </div>

                {/* Split Interim Content */}
                <div className="grid grid-cols-2 divide-x divide-indigo-100 p-4 gap-4 items-start">
                  {/* Left: Interim Source Speech */}
                  <div className="pr-2">
                    <div className="flex items-center gap-1.5 mb-1 text-[10px] font-bold uppercase tracking-wider text-slate-400">
                      <span>Transcribing Audio</span>
                      <span className="size-1.5 rounded-full bg-emerald-500 animate-pulse" />
                    </div>
                    <ol className="space-y-1.5">
                      {liveBlocks.map((block) => (
                        <TranscriptBlock key={block.id} block={block} />
                      ))}
                    </ol>
                  </div>

                  {/* Right: Interim Translation Indicator */}
                  <div className="pl-2">
                    <div className="p-3 bg-indigo-50/70 rounded-lg border border-indigo-200/80">
                      <div className="flex items-center justify-between mb-1 text-[10px] font-bold uppercase tracking-wider text-brand-primary">
                        <span>Interim Output</span>
                        <span className="inline-flex items-center gap-1 px-2 py-0.5 rounded-full bg-indigo-100 text-brand-primary text-[10px] font-medium">
                          <svg
                            className="animate-spin size-3"
                            viewBox="0 0 24 24"
                            fill="none"
                          >
                            <circle
                              className="opacity-25"
                              cx="12"
                              cy="12"
                              r="10"
                              stroke="currentColor"
                              strokeWidth="4"
                            />
                            <path
                              className="opacity-75"
                              fill="currentColor"
                              d="M4 12a8 8 0 018-8v8H4z"
                            />
                          </svg>
                          Translating...
                        </span>
                      </div>
                      <p className="font-sans text-xs italic text-indigo-900/80 leading-relaxed">
                        Processing live sentence boundary...
                      </p>
                    </div>
                  </div>
                </div>
              </li>
            ) : null}
          </ol>
        )}

        <div ref={endRef} aria-hidden="true" />
      </div>
    </div>
  );
}
