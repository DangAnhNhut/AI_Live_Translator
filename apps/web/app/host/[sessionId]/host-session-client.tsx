"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import { AudioSourcePanel } from "@/components/host/audio-source-panel";
import { HostHeader } from "@/components/host/host-header";
import { HostStatus } from "@/components/host/host-status";
import { TranslationLanguagePanel } from "@/components/host/translation-language-panel";
import { LanguagePair } from "@/components/live/language-pair";
import { TranslationTranscriptPanel } from "@/components/live/translation-transcript-panel";
import type { AudioCaptureInfo, AudioInput } from "@/lib/audio/audio-input";
import { MicrophoneAudioInput } from "@/lib/audio/microphone-audio-input";
import { SystemAudioInput } from "@/lib/audio/system-audio-input";
import {
  canStartHostSession,
  createHostAudioInput,
  createHostAudioSelection,
  getAudioInputErrorMessage,
  lockHostAudioSelection,
  selectHostAudioSource,
  stopHostSession,
  unlockHostAudioSelection,
  type AudioSourceType,
  type HostAudioSelection,
  type HostSessionState,
} from "@/lib/host/host-session";
import {
  createHostTranslationSelection,
  lockHostTranslationSelection,
  selectHostTargetLanguage,
  unlockHostTranslationSelection,
  type HostTranslationSelection,
} from "@/lib/host/host-translation";
import {
  applyTranscriptEvent,
  type TranscriptSegment,
} from "@/lib/realtime/transcript";
import {
  applyTranslationEvent,
  createTranslationState,
  deactivateTranslationConfiguration,
  getActiveTranslationConfiguration,
  type TargetLanguage,
} from "@/lib/realtime/translation";
import {
  buildProducerWebSocketUrl,
  SttProducerClient,
} from "@/lib/stt/producer-client";

type HostSessionClientProps = {
  sessionId: string;
};

type CleanupReason = "deliberate" | "capture-ended" | "error" | "unmount";

export function HostSessionClient({ sessionId }: HostSessionClientProps) {
  const producerUrl = useMemo(() => {
    try {
      return buildProducerWebSocketUrl(process.env.NEXT_PUBLIC_WS_BASE_URL);
    } catch {
      return null;
    }
  }, []);
  const [state, setState] = useState<HostSessionState>("ready");
  const [audioSelection, setAudioSelection] =
    useState<HostAudioSelection>(createHostAudioSelection);
  const [translationSelection, setTranslationSelection] =
    useState<HostTranslationSelection>(createHostTranslationSelection);
  const [translationState, setTranslationState] = useState(
    createTranslationState,
  );
  const [segments, setSegments] = useState<readonly TranscriptSegment[]>([]);
  const [captureInfo, setCaptureInfo] = useState<AudioCaptureInfo | null>(null);
  const [message, setMessage] = useState<string | null>(null);
  const audioInputRef = useRef<AudioInput | null>(null);
  const producerRef = useRef<SttProducerClient | null>(null);
  const cleanupPromiseRef = useRef<Promise<void> | null>(null);
  const operationRef = useRef(0);
  const mountedRef = useRef(true);

  const cleanupSession = useCallback(
    (reason: CleanupReason, errorMessage?: string): Promise<void> => {
      if (cleanupPromiseRef.current !== null) {
        return cleanupPromiseRef.current;
      }

      operationRef.current += 1;
      const input = audioInputRef.current;
      const producer = producerRef.current;

      const cleanup = async () => {
        if (mountedRef.current && reason !== "unmount") {
          setState("stopping");
        }

        // Input stops first so a safe partial PCM block can reach a live
        // producer before its clean stt.stop sequence begins.
        await stopHostSession(input, producer);

        if (audioInputRef.current === input) {
          audioInputRef.current = null;
        }
        if (producerRef.current === producer) {
          producerRef.current = null;
        }

        if (process.env.NODE_ENV === "development" && producer !== null) {
          const diagnostics = producer.getDiagnostics();
          console.debug("[host-audio] producer stopped", diagnostics);
        }

        if (!mountedRef.current || reason === "unmount") {
          return;
        }

        setCaptureInfo(null);
        setTranslationState((current) =>
          deactivateTranslationConfiguration(current),
        );
        setAudioSelection((current) => unlockHostAudioSelection(current));
        setTranslationSelection((current) =>
          unlockHostTranslationSelection(current),
        );
        if (reason === "error") {
          setMessage(
            errorMessage ??
              "The live speech session ended. Select Start Session to try again.",
          );
          setState("error");
        } else {
          setMessage(
            reason === "capture-ended"
              ? "Audio capture ended. Start a new session when you are ready."
              : null,
          );
          setState("ready");
        }
      };

      const promise = cleanup().finally(() => {
        if (cleanupPromiseRef.current === promise) {
          cleanupPromiseRef.current = null;
        }
      });
      cleanupPromiseRef.current = promise;
      return promise;
    },
    [],
  );

  const startSession = useCallback(async () => {
    const selectedSource = audioSelection.selectedSource;
    const selectedTarget = translationSelection.targetLanguage;
    if (
      producerUrl === null ||
      !canStartHostSession(state, audioSelection) ||
      selectedSource === null ||
      cleanupPromiseRef.current !== null
    ) {
      if (producerUrl === null) {
        setMessage("The speech service address is not configured correctly.");
        setState("error");
      }
      return;
    }

    const operation = operationRef.current + 1;
    operationRef.current = operation;
    setSegments([]);
    setTranslationState(createTranslationState());
    setCaptureInfo(null);
    setMessage(null);
    setAudioSelection((current) => lockHostAudioSelection(current));
    setTranslationSelection((current) =>
      lockHostTranslationSelection(current),
    );
    setState("requesting_permission");

    const input = createHostAudioInput(selectedSource, {
      microphone: () => new MicrophoneAudioInput(),
      system: () => new SystemAudioInput(),
    });
    audioInputRef.current = input;
    let captureReady = false;

    try {
      const info = await input.start({
        onPcmChunk: (chunk) => {
          producerRef.current?.sendPcmChunk(chunk);
        },
        onEnded: () => {
          void cleanupSession("capture-ended");
        },
      });

      if (!mountedRef.current || operationRef.current !== operation) {
        await input.stop();
        return;
      }

      captureReady = true;
      setCaptureInfo(info);
      if (process.env.NODE_ENV === "development") {
        console.debug("[host-audio] capture ready", {
          captureSampleRate: info.captureSampleRate,
          channelCount: info.channelCount,
          targetSampleRate: info.targetSampleRate,
        });
      }
      setState("connecting");

      const producer = new SttProducerClient({
        url: producerUrl,
        sessionId,
        translation: { targetLanguage: selectedTarget },
        onStatus: (nextStatus) => {
          if (!mountedRef.current || operationRef.current !== operation) {
            return;
          }
          if (nextStatus === "live") {
            setState("live");
          } else if (nextStatus === "connecting") {
            setState("connecting");
          }
        },
        onTranscript: (event) => {
          if (mountedRef.current && operationRef.current === operation) {
            setSegments((current) => applyTranscriptEvent(current, event));
          }
        },
        onTranslation: (event) => {
          if (mountedRef.current && operationRef.current === operation) {
            setTranslationState((current) =>
              applyTranslationEvent(current, event),
            );
          }
        },
        onError: (safeMessage) => {
          if (mountedRef.current && operationRef.current === operation) {
            void cleanupSession("error", safeMessage);
          }
        },
      });
      producerRef.current = producer;
      await producer.start();
    } catch (error) {
      if (mountedRef.current && operationRef.current === operation) {
        const safeMessage =
          !captureReady
            ? getAudioInputErrorMessage(selectedSource, error)
            : "The speech service could not start. Check the backend and try again.";
        await cleanupSession("error", safeMessage);
      }
    }
  }, [
    audioSelection,
    cleanupSession,
    producerUrl,
    sessionId,
    state,
    translationSelection.targetLanguage,
  ]);

  const selectAudioSource = useCallback((source: AudioSourceType) => {
    setAudioSelection((current) => selectHostAudioSource(current, source));
  }, []);

  const selectTargetLanguage = useCallback((target: TargetLanguage) => {
    setTranslationSelection((current) =>
      selectHostTargetLanguage(current, target),
    );
  }, []);

  const stopSession = useCallback(() => {
    void cleanupSession("deliberate");
  }, [cleanupSession]);

  useEffect(() => {
    mountedRef.current = true;
    return () => {
      mountedRef.current = false;
      void cleanupSession("unmount");
    };
  }, [cleanupSession]);

  const activeTranslationConfiguration =
    getActiveTranslationConfiguration(translationState);

  return (
    <div className="min-h-screen bg-background text-text-primary">
      <HostHeader />
      <main className="relative overflow-hidden">
        <div
          aria-hidden="true"
          className="pointer-events-none absolute inset-x-0 top-0 h-[440px] bg-[radial-gradient(circle_at_90%_0%,rgba(79,95,231,0.12),transparent_52%),radial-gradient(circle_at_0%_75%,rgba(116,86,232,0.08),transparent_46%)]"
        />
        <div className="relative mx-auto w-full max-w-[1280px] px-4 py-8 sm:px-8 sm:py-12 lg:px-12">
          <section className="mb-8 flex flex-col gap-5 md:flex-row md:items-end md:justify-between">
            <div className="max-w-2xl">
              <p className="text-xs font-semibold uppercase tracking-[0.05em] text-brand-primary">
                Web audio host
              </p>
              <h1 className="mt-3 font-display text-3xl font-bold tracking-[-0.02em] text-text-primary sm:text-4xl">
                Turn audio into live captions
              </h1>
              <p className="mt-3 text-base leading-7 text-text-secondary sm:text-lg">
                Use this device&apos;s microphone or share browser playback, then
                follow the transcript while viewers receive the same session.
              </p>
            </div>
            <HostStatus state={state} />
          </section>

          <div className="grid items-start gap-6 lg:grid-cols-[320px_minmax(0,1fr)]">
            <aside className="grid gap-4">
              <AudioSourcePanel
                state={state}
                selectedSource={audioSelection.selectedSource}
                sourceLocked={audioSelection.locked}
                canStart={canStartHostSession(state, audioSelection)}
                captureInfo={captureInfo}
                message={message}
                onSelectSource={selectAudioSource}
                onStart={() => void startSession()}
                onStop={stopSession}
              />

              <TranslationLanguagePanel
                selection={translationSelection}
                activeConfiguration={activeTranslationConfiguration}
                onTargetChange={selectTargetLanguage}
              />

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
                    <dt className="sr-only">Active Translation languages</dt>
                    <dd>
                      <LanguagePair
                        configuration={activeTranslationConfiguration}
                      />
                    </dd>
                  </div>
                  <div className="border-t border-border-default pt-4">
                    <dt className="text-xs font-semibold uppercase tracking-[0.05em] text-text-secondary">
                      Audio handling
                    </dt>
                    <dd className="mt-1 text-sm leading-6 text-text-primary">
                      Transient streaming only; no recording or playback.
                    </dd>
                  </div>
                </dl>
              </section>
            </aside>

            <section
              aria-label="Host transcript workspace"
              className="overflow-hidden rounded-2xl border border-border-default bg-white shadow-[0_10px_30px_-16px_rgba(17,24,39,0.16)]"
            >
              <div className="flex min-h-16 flex-wrap items-center justify-between gap-4 border-b border-border-default bg-white px-4 py-3 sm:px-6">
                <div>
                  <p className="font-display text-sm font-semibold text-text-primary sm:text-base">
                    Host transcript
                  </p>
                  <p className="mt-0.5 max-w-[55vw] truncate font-mono text-xs text-text-secondary sm:max-w-none">
                    {sessionId}
                  </p>
                </div>
                <HostStatus state={state} />
              </div>
              <TranslationTranscriptPanel
                segments={segments}
                translationState={translationState}
                translationExpected
                emptyTitle={
                  audioSelection.selectedSource === "microphone"
                    ? "Waiting for microphone speech…"
                    : audioSelection.selectedSource === "system"
                      ? "Waiting for System Audio…"
                      : "Choose an audio source"
                }
                emptyDescription="Select a source and start the session. Recognized speech will appear here."
              />
            </section>
          </div>
        </div>
      </main>
    </div>
  );
}
