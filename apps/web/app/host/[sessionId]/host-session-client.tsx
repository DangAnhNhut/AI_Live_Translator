"use client";

import { useCallback, useEffect, useMemo, useRef, useState } from "react";

import { HostHeader } from "@/components/host/host-header";
import { HostReadyCanvas } from "@/components/host/host-ready-canvas";
import { HostRightPanel } from "@/components/host/host-right-panel";
import { HostSidebar } from "@/components/host/host-sidebar";
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
  const [elapsedSeconds, setElapsedSeconds] = useState(0);

  const audioInputRef = useRef<AudioInput | null>(null);
  const producerRef = useRef<SttProducerClient | null>(null);
  const cleanupPromiseRef = useRef<Promise<void> | null>(null);
  const operationRef = useRef(0);
  const mountedRef = useRef(true);

  const sessionStartTimeRef = useRef<number | null>(null);

  // Presentation-only local elapsed timer
  useEffect(() => {
    if (state !== "live") {
      sessionStartTimeRef.current = null;
      return;
    }
    sessionStartTimeRef.current = Date.now();
    const interval = window.setInterval(() => {
      if (sessionStartTimeRef.current !== null) {
        setElapsedSeconds(
          Math.floor((Date.now() - sessionStartTimeRef.current) / 1000),
        );
      }
    }, 1000);
    return () => window.clearInterval(interval);
  }, [state]);

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
    setElapsedSeconds(0);
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

  const isReadyEmptyState =
    state === "ready" &&
    segments.length === 0 &&
    translationState.utterances.length === 0;

  return (
    <div className="h-screen w-screen overflow-hidden flex flex-row bg-surface text-slate-900 select-none">
      {/* 1. Left Persistent Minimal Product Rail */}
      <HostSidebar sessionId={sessionId} isLive={state === "live"} />

      {/* 2. Main Desktop Workstation Workspace */}
      <div className="flex-1 h-full flex flex-col min-w-0 overflow-hidden bg-surface">
        {/* Top 64px Session Header */}
        <HostHeader
          sessionId={sessionId}
          state={state}
          selectedSource={audioSelection.selectedSource}
          targetLanguage={translationSelection.targetLanguage}
          elapsedSeconds={elapsedSeconds}
        />

        {/* Center Workspace (Ready Canvas vs Live Split Workspace) */}
        <main className="flex-1 h-full overflow-hidden flex flex-col">
          {isReadyEmptyState ? (
            <HostReadyCanvas
              selectedSource={audioSelection.selectedSource}
              targetLanguage={translationSelection.targetLanguage}
              canStart={canStartHostSession(state, audioSelection)}
              onStart={() => void startSession()}
              message={message}
              state={state}
            />
          ) : (
            <TranslationTranscriptPanel
              segments={segments}
              translationState={translationState}
              translationExpected
              emptyTitle={
                audioSelection.selectedSource === "microphone"
                  ? "Waiting for microphone speech…"
                  : "Waiting for System Audio…"
              }
              emptyDescription="Speech will appear in real time and translate into your chosen target language."
            />
          )}
        </main>
      </div>

      {/* 3. Right 340px Docked Session Control Panel */}
      <HostRightPanel
        sessionId={sessionId}
        state={state}
        selectedSource={audioSelection.selectedSource}
        sourceLocked={audioSelection.locked}
        canStart={canStartHostSession(state, audioSelection)}
        captureInfo={captureInfo}
        message={message}
        onSelectSource={selectAudioSource}
        onStart={() => void startSession()}
        onStop={stopSession}
        targetLanguage={translationSelection.targetLanguage}
        targetLocked={translationSelection.locked}
        onTargetChange={selectTargetLanguage}
        activeConfiguration={activeTranslationConfiguration}
      />
    </div>
  );
}
