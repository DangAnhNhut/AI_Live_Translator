"use client";

import Image from "next/image";
import type { TranslationConfiguration } from "@/lib/realtime/translation";
import type { ViewerConnectionStatus } from "@/lib/realtime/viewer-socket";
import {
  formatViewerLanguageRoute,
  getViewerSessionBreadcrumb,
} from "@/lib/realtime/viewer-presentation";

export type LiveHeaderProps = {
  sessionId?: string;
  status?: ViewerConnectionStatus;
  activeConfiguration?: TranslationConfiguration | null;
};

export function LiveHeader({
  sessionId = "",
  status = "connecting",
  activeConfiguration = null,
}: LiveHeaderProps) {
  const breadcrumb = sessionId ? getViewerSessionBreadcrumb(sessionId) : null;
  const languageRoute = formatViewerLanguageRoute(activeConfiguration);

  return (
    <header
      className="sticky top-0 z-30 flex h-16 w-full flex-shrink-0 items-center justify-between border-b border-slate-200 bg-white/95 px-6 backdrop-blur-md shadow-[0_1px_3px_0_rgba(0,0,0,0.03)]"
      data-purpose="viewer-header"
    >
      <div className="mx-auto flex w-full max-w-[1536px] items-center justify-between gap-4">
        {/* Left: Brand Logo & Product Identifier */}
        <div className="flex items-center gap-3 shrink-0" data-purpose="brand-container">
          <div className="flex items-center gap-2.5">
            <Image
              src="/app-icon.jpg"
              alt=""
              width={32}
              height={32}
              priority
              className="size-8 rounded-lg shadow-xs"
            />
            <span className="font-display text-base sm:text-[17px] font-bold tracking-tight text-slate-900">
              AI Live Translator
            </span>
          </div>
        </div>

        {/* Center / Session Context: Session ID, Connection Status, Language Route */}
        {breadcrumb ? (
          <div className="flex items-center gap-2.5 sm:gap-3 shrink-0">
            {/* Breadcrumb */}
            <div className="flex items-center gap-1.5 sm:gap-2 text-slate-500 font-sans text-xs sm:text-sm">
              <span className="font-medium text-slate-600 hidden md:inline">
                {breadcrumb.category}
              </span>
              <span className="text-slate-300 hidden md:inline">/</span>
              <span
                className="font-mono text-slate-900 font-semibold truncate max-w-[120px] sm:max-w-[200px]"
                title={breadcrumb.sessionId}
              >
                {breadcrumb.sessionId}
              </span>
            </div>

            <span className="text-slate-300 hidden sm:inline" aria-hidden="true">
              |
            </span>

            {/* Connection Status Badge */}
            {status === "live" ? (
              <span className="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full bg-emerald-50 border border-emerald-200 text-emerald-700 text-[11px] uppercase tracking-wide font-bold flex-shrink-0">
                <span className="relative flex size-2">
                  <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-emerald-400 opacity-75" />
                  <span className="relative inline-flex rounded-full size-2 bg-emerald-600" />
                </span>
                LIVE
              </span>
            ) : status === "connecting" ? (
              <span className="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full bg-amber-50 border border-amber-200 text-amber-700 text-[11px] uppercase tracking-wide font-bold flex-shrink-0">
                <span className="size-2 rounded-full bg-amber-500 animate-pulse" />
                Connecting
              </span>
            ) : status === "reconnecting" ? (
              <span className="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full bg-amber-50 border border-amber-200 text-amber-800 text-[11px] uppercase tracking-wide font-bold flex-shrink-0">
                <span className="size-2 rounded-full bg-amber-600 animate-pulse" />
                Reconnecting
              </span>
            ) : status === "error" ? (
              <span className="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full bg-rose-50 border border-rose-200 text-rose-700 text-[11px] uppercase tracking-wide font-bold flex-shrink-0">
                <span className="size-2 rounded-full bg-rose-500" />
                Error
              </span>
            ) : (
              <span className="inline-flex items-center gap-1.5 px-2.5 py-0.5 rounded-full bg-slate-100 border border-slate-200 text-slate-600 text-[11px] uppercase tracking-wide font-bold flex-shrink-0">
                <span className="size-2 rounded-full bg-slate-400" />
                Disconnected
              </span>
            )}

            {/* Language Route Chip */}
            <div className="flex items-center gap-1 px-2 sm:px-2.5 py-0.5 rounded-md bg-indigo-50 border border-indigo-100 text-[11px] font-bold text-brand-primary flex-shrink-0">
              <span>{languageRoute}</span>
            </div>
          </div>
        ) : null}

        {/* Right: Receive-Only Mode Indicator */}
        <div className="flex items-center gap-2 shrink-0">
          <span className="inline-flex items-center gap-1.5 px-2.5 py-1 rounded-full border border-indigo-100 bg-indigo-50/80 text-[11px] font-bold tracking-wide text-brand-primary uppercase">
            <svg
              className="size-3.5 text-brand-primary"
              fill="none"
              stroke="currentColor"
              strokeWidth="2"
              viewBox="0 0 24 24"
              aria-hidden="true"
            >
              <path
                strokeLinecap="round"
                strokeLinejoin="round"
                d="M15 12a3 3 0 11-6 0 3 3 0 016 0z"
              />
              <path
                strokeLinecap="round"
                strokeLinejoin="round"
                d="M2.458 12C3.732 7.943 7.523 5 12 5c4.478 0 8.268 2.943 9.542 7-1.274 4.057-5.064 7-9.542 7-4.477 0-8.268-2.943-9.542-7z"
              />
            </svg>
            <span className="hidden sm:inline">Receive only</span>
            <span className="sm:hidden">Viewer</span>
          </span>
        </div>
      </div>
    </header>
  );
}
