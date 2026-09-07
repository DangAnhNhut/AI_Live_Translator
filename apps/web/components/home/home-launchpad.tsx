"use client";

import { useState } from "react";
import { useRouter } from "next/navigation";

import {
  generateSessionId,
  parseSessionInput,
  validateCustomSessionId,
} from "@/lib/home/session-slug";

export function HomeLaunchpad() {
  const router = useRouter();

  // Host state
  const [isStartingHost, setIsStartingHost] = useState(false);
  const [showCustomHost, setShowCustomHost] = useState(false);
  const [customHostId, setCustomHostId] = useState("");
  const [customHostError, setCustomHostError] = useState<string | null>(null);

  // Viewer / Join state
  const [joinInput, setJoinInput] = useState("");
  const [joinError, setJoinError] = useState<string | null>(null);
  const [isJoining, setIsJoining] = useState(false);

  const handleStartGeneratedHost = () => {
    setIsStartingHost(true);
    const newSessionId = generateSessionId();
    router.push(`/host/${encodeURIComponent(newSessionId)}`);
  };

  const handleStartCustomHost = (e: React.FormEvent) => {
    e.preventDefault();
    const result = validateCustomSessionId(customHostId);
    if (!result.valid) {
      setCustomHostError(result.error);
      return;
    }
    setCustomHostError(null);
    setIsStartingHost(true);
    router.push(`/host/${encodeURIComponent(result.sessionId)}`);
  };

  const handleJoinSession = (e: React.FormEvent) => {
    e.preventDefault();
    const result = parseSessionInput(joinInput);
    if (!result.valid) {
      setJoinError(result.error);
      return;
    }
    setJoinError(null);
    setIsJoining(true);
    router.push(`/live/${encodeURIComponent(result.sessionId)}`);
  };

  return (
    <div className="w-full space-y-6 sm:space-y-8">
      {/* Hero Section */}
      <section className="text-center space-y-2.5 pt-0 pb-1">
        <div className="inline-flex items-center gap-2 px-3 py-1 rounded-full bg-indigo-50 border border-indigo-100/80 text-brand-primary text-xs font-semibold tracking-wide shadow-2xs">
          <span className="flex h-2 w-2 relative">
            <span className="animate-ping absolute inline-flex h-full w-full rounded-full bg-brand-primary opacity-75"></span>
            <span className="relative inline-flex rounded-full h-2 w-2 bg-brand-primary"></span>
          </span>
          <span>Realtime Speech Translation</span>
        </div>

        <h1 className="font-display text-2xl sm:text-3xl lg:text-4xl font-extrabold text-text-primary tracking-tight leading-[1.15]">
          Understand anyone.{" "}
          <span className="text-brand-primary">Speak to everyone.</span>
        </h1>

        <p className="max-w-2xl mx-auto text-xs sm:text-sm text-text-secondary leading-relaxed font-normal">
          Realtime spoken translation workstation. Presenters stream speech from
          browser audio; attendees follow along with live dual-column captions.
        </p>
      </section>

      {/* Primary Action Cards Grid */}
      <div className="grid grid-cols-1 md:grid-cols-2 gap-5 lg:gap-6 items-stretch">
        {/* CARD 1: HOST SESSION (PRESENTER) */}
        <section
          data-testid="host-session-card"
          className="relative bg-surface-card rounded-2xl border border-slate-200/90 shadow-[0_4px_24px_-4px_rgba(79,95,231,0.07)] p-5 sm:p-6 flex flex-col justify-between hover:shadow-[0_8px_32px_-4px_rgba(79,95,231,0.12)] transition-shadow"
        >
          <div className="space-y-3">
            <div className="flex items-center justify-between">
              <div className="size-9 rounded-xl bg-indigo-50 border border-indigo-100 text-brand-primary flex items-center justify-center shadow-2xs">
                <svg
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  strokeWidth="2"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  className="size-5"
                  aria-hidden="true"
                >
                  <path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3Z" />
                  <path d="M19 10v2a7 7 0 0 1-14 0v-2" />
                  <line x1="12" x2="12" y1="19" y2="22" />
                </svg>
              </div>
              <span className="inline-flex items-center px-2 py-0.5 rounded-md bg-indigo-50/80 text-brand-primary text-[11px] font-semibold uppercase tracking-wider">
                Presenter
              </span>
            </div>

            <div className="space-y-1">
              <h2 className="font-display text-lg sm:text-xl font-bold text-text-primary">
                Host a Live Session
              </h2>
              <p className="text-xs sm:text-sm text-text-secondary leading-relaxed">
                Launch a presenter session. Configure microphone or system audio
                input and choose your translation target inside the live
                workstation before broadcasting.
              </p>
            </div>
          </div>

          <div className="pt-4 space-y-3">
            <button
              type="button"
              data-testid="start-host-btn"
              onClick={handleStartGeneratedHost}
              disabled={isStartingHost}
              className="w-full h-11 rounded-xl bg-brand-primary hover:bg-brand-primary-strong text-white font-semibold text-xs sm:text-sm flex items-center justify-center gap-2 shadow-md shadow-brand-primary/25 transition-all active:scale-[0.98] disabled:opacity-70 disabled:pointer-events-none cursor-pointer"
            >
              {isStartingHost ? (
                <>
                  <svg
                    className="animate-spin size-4 text-white"
                    fill="none"
                    viewBox="0 0 24 24"
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
                      d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
                    />
                  </svg>
                  <span>Starting Host Workstation...</span>
                </>
              ) : (
                <>
                  <svg
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    strokeWidth="2"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    className="size-4"
                    aria-hidden="true"
                  >
                    <polygon points="5 3 19 12 5 21 5 3" />
                  </svg>
                  <span>Host Live Session</span>
                </>
              )}
            </button>

            {/* Optional Custom Session ID Accordion */}
            <div className="pt-0.5 border-t border-slate-100">
              <button
                type="button"
                data-testid="custom-host-toggle"
                onClick={() => {
                  setShowCustomHost(!showCustomHost);
                  setCustomHostError(null);
                }}
                className="text-[11.5px] text-text-secondary hover:text-brand-primary font-medium flex items-center gap-1.5 transition-colors cursor-pointer"
              >
                <span>{showCustomHost ? "Hide custom ID" : "Use custom session ID"}</span>
                <svg
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  strokeWidth="2"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  className={`size-3 transition-transform ${showCustomHost ? "rotate-180" : ""}`}
                >
                  <polyline points="6 9 12 15 18 9" />
                </svg>
              </button>

              {showCustomHost && (
                <form
                  onSubmit={handleStartCustomHost}
                  className="mt-2.5 space-y-2"
                >
                  <div className="flex gap-2">
                    <input
                      type="text"
                      data-testid="custom-host-input"
                      value={customHostId}
                      onChange={(e) => {
                        setCustomHostId(e.target.value);
                        if (customHostError) setCustomHostError(null);
                      }}
                      placeholder="e.g. all-hands-q3"
                      className="flex-1 h-8 px-2.5 text-xs rounded-lg bg-slate-50 border border-slate-200 text-text-primary focus:bg-white focus:border-brand-primary focus:ring-2 focus:ring-brand-primary/20 outline-none transition-all"
                    />
                    <button
                      type="submit"
                      data-testid="start-custom-host-btn"
                      disabled={isStartingHost}
                      className="h-8 px-3 rounded-lg bg-slate-800 hover:bg-slate-900 text-white text-xs font-semibold transition-all shrink-0 cursor-pointer"
                    >
                      Start
                    </button>
                  </div>
                  {customHostError && (
                    <p className="text-[11.5px] text-state-error font-medium">
                      {customHostError}
                    </p>
                  )}
                </form>
              )}
            </div>
          </div>
        </section>

        {/* CARD 2: JOIN SESSION (AUDIENCE) */}
        <section
          data-testid="join-session-card"
          className="relative bg-surface-card rounded-2xl border border-slate-200/90 shadow-[0_4px_24px_-4px_rgba(15,23,42,0.04)] p-5 sm:p-6 flex flex-col justify-between hover:shadow-[0_8px_32px_-4px_rgba(15,23,42,0.08)] transition-shadow"
        >
          <div className="space-y-3">
            <div className="flex items-center justify-between">
              <div className="size-9 rounded-xl bg-slate-100 border border-slate-200 text-slate-700 flex items-center justify-center shadow-2xs">
                <svg
                  viewBox="0 0 24 24"
                  fill="none"
                  stroke="currentColor"
                  strokeWidth="2"
                  strokeLinecap="round"
                  strokeLinejoin="round"
                  className="size-5"
                  aria-hidden="true"
                >
                  <path d="M4 19.5v-15A2.5 2.5 0 0 1 6.5 2H20v20H6.5a2.5 2.5 0 0 1-2.5-2.5Z" />
                  <path d="M6 6h10" />
                  <path d="M6 10h10" />
                  <path d="M6 14h6" />
                </svg>
              </div>
              <span className="inline-flex items-center px-2 py-0.5 rounded-md bg-slate-100 text-slate-700 text-[11px] font-semibold uppercase tracking-wider">
                Audience
              </span>
            </div>

            <div className="space-y-1">
              <h2 className="font-display text-lg sm:text-xl font-bold text-text-primary">
                Join a Live Session
              </h2>
              <p className="text-xs sm:text-sm text-text-secondary leading-relaxed">
                Follow real-time translation captions in your browser. Enter the
                session ID or paste the link you received from the session host.
              </p>
            </div>
          </div>

          <form onSubmit={handleJoinSession} className="pt-4 space-y-2.5">
            <div className="space-y-1">
              <label
                htmlFor="join-session-input"
                className="block text-[11px] font-semibold uppercase tracking-wider text-text-secondary"
              >
                Session ID or Viewer Link
              </label>
              <div className="relative">
                <input
                  id="join-session-input"
                  data-testid="join-session-input"
                  type="text"
                  value={joinInput}
                  onChange={(e) => {
                    setJoinInput(e.target.value);
                    if (joinError) setJoinError(null);
                  }}
                  placeholder="e.g. room-101 or https://.../live/room-101"
                  className={`w-full h-11 px-3.5 rounded-xl bg-slate-50 border text-xs sm:text-sm text-text-primary focus:bg-white focus:ring-2 outline-none transition-all ${
                    joinError
                      ? "border-state-error focus:border-state-error focus:ring-state-error/20"
                      : "border-slate-200 focus:border-brand-primary focus:ring-brand-primary/20"
                  }`}
                />
              </div>
              {joinError && (
                <p
                  data-testid="join-error-message"
                  className="text-[11.5px] text-state-error font-medium flex items-center gap-1 mt-0.5"
                >
                  <svg
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    strokeWidth="2"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    className="size-3.5 shrink-0"
                  >
                    <circle cx="12" cy="12" r="10" />
                    <line x1="12" x2="12" y1="8" y2="12" />
                    <line x1="12" x2="12.01" y1="16" y2="16" />
                  </svg>
                  <span>{joinError}</span>
                </p>
              )}
            </div>

            <button
              type="submit"
              data-testid="join-session-btn"
              disabled={isJoining}
              className="w-full h-11 rounded-xl bg-slate-900 hover:bg-slate-800 text-white font-semibold text-xs sm:text-sm flex items-center justify-center gap-2 transition-all shadow-sm active:scale-[0.98] disabled:opacity-70 disabled:pointer-events-none cursor-pointer"
            >
              {isJoining ? (
                <>
                  <svg
                    className="animate-spin size-4 text-white"
                    fill="none"
                    viewBox="0 0 24 24"
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
                      d="M4 12a8 8 0 018-8V0C5.373 0 0 5.373 0 12h4zm2 5.291A7.962 7.962 0 014 12H0c0 3.042 1.135 5.824 3 7.938l3-2.647z"
                    />
                  </svg>
                  <span>Joining Session...</span>
                </>
              ) : (
                <>
                  <svg
                    viewBox="0 0 24 24"
                    fill="none"
                    stroke="currentColor"
                    strokeWidth="2"
                    strokeLinecap="round"
                    strokeLinejoin="round"
                    className="size-4"
                    aria-hidden="true"
                  >
                    <path d="M15 3h4a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2h-4" />
                    <polyline points="10 17 15 12 10 7" />
                    <line x1="15" x2="3" y1="12" y2="12" />
                  </svg>
                  <span>Join Live Session</span>
                </>
              )}
            </button>

            <p className="text-[11px] text-text-secondary text-center">
              Zero installation required · Direct live caption feed
            </p>
          </form>
        </section>
      </div>

      {/* Subordinate Product Capabilities */}
      <section className="pt-6 border-t border-slate-200/80">
        <div className="grid grid-cols-1 md:grid-cols-3 gap-4 sm:gap-5">
          <div className="p-4 sm:p-5 rounded-xl bg-white border border-slate-200/80 shadow-2xs space-y-2">
            <div className="flex items-center gap-2 text-brand-primary">
              <svg
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                strokeLinecap="round"
                strokeLinejoin="round"
                className="size-4.5"
              >
                <rect x="3" y="3" width="18" height="18" rx="2" />
                <line x1="12" x2="12" y1="3" y2="21" />
              </svg>
              <h3 className="font-display font-semibold text-xs sm:text-sm text-text-primary">
                Realtime Bilingual Captions
              </h3>
            </div>
            <p className="text-xs text-text-secondary leading-relaxed">
              Utterance-aligned dual columns show original Vietnamese alongside
              real-time translated text.
            </p>
          </div>

          <div className="p-4 sm:p-5 rounded-xl bg-white border border-slate-200/80 shadow-2xs space-y-2">
            <div className="flex items-center gap-2 text-brand-primary">
              <svg
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                strokeLinecap="round"
                strokeLinejoin="round"
                className="size-4.5"
              >
                <circle cx="12" cy="12" r="10" />
                <line x1="2" x2="22" y1="12" y2="12" />
                <path d="M12 2a15.3 15.3 0 0 1 4 10 15.3 15.3 0 0 1-4 10 15.3 15.3 0 0 1-4-10 15.3 15.3 0 0 1 4-10z" />
              </svg>
              <h3 className="font-display font-semibold text-xs sm:text-sm text-text-primary">
                Multiple Translation Targets
              </h3>
            </div>
            <p className="text-xs text-text-secondary leading-relaxed">
              Choose from English, Japanese, Korean, Chinese (Simplified), Thai,
              French, German, and Spanish.
            </p>
          </div>

          <div className="p-4 sm:p-5 rounded-xl bg-white border border-slate-200/80 shadow-2xs space-y-2">
            <div className="flex items-center gap-2 text-brand-primary">
              <svg
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                strokeLinecap="round"
                strokeLinejoin="round"
                className="size-4.5"
              >
                <path d="M10 13a5 5 0 0 0 7.54.54l3-3a5 5 0 0 0-7.07-7.07l-1.72 1.71" />
                <path d="M14 11a5 5 0 0 0-7.54-.54l-3 3a5 5 0 0 0 7.07 7.07l1.71-1.71" />
              </svg>
              <h3 className="font-display font-semibold text-xs sm:text-sm text-text-primary">
                Shareable Viewer Link
              </h3>
            </div>
            <p className="text-xs text-text-secondary leading-relaxed">
              Share a direct link for audience participants to follow live
              captions in their browser without signing in.
            </p>
          </div>
        </div>
      </section>
    </div>
  );
}
