"use client";

import { useState } from "react";
import type { AudioSourceType, HostSessionState } from "@/lib/host/host-session";
import type { TargetLanguage } from "@/lib/realtime/translation";

type HostHeaderProps = {
  sessionId?: string;
  state?: HostSessionState;
  selectedSource?: AudioSourceType | null;
  targetLanguage?: TargetLanguage;
  elapsedSeconds?: number;
};

function formatDuration(totalSeconds: number): string {
  const hours = Math.floor(totalSeconds / 3600);
  const minutes = Math.floor((totalSeconds % 3600) / 60);
  const seconds = totalSeconds % 60;
  if (hours > 0) {
    return `${String(hours).padStart(2, "0")}:${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`;
  }
  return `${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`;
}

export function HostHeader({
  sessionId = "",
  state = "ready",
  selectedSource = null,
  targetLanguage = "en",
  elapsedSeconds = 0,
}: HostHeaderProps) {
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

  return (
    <header className="flex h-16 flex-shrink-0 items-center justify-between border-b border-slate-200 bg-white px-6 z-20 shadow-[0_1px_2px_rgba(0,0,0,0.03)]">
      {/* Left: Breadcrumbs & Real State Info */}
      <div className="flex items-center gap-3 min-w-0">
        {/* Breadcrumb */}
        <div className="flex items-center gap-2 text-slate-500 font-sans text-xs sm:text-sm flex-shrink-0">
          <span className="font-medium text-slate-600">Live Session</span>
          <span className="text-slate-300">/</span>
          <span className="font-mono text-slate-900 font-semibold truncate max-w-[140px] sm:max-w-[200px]">
            {sessionId}
          </span>
        </div>

        <span className="text-slate-300 hidden sm:inline" aria-hidden="true">
          |
        </span>

        {/* Real Status Badge */}
        {isLive ? (
          <span className="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full bg-emerald-50 border border-emerald-200 text-emerald-700 text-[11px] uppercase tracking-wide font-bold flex-shrink-0">
            <span className="relative flex size-2">
              <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-emerald-400 opacity-75" />
              <span className="relative inline-flex rounded-full size-2 bg-emerald-600" />
            </span>
            LIVE
          </span>
        ) : state === "connecting" || state === "requesting_permission" ? (
          <span className="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full bg-indigo-50 border border-indigo-200 text-brand-primary text-[11px] uppercase tracking-wide font-bold flex-shrink-0">
            <span className="size-2 rounded-full bg-brand-primary animate-pulse" />
            Connecting
          </span>
        ) : state === "stopping" ? (
          <span className="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full bg-amber-50 border border-amber-200 text-amber-700 text-[11px] uppercase tracking-wide font-bold flex-shrink-0">
            Stopping
          </span>
        ) : state === "error" ? (
          <span className="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full bg-red-50 border border-red-200 text-state-error text-[11px] uppercase tracking-wide font-bold flex-shrink-0">
            Error
          </span>
        ) : (
          <span className="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full bg-slate-100 border border-slate-200 text-slate-600 text-[11px] uppercase tracking-wide font-bold flex-shrink-0">
            <span className="size-2 rounded-full bg-slate-400" />
            READY
          </span>
        )}

        {/* Language Route Chip */}
        <div className="hidden sm:flex items-center gap-1 px-2 py-0.5 rounded-md bg-indigo-50 border border-indigo-100 text-[11px] font-bold text-brand-primary flex-shrink-0">
          <span>VI</span>
          <span className="text-indigo-400" aria-hidden="true">
            →
          </span>
          <span>{targetLanguage.toUpperCase()}</span>
        </div>

        {/* Presentation-Only Live Timer */}
        <div className="flex items-center gap-1.5 px-2.5 py-0.5 text-slate-600 text-xs bg-slate-50 border border-slate-200 rounded-md font-mono tabular-nums font-semibold flex-shrink-0">
          <svg
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
            className="size-3.5 text-slate-400"
            aria-hidden="true"
          >
            <circle cx="12" cy="12" r="10" />
            <polyline points="12 6 12 12 16 14" />
          </svg>
          <span data-testid="live-timer">{formatDuration(elapsedSeconds)}</span>
        </div>
      </div>

      {/* Right: Audio Tag, Share Link */}
      <div className="flex items-center gap-3 flex-shrink-0">
        {/* Selected Audio Source Tag */}
        {selectedSource ? (
          <div className="hidden md:flex items-center gap-1.5 px-3 py-1 rounded-lg bg-slate-50 border border-slate-200 text-slate-700 text-xs font-medium">
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
              {selectedSource === "system" ? (
                <>
                  <polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5" />
                  <path d="M15.54 8.46a5 5 0 0 1 0 7.07" />
                  <path d="M19.07 4.93a10 10 0 0 1 0 14.14" />
                </>
              ) : (
                <>
                  <path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3Z" />
                  <path d="M19 10v2a7 7 0 0 1-14 0v-2" />
                  <line x1="12" x2="12" y1="19" y2="22" />
                </>
              )}
            </svg>
            <span>
              {selectedSource === "system" ? "System Audio" : "Microphone"}
            </span>
          </div>
        ) : null}

        {/* Share Button with 1-click Copy */}
        <button
          type="button"
          onClick={handleCopyLink}
          className="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg border border-slate-200 bg-white hover:bg-slate-50 text-slate-700 text-xs font-medium transition shadow-2xs"
          title="Copy live viewer link"
        >
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
            <circle cx="18" cy="5" r="3" />
            <circle cx="6" cy="12" r="3" />
            <circle cx="18" cy="19" r="3" />
            <line x1="8.59" x2="15.42" y1="13.51" y2="17.49" />
            <line x1="15.41" x2="8.59" y1="6.51" y2="10.49" />
          </svg>
          <span>{copied ? "Link Copied!" : "Share Link"}</span>
        </button>
      </div>
    </header>
  );
}
