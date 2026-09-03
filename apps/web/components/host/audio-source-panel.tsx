import type { AudioCaptureInfo } from "@/lib/audio/audio-input";
import type {
  AudioSourceType,
  HostSessionState,
} from "@/lib/host/host-session";

import { HostStatus } from "./host-status";

type AudioSourcePanelProps = {
  state: HostSessionState;
  selectedSource: AudioSourceType | null;
  sourceLocked: boolean;
  canStart: boolean;
  captureInfo: AudioCaptureInfo | null;
  message: string | null;
  onSelectSource: (source: AudioSourceType) => void;
  onStart: () => void;
  onStop: () => void;
};

const AUDIO_SOURCES: ReadonlyArray<{
  type: AudioSourceType;
  label: string;
  description: string;
}> = [
  {
    type: "microphone",
    label: "Microphone",
    description: "Capture speech from this device's microphone.",
  },
  {
    type: "system",
    label: "System Audio",
    description: "Capture playback from a browser tab or desktop source.",
  },
];

export function AudioSourcePanel({
  state,
  selectedSource,
  sourceLocked,
  canStart,
  captureInfo,
  message,
  onSelectSource,
  onStart,
  onStop,
}: AudioSourcePanelProps) {
  const canStop =
    state === "requesting_permission" ||
    state === "connecting" ||
    state === "live";
  const privacyCopy =
    selectedSource === "microphone"
      ? "The browser controls microphone access. Audio is streamed only while this session is live; Stop ends capture."
      : selectedSource === "system"
        ? "The browser controls what is shared. Select a source with audio enabled; Stop ends capture."
        : "Choose one source. Browser permission is requested only after you select Start Session.";

  return (
    <section className="rounded-2xl border border-border-default bg-white p-5 shadow-[0_10px_24px_-20px_rgba(17,24,39,0.18)] sm:p-6">
      <div>
        <p className="text-xs font-semibold uppercase tracking-[0.05em] text-brand-primary">
          Audio source
        </p>
        <h2 className="mt-2 font-display text-xl font-semibold text-text-primary">
          Choose one source
        </h2>
      </div>

      <div
        className="mt-5 grid gap-3"
        role="radiogroup"
        aria-label="Audio source"
      >
        {AUDIO_SOURCES.map((source) => {
          const selected = selectedSource === source.type;
          return (
            <button
              key={source.type}
              type="button"
              role="radio"
              aria-checked={selected}
              disabled={sourceLocked}
              onClick={() => onSelectSource(source.type)}
              className={`flex min-h-24 w-full items-start gap-3 rounded-xl border p-4 text-left transition disabled:cursor-not-allowed disabled:opacity-60 ${
                selected
                  ? "border-brand-primary bg-brand-primary/[0.06] shadow-[0_5px_18px_-12px_rgba(79,95,231,0.45)]"
                  : "border-border-default bg-white hover:border-brand-primary/35 hover:bg-brand-primary/[0.025]"
              }`}
            >
              <span
                className={`mt-0.5 flex size-5 shrink-0 items-center justify-center rounded-full border ${
                  selected
                    ? "border-brand-primary bg-brand-primary text-white"
                    : "border-slate-300 bg-white"
                }`}
                aria-hidden="true"
              >
                {selected ? (
                  <svg
                    viewBox="0 0 16 16"
                    fill="none"
                    stroke="currentColor"
                    strokeWidth="2"
                    className="size-3"
                  >
                    <path d="m4 8 2.5 2.5L12 5" />
                  </svg>
                ) : null}
              </span>
              <span className="min-w-0">
                <span className="flex flex-wrap items-center gap-2 font-display text-base font-semibold text-text-primary">
                  {source.label}
                  {selected ? (
                    <span className="rounded-full bg-brand-primary px-2 py-0.5 font-sans text-[10px] font-semibold uppercase tracking-[0.05em] text-white">
                      Selected
                    </span>
                  ) : null}
                </span>
                <span className="mt-1 block text-sm leading-5 text-text-secondary">
                  {source.description}
                </span>
              </span>
            </button>
          );
        })}
      </div>

      <div className="mt-5 rounded-xl border border-brand-primary/10 bg-brand-primary/[0.04] p-4">
        <p className="text-sm leading-6 text-text-secondary">{privacyCopy}</p>
      </div>

      <div className="mt-5 border-t border-border-default pt-5">
        <HostStatus state={state} showDetail />

        {message ? (
          <p
            className={`mt-4 rounded-lg border px-3 py-2.5 text-sm leading-5 ${
              state === "error"
                ? "border-red-200 bg-red-50 text-[#93000a]"
                : "border-slate-200 bg-slate-50 text-text-secondary"
            }`}
            role={state === "error" ? "alert" : "status"}
          >
            {message}
          </p>
        ) : null}

        {captureInfo ? (
          <dl className="mt-4 grid grid-cols-2 gap-3 rounded-lg bg-slate-50 p-3 text-xs">
            <div>
              <dt className="text-text-secondary">Capture rate</dt>
              <dd className="mt-1 font-semibold text-text-primary">
                {captureInfo.captureSampleRate.toLocaleString()} Hz
              </dd>
            </div>
            <div>
              <dt className="text-text-secondary">PCM output</dt>
              <dd className="mt-1 font-semibold text-text-primary">
                16 kHz mono
              </dd>
            </div>
          </dl>
        ) : null}

        <div className="mt-5 flex flex-col gap-3 sm:flex-row">
          <button
            type="button"
            onClick={onStart}
            disabled={!canStart}
            className="inline-flex min-h-11 flex-1 items-center justify-center gap-2 rounded-lg bg-brand-primary px-5 py-2.5 text-sm font-semibold text-white shadow-sm transition hover:bg-brand-primary-strong disabled:cursor-not-allowed disabled:opacity-45"
          >
            <span aria-hidden="true">▶</span>
            Start Session
          </button>
          <button
            type="button"
            onClick={onStop}
            disabled={!canStop}
            className="inline-flex min-h-11 flex-1 items-center justify-center gap-2 rounded-lg border border-border-default bg-white px-5 py-2.5 text-sm font-semibold text-text-primary transition hover:border-slate-300 hover:bg-slate-50 disabled:cursor-not-allowed disabled:opacity-45"
          >
            <span aria-hidden="true">■</span>
            Stop Session
          </button>
        </div>
      </div>
    </section>
  );
}
