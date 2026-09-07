"use client";

import { useState } from "react";
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
  const [copied, setCopied] = useState(false);
  const view = buildBilingualTranscriptBlockView(utterance);
  const pending = view.status === "pending";
  const failed = view.status === "failed";
  const finalized = view.status === "final";

  const handleCopy = async () => {
    const textToCopy =
      utterance.translatedText && utterance.translatedText.trim().length > 0
        ? `${utterance.sourceText}\n${utterance.translatedText}`
        : utterance.sourceText;
    try {
      await navigator.clipboard.writeText(textToCopy);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      // Fallback
    }
  };

  return (
    <li
      className="bg-white rounded-xl border border-slate-200/80 shadow-2xs hover:shadow-xs transition overflow-hidden"
      data-testid="bilingual-transcript-row"
      data-utterance-id={utterance.utteranceId}
    >
      {/* Row Meta Header (Real data only: No fake timestamps or person names) */}
      <div className="flex items-center justify-between px-4 py-2 bg-slate-50/70 border-b border-slate-100 text-slate-600">
        <div className="flex items-center gap-2">
          {finalized ? (
            <span
              className="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full bg-slate-100 text-slate-600 text-[10px] font-semibold"
              data-testid="utterance-status-finalized"
            >
              <span className="size-1.5 rounded-full bg-slate-400" />
              Finalized
            </span>
          ) : pending ? (
            <span
              className="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full bg-indigo-50 text-brand-primary text-[10px] font-semibold"
              data-testid="utterance-status-translating"
            >
              <span className="size-1.5 rounded-full bg-brand-primary animate-pulse" />
              Translating...
            </span>
          ) : (
            <span
              className="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full bg-red-50 text-state-error text-[10px] font-semibold"
              data-testid="utterance-status-failed"
            >
              <span className="size-1.5 rounded-full bg-state-error" />
              Translation unavailable
            </span>
          )}
        </div>

        {/* Real Clipboard Copy Action */}
        <button
          type="button"
          onClick={handleCopy}
          className="p-1 rounded text-slate-400 hover:text-slate-700 hover:bg-white transition"
          title="Copy bilingual utterance to clipboard"
          aria-label="Copy utterance text"
        >
          {copied ? (
            <svg
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth="2.5"
              className="size-3.5 text-emerald-600"
            >
              <polyline points="20 6 9 17 4 12" />
            </svg>
          ) : (
            <svg
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth="2"
              strokeLinecap="round"
              strokeLinejoin="round"
              className="size-3.5"
            >
              <rect x="9" y="9" width="13" height="13" rx="2" ry="2" />
              <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
            </svg>
          )}
        </button>
      </div>

      {/* Side-by-Side Split Body (50/50 Split aligned by utterance identity) */}
      <div className="grid grid-cols-2 divide-x divide-slate-100 p-4 gap-4 items-start">
        {/* Left Column: Original Source Speech */}
        <div className="pr-2" data-testid="utterance-source-column">
          <p className="font-sans text-[15px] text-slate-700 leading-relaxed font-normal break-words">
            {view.sourceText}
          </p>
        </div>

        {/* Right Column: Translated Target Speech */}
        <div className="pl-2" data-testid="utterance-translation-column">
          {pending ? (
            <div
              className="p-3 bg-indigo-50/30 rounded-lg border border-dashed border-indigo-200/80 flex items-center gap-2 text-slate-500 italic text-sm"
              role="status"
            >
              <svg
                className="animate-spin size-3.5 text-brand-primary"
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
              <span>Translating...</span>
            </div>
          ) : failed ? (
            <div
              className="p-3 bg-red-50/70 rounded-lg border border-red-200"
              role="status"
            >
              <p className="text-xs font-semibold text-[#93000a]">
                {view.translationText}
              </p>
              {view.secondaryHint ? (
                <p className="text-[11px] text-[#93000a]/80 mt-1 leading-normal">
                  {view.secondaryHint}
                </p>
              ) : null}
            </div>
          ) : (
            <div className="p-3 bg-indigo-50/40 rounded-lg border border-indigo-100/60">
              <p className="font-sans text-[16px] text-brand-primary font-semibold leading-relaxed break-words">
                {view.translationText}
              </p>
            </div>
          )}
        </div>
      </div>
    </li>
  );
}
