"use client";

import { useState } from "react";
import type { AudioCaptureInfo } from "@/lib/audio/audio-input";
import type {
  AudioSourceType,
  HostSessionState,
} from "@/lib/host/host-session";
import {
  HOST_SOURCE_LANGUAGE,
  HOST_TARGET_LANGUAGE_OPTIONS,
} from "@/lib/host/host-translation";
import { getLanguageLabel } from "@/lib/realtime/translation-presentation";
import type {
  TargetLanguage,
  TranslationConfiguration,
} from "@/lib/realtime/translation";

import { HostStatus } from "./host-status";

type HostRightPanelProps = {
  sessionId: string;
  state: HostSessionState;
  selectedSource: AudioSourceType | null;
  sourceLocked: boolean;
  canStart: boolean;
  captureInfo: AudioCaptureInfo | null;
  message: string | null;
  onSelectSource: (source: AudioSourceType) => void;
  onStart: () => void;
  onStop: () => void;
  targetLanguage: TargetLanguage;
  targetLocked: boolean;
  onTargetChange: (target: TargetLanguage) => void;
  activeConfiguration: TranslationConfiguration | null;
};

export function HostRightPanel({
  sessionId,
  state,
  selectedSource,
  sourceLocked,
  canStart,
  captureInfo,
  message,
  onSelectSource,
  onStart,
  onStop,
  targetLanguage,
  targetLocked,
  onTargetChange,
  activeConfiguration,
}: HostRightPanelProps) {
  const [copied, setCopied] = useState(false);

  const handleCopyLink = async () => {
    if (typeof window === "undefined") return;
    const viewerUrl = `${window.location.origin}/live/${sessionId}`;
    try {
      await navigator.clipboard.writeText(viewerUrl);
      setCopied(true);
      setTimeout(() => setCopied(false), 1500);
    } catch {
      // Fallback
    }
  };

  const isLive = state === "live";
  const canStop =
    state === "requesting_permission" ||
    state === "connecting" ||
    state === "live";

  return (
    <aside
      aria-label="Host session control panel"
      className="w-[340px] flex-shrink-0 h-full overflow-y-auto bg-white border-l border-slate-200 p-5 space-y-5 custom-scroll flex flex-col justify-between"
      data-testid="host-right-panel"
    >
      <div className="space-y-5">
        {/* Section 1: Session Status */}
        <div className="space-y-2">
          <div className="flex items-center justify-between">
            <span className="text-[11px] font-bold uppercase tracking-wider text-slate-400">
              Session Status
            </span>
            <HostStatus state={state} />
          </div>
        </div>

        {/* Section 2: Audio Source Card */}
        <div className="rounded-xl border border-slate-200 bg-slate-50/70 p-4 space-y-3">
          <div className="flex items-center justify-between">
            <span className="text-[11px] font-bold uppercase tracking-wider text-slate-500">
              Audio Source
            </span>
            <span className="text-[11px] font-medium text-slate-400">
              {sourceLocked ? "Locked during session" : "Select one"}
            </span>
          </div>

          <div
            className="grid grid-cols-2 gap-2"
            role="radiogroup"
            aria-label="Audio source"
          >
            <button
              type="button"
              role="radio"
              aria-checked={selectedSource === "microphone"}
              disabled={sourceLocked}
              onClick={() => onSelectSource("microphone")}
              className={`flex flex-col items-center justify-center p-3 rounded-lg border text-center transition ${
                selectedSource === "microphone"
                  ? "border-brand-primary bg-indigo-50/60 text-brand-primary font-semibold shadow-2xs"
                  : "border-slate-200 bg-white hover:bg-slate-50 text-slate-700"
              } disabled:cursor-not-allowed disabled:opacity-60`}
            >
              <svg
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                strokeLinecap="round"
                strokeLinejoin="round"
                className="size-5 mb-1.5"
                aria-hidden="true"
              >
                <path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3Z" />
                <path d="M19 10v2a7 7 0 0 1-14 0v-2" />
                <line x1="12" x2="12" y1="19" y2="22" />
              </svg>
              <span className="text-xs">Microphone</span>
            </button>

            <button
              type="button"
              role="radio"
              aria-checked={selectedSource === "system"}
              disabled={sourceLocked}
              onClick={() => onSelectSource("system")}
              className={`flex flex-col items-center justify-center p-3 rounded-lg border text-center transition ${
                selectedSource === "system"
                  ? "border-brand-primary bg-indigo-50/60 text-brand-primary font-semibold shadow-2xs"
                  : "border-slate-200 bg-white hover:bg-slate-50 text-slate-700"
              } disabled:cursor-not-allowed disabled:opacity-60`}
            >
              <svg
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                strokeLinecap="round"
                strokeLinejoin="round"
                className="size-5 mb-1.5"
                aria-hidden="true"
              >
                <polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5" />
                <path d="M15.54 8.46a5 5 0 0 1 0 7.07" />
                <path d="M19.07 4.93a10 10 0 0 1 0 14.14" />
              </svg>
              <span className="text-xs">System Audio</span>
            </button>
          </div>

          {/* Decorative Audio Activity Visualizer (Real audio activity indication: NO fake dB) */}
          {isLive ? (
            <div className="pt-2 border-t border-slate-200/80 space-y-1.5">
              <div className="flex items-center justify-between text-[11px]">
                <span className="font-medium text-emerald-700 flex items-center gap-1.5">
                  <span className="size-1.5 rounded-full bg-emerald-500 animate-pulse" />
                  Audio stream active
                </span>
                {/* Decorative animated speech bars */}
                <div
                  className="flex items-end gap-[2px] h-3.5"
                  aria-hidden="true"
                >
                  <span className="w-1 h-2 bg-emerald-500 rounded-full animate-pulse" />
                  <span
                    className="w-1 h-3.5 bg-emerald-600 rounded-full animate-pulse"
                    style={{ animationDelay: "150ms" }}
                  />
                  <span
                    className="w-1 h-2.5 bg-emerald-400 rounded-full animate-pulse"
                    style={{ animationDelay: "300ms" }}
                  />
                  <span
                    className="w-1 h-3 bg-emerald-500 rounded-full animate-pulse"
                    style={{ animationDelay: "450ms" }}
                  />
                </div>
              </div>
              {captureInfo ? (
                <p className="text-[10px] text-slate-500">
                  {captureInfo.captureSampleRate.toLocaleString()} Hz capture →
                  16 kHz mono PCM
                </p>
              ) : null}
            </div>
          ) : null}
        </div>

        {/* Section 3: Language Route Card */}
        <div className="rounded-xl border border-slate-200 bg-slate-50/70 p-4 space-y-3">
          <div className="flex items-center justify-between">
            <span className="text-[11px] font-bold uppercase tracking-wider text-slate-500">
              Language Route
            </span>
            <span className="text-[11px] font-medium text-slate-400">
              {targetLocked ? "Locked" : "Select target"}
            </span>
          </div>

          <div className="grid grid-cols-2 gap-2">
            {/* Source: Read-only Vietnamese */}
            <div className="p-2.5 bg-white border border-slate-200 rounded-lg flex flex-col">
              <span className="text-[10px] text-slate-400 uppercase tracking-wider font-semibold">
                Source
              </span>
              <span className="text-xs font-semibold text-slate-800 mt-0.5">
                {HOST_SOURCE_LANGUAGE.label}
              </span>
              <span className="text-[10px] text-slate-400">vi</span>
            </div>

            {/* Target: 8 Approved Targets */}
            <div className="p-2.5 bg-indigo-50/60 border border-indigo-100 rounded-lg flex flex-col">
              <span className="text-[10px] text-brand-primary uppercase tracking-wider font-semibold">
                Target
              </span>
              <select
                aria-label="Target language"
                value={targetLanguage}
                disabled={targetLocked}
                onChange={(e) =>
                  onTargetChange(e.target.value as TargetLanguage)
                }
                className="mt-0.5 text-xs font-semibold text-brand-primary bg-transparent border-0 p-0 focus:ring-0 cursor-pointer disabled:cursor-not-allowed"
              >
                {HOST_TARGET_LANGUAGE_OPTIONS.map((opt) => (
                  <option key={opt.code} value={opt.code}>
                    {opt.label} ({opt.code})
                  </option>
                ))}
              </select>
              <span className="text-[10px] text-indigo-400">
                {targetLanguage}
              </span>
            </div>
          </div>

          {activeConfiguration ? (
            <p className="text-[10px] text-brand-primary pt-1 border-t border-slate-200/80">
              Confirmed: {getLanguageLabel(activeConfiguration.sourceLanguage)} →{" "}
              {getLanguageLabel(activeConfiguration.targetLanguage)}
            </p>
          ) : null}
        </div>

        {/* Section 4: Viewer Broadcast Link (Real data only: No fake viewer count or avatars) */}
        <div className="rounded-xl border border-slate-200 bg-slate-50/70 p-4 space-y-2.5">
          <div className="flex items-center justify-between">
            <span className="text-[11px] font-bold uppercase tracking-wider text-slate-500">
              Broadcast URL
            </span>
          </div>
          <p className="text-[11px] text-slate-500">
            Share this link for viewers to watch translated captions live:
          </p>
          <div className="flex items-center gap-1.5">
            <input
              type="text"
              readOnly
              value={
                typeof window !== "undefined"
                  ? `${window.location.origin}/live/${sessionId}`
                  : `/live/${sessionId}`
              }
              className="h-8 w-full px-2.5 text-xs bg-white border border-slate-200 rounded-lg text-slate-600 truncate focus:outline-none select-all"
            />
            <button
              type="button"
              onClick={handleCopyLink}
              className="h-8 px-3 rounded-lg bg-brand-primary hover:bg-brand-primary-strong text-white text-xs font-semibold transition whitespace-nowrap"
            >
              {copied ? "Copied!" : "Copy"}
            </button>
          </div>
        </div>

        {/* Real Message / Error Notice */}
        {message ? (
          <div
            className={`p-3 rounded-xl border text-xs leading-relaxed ${
              state === "error"
                ? "bg-red-50 border-red-200 text-[#93000a]"
                : "bg-slate-50 border-slate-200 text-slate-600"
            }`}
            role={state === "error" ? "alert" : "status"}
          >
            {message}
          </div>
        ) : null}
      </div>

      {/* Section 5: Session Actions (Bottom docked) */}
      <div className="pt-4 border-t border-slate-200 space-y-2">
        <span className="text-[11px] font-bold uppercase tracking-wider text-slate-400 block pb-0.5">
          Session Actions
        </span>

        {canStop ? (
          <button
            type="button"
            onClick={onStop}
            className="w-full flex items-center justify-center gap-2 py-2.5 px-4 rounded-xl bg-red-50 hover:bg-red-100 border border-red-200/80 text-state-error text-xs font-semibold transition shadow-2xs"
          >
            <svg
              viewBox="0 0 24 24"
              fill="currentColor"
              className="size-3.5"
              aria-hidden="true"
            >
              <rect x="5" y="5" width="14" height="14" rx="2" />
            </svg>
            <span>Stop Session</span>
          </button>
        ) : (
          <button
            type="button"
            onClick={onStart}
            disabled={!canStart}
            className="w-full flex items-center justify-center gap-2 py-2.5 px-4 rounded-xl bg-brand-primary hover:bg-brand-primary-strong text-white text-xs font-semibold transition shadow-sm disabled:cursor-not-allowed disabled:opacity-45"
          >
            <svg
              viewBox="0 0 24 24"
              fill="currentColor"
              className="size-3.5"
              aria-hidden="true"
            >
              <polygon points="5 3 19 12 5 21 5 3" />
            </svg>
            <span>Start Session</span>
          </button>
        )}
      </div>
    </aside>
  );
}
