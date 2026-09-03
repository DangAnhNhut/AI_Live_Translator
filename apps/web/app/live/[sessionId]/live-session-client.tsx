"use client";

import { useEffect, useMemo, useState } from "react";

import { ConnectionStatus } from "@/components/live/connection-status";
import { LanguagePair } from "@/components/live/language-pair";
import { LiveHeader } from "@/components/live/live-header";
import { TranslationTranscriptPanel } from "@/components/live/translation-transcript-panel";
import {
  applyTranscriptEvent,
  type TranscriptSegment,
} from "@/lib/realtime/transcript";
import {
  applyTranslationEvent,
  createTranslationState,
  deactivateTranslationConfiguration,
  getActiveTranslationConfiguration,
} from "@/lib/realtime/translation";
import {
  buildViewerWebSocketUrl,
  ViewerSocketClient,
  type ViewerConnectionStatus,
} from "@/lib/realtime/viewer-socket";

type LiveSessionClientProps = {
  sessionId: string;
};

export function LiveSessionClient({ sessionId }: LiveSessionClientProps) {
  const viewerUrl = useMemo(() => {
    try {
      return buildViewerWebSocketUrl(
        process.env.NEXT_PUBLIC_WS_BASE_URL,
        sessionId,
      );
    } catch {
      return null;
    }
  }, [sessionId]);
  const [status, setStatus] =
    useState<ViewerConnectionStatus>(viewerUrl === null ? "error" : "connecting");
  const [segments, setSegments] = useState<readonly TranscriptSegment[]>([]);
  const [translationState, setTranslationState] = useState(
    createTranslationState,
  );

  useEffect(() => {
    let active = true;
    if (viewerUrl === null) {
      return;
    }

    const client = new ViewerSocketClient({
      url: viewerUrl,
      onStatus: (nextStatus) => {
        if (active) {
          setStatus(nextStatus);
        }
      },
      onTranscript: (event) => {
        if (active) {
          if (event.stream_id !== undefined) {
            setTranslationState((current) =>
              deactivateTranslationConfiguration(current, event.stream_id),
            );
          }
          setSegments((current) => applyTranscriptEvent(current, event));
        }
      },
      onTranslation: (event) => {
        if (active) {
          setTranslationState((current) =>
            applyTranslationEvent(current, event),
          );
        }
      },
    });

    client.start();

    return () => {
      active = false;
      client.stop();
    };
  }, [viewerUrl]);

  const activeTranslationConfiguration =
    getActiveTranslationConfiguration(translationState);

  return (
    <div className="min-h-screen bg-background text-text-primary">
      <LiveHeader />

      <main className="relative overflow-hidden">
        <div
          aria-hidden="true"
          className="pointer-events-none absolute inset-x-0 top-0 h-[420px] bg-[radial-gradient(circle_at_90%_0%,rgba(79,95,231,0.10),transparent_52%),radial-gradient(circle_at_0%_75%,rgba(116,86,232,0.08),transparent_46%)]"
        />

        <div className="relative mx-auto w-full max-w-[1280px] px-4 py-8 sm:px-8 sm:py-12 lg:px-12">
          <section className="mb-8 flex flex-col gap-5 md:flex-row md:items-end md:justify-between">
            <div className="max-w-2xl">
              <p className="text-xs font-semibold uppercase tracking-[0.05em] text-brand-primary">
                Receive-only live session
              </p>
              <h1 className="mt-3 font-display text-3xl font-bold tracking-[-0.02em] text-text-primary sm:text-4xl">
                Follow the conversation in real time
              </h1>
              <p className="mt-3 text-base leading-7 text-text-secondary sm:text-lg">
                Live captions from the connected mobile speaker appear here as
                they are recognized.
              </p>
            </div>
            <ConnectionStatus status={status} announce />
          </section>

          <div className="grid items-start gap-6 lg:grid-cols-[minmax(0,1fr)_280px]">
            <section
              aria-label="Live caption workspace"
              className="overflow-hidden rounded-2xl border border-border-default bg-white shadow-[0_10px_30px_-16px_rgba(17,24,39,0.16)]"
            >
              <div className="flex min-h-16 flex-wrap items-center justify-between gap-4 border-b border-border-default bg-white px-4 py-3 sm:px-6">
                <div className="flex items-center gap-4">
                  <div className="hidden gap-2 sm:flex" aria-hidden="true">
                    <span className="size-3 rounded-full bg-slate-200" />
                    <span className="size-3 rounded-full bg-slate-200" />
                    <span className="size-3 rounded-full bg-slate-200" />
                  </div>
                  <div className="hidden h-7 w-px bg-border-default sm:block" />
                  <div>
                    <p className="font-display text-sm font-semibold text-text-primary sm:text-base">
                      Live Session
                    </p>
                    <p className="mt-0.5 max-w-[42vw] truncate font-mono text-xs text-text-secondary sm:max-w-none">
                      {sessionId}
                    </p>
                  </div>
                </div>
                <ConnectionStatus status={status} />
              </div>

              <TranslationTranscriptPanel
                segments={segments}
                translationState={translationState}
                translationExpected={false}
              />
            </section>

            <aside className="grid gap-4 sm:grid-cols-2 lg:grid-cols-1">
              <section className="rounded-2xl border border-border-default bg-white p-5 shadow-[0_10px_24px_-20px_rgba(17,24,39,0.18)]">
                <h2 className="font-display text-lg font-semibold text-text-primary">
                  Session details
                </h2>
                <dl className="mt-5 space-y-4">
                  <div>
                    <dt className="text-xs font-semibold uppercase tracking-[0.05em] text-text-secondary">
                      Session ID
                    </dt>
                    <dd className="mt-1 break-all font-mono text-sm font-medium text-text-primary">
                      {sessionId}
                    </dd>
                  </div>
                  <div className="border-t border-border-default pt-4">
                    <dt className="text-xs font-semibold uppercase tracking-[0.05em] text-text-secondary">
                      Source speech
                    </dt>
                    <dd className="mt-1 text-sm font-medium text-text-primary">
                      Vietnamese
                    </dd>
                  </div>
                  <div className="border-t border-border-default pt-4">
                    <dt className="sr-only">Translation languages</dt>
                    <dd>
                      <LanguagePair
                        configuration={activeTranslationConfiguration}
                      />
                    </dd>
                  </div>
                  <div className="border-t border-border-default pt-4">
                    <dt className="text-xs font-semibold uppercase tracking-[0.05em] text-text-secondary">
                      Access
                    </dt>
                    <dd className="mt-1 text-sm font-medium text-text-primary">
                      Receive only
                    </dd>
                  </div>
                </dl>
              </section>

              <section className="rounded-2xl border border-border-default bg-white p-5 shadow-[0_10px_24px_-20px_rgba(17,24,39,0.18)]">
                <h2 className="font-display text-lg font-semibold text-text-primary">
                  Connection
                </h2>
                <div className="mt-4">
                  <ConnectionStatus status={status} showDetail />
                </div>
                <p className="mt-4 border-t border-border-default pt-4 text-xs leading-5 text-text-secondary">
                  Captions already received stay visible during reconnects. Speech
                  missed while disconnected cannot be replayed in this version.
                </p>
              </section>
            </aside>
          </div>
        </div>
      </main>
    </div>
  );
}
