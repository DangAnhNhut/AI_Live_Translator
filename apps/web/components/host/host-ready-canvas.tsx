import type { AudioSourceType, HostSessionState } from "@/lib/host/host-session";
import { getLanguageLabel } from "@/lib/realtime/translation-presentation";
import type { TargetLanguage } from "@/lib/realtime/translation";

type HostReadyCanvasProps = {
  selectedSource: AudioSourceType | null;
  targetLanguage: TargetLanguage;
  canStart: boolean;
  onStart: () => void;
  message?: string | null;
  state: HostSessionState;
};

export function HostReadyCanvas({
  selectedSource,
  targetLanguage,
  canStart,
  onStart,
  message,
  state,
}: HostReadyCanvasProps) {
  const isPending =
    state === "requesting_permission" || state === "connecting";

  return (
    <div
      className="flex flex-1 items-center justify-center p-6 sm:p-10 overflow-y-auto custom-scroll"
      data-testid="host-ready-canvas"
    >
      <div className="max-w-xl w-full flex flex-col items-center text-center">
        {/* Decorative Broadcast Ready Icon */}
        <div
          className="size-20 rounded-2xl bg-indigo-50 border border-indigo-100 flex items-center justify-center mb-6 shadow-sm"
          aria-hidden="true"
        >
          <div className="size-12 rounded-xl bg-brand-primary flex items-center justify-center text-white shadow-md">
            <svg
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth="2"
              strokeLinecap="round"
              strokeLinejoin="round"
              className="size-6"
            >
              <path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3Z" />
              <path d="M19 10v2a7 7 0 0 1-14 0v-2" />
              <line x1="12" x2="12" y1="19" y2="22" />
            </svg>
          </div>
        </div>

        {/* Title & Subtitle */}
        <h2 className="font-display font-bold text-2xl sm:text-3xl text-slate-900 tracking-tight mb-2">
          Ready to start live translation
        </h2>
        <p className="text-sm text-slate-500 max-w-md mx-auto mb-8 leading-relaxed">
          Your session is configured and ready. Start listening when you&apos;re
          ready to stream live captions.
        </p>

        {/* Configuration Summary Card (Strictly Real Data Only: No Fake Viewers) */}
        <div className="w-full bg-white rounded-2xl border border-slate-200 p-5 shadow-xs mb-8 text-left divide-y divide-slate-100">
          {/* Summary Row 1: Audio Source */}
          <div className="flex items-center justify-between pb-3.5">
            <div className="flex items-center gap-2.5">
              <span className="p-1.5 rounded-lg bg-slate-100 text-slate-600">
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
                  <path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3Z" />
                  <path d="M19 10v2a7 7 0 0 1-14 0v-2" />
                  <line x1="12" x2="12" y1="19" y2="22" />
                </svg>
              </span>
              <span className="text-xs font-semibold text-slate-700">
                Audio Source
              </span>
            </div>
            <span className="text-xs font-semibold text-slate-800">
              {selectedSource === "system"
                ? "System Audio (Browser / Tab playback)"
                : selectedSource === "microphone"
                  ? "Microphone (Device input)"
                  : "No source selected"}
            </span>
          </div>

          {/* Summary Row 2: Language Route */}
          <div className="flex items-center justify-between pt-3.5">
            <div className="flex items-center gap-2.5">
              <span className="p-1.5 rounded-lg bg-slate-100 text-slate-600">
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
                  <path d="m5 8 6 6" />
                  <path d="m4 14 6-6 2-3" />
                  <path d="M2 5h12" />
                  <path d="M7 2h1" />
                  <path d="m22 22-5-10-5 10" />
                  <path d="M14 18h6" />
                </svg>
              </span>
              <span className="text-xs font-semibold text-slate-700">
                Language Route
              </span>
            </div>
            <span className="text-xs font-bold text-brand-primary">
              Vietnamese (VI) → {getLanguageLabel(targetLanguage)} (
              {targetLanguage.toUpperCase()})
            </span>
          </div>
        </div>

        {/* Message / Error alert if present */}
        {message ? (
          <div
            className={`w-full mb-6 p-4 rounded-xl border text-sm text-left ${
              state === "error"
                ? "bg-red-50 border-red-200 text-[#93000a]"
                : "bg-slate-50 border-slate-200 text-slate-600"
            }`}
            role={state === "error" ? "alert" : "status"}
          >
            {message}
          </div>
        ) : null}

        {/* Primary CTA Button */}
        <div className="flex flex-col sm:flex-row items-center gap-3 w-full sm:w-auto">
          <button
            type="button"
            onClick={onStart}
            disabled={!canStart || isPending}
            className="w-full sm:w-auto inline-flex items-center justify-center px-8 py-3.5 bg-brand-primary hover:bg-brand-primary-strong text-white font-semibold rounded-xl shadow-md transition disabled:cursor-not-allowed disabled:opacity-45 gap-2.5 text-sm"
          >
            {isPending ? (
              <>
                <svg
                  className="animate-spin size-4 text-white"
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
                <span>Connecting...</span>
              </>
            ) : (
              <>
                <svg
                  viewBox="0 0 24 24"
                  fill="currentColor"
                  className="size-4"
                  aria-hidden="true"
                >
                  <polygon points="5 3 19 12 5 21 5 3" />
                </svg>
                <span>Start Listening</span>
              </>
            )}
          </button>
        </div>

        <p className="text-[11px] text-slate-400 mt-4">
          Captions will automatically appear once speech input is detected.
        </p>
      </div>
    </div>
  );
}
