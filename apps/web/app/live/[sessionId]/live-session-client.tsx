"use client";

import { useEffect, useMemo, useState } from "react";

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

  const [status, setStatus] = useState<ViewerConnectionStatus>(
    viewerUrl === null ? "error" : "connecting",
  );
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
    <div className="h-screen w-full flex flex-col bg-surface text-slate-900 overflow-hidden">
      {/* 1. Truthful 64px Desktop Viewer Header */}
      <LiveHeader
        sessionId={sessionId}
        status={status}
        activeConfiguration={activeTranslationConfiguration}
      />

      {/* Non-blocking Reconnect Banner */}
      {status === "reconnecting" && (
        <div
          role="status"
          className="flex-shrink-0 bg-amber-50 border-b border-amber-200 px-6 py-2 text-center text-xs font-medium text-amber-900 flex items-center justify-center gap-2"
        >
          <span className="size-2 rounded-full bg-amber-500 animate-pulse" />
          <span>
            Connection interrupted. Retrying automatically... Existing captions remain visible.
          </span>
        </div>
      )}

      {/* Truthful Connection Error Notice (non-blocking if content exists) */}
      {status === "error" && (
        <div
          role="alert"
          className="flex-shrink-0 bg-rose-50 border-b border-rose-200 px-6 py-2 text-center text-xs font-medium text-rose-800 flex items-center justify-center gap-2"
        >
          <span className="size-2 rounded-full bg-rose-500" />
          <span>
            Could not connect to live caption feed. Please verify the session is active or check your network.
          </span>
        </div>
      )}

      {/* 2. Dominant Center Full-Width Transcript Workspace */}
      <main
        className="flex-1 w-full overflow-hidden flex flex-col"
        data-purpose="viewer-transcript-stream"
      >
        <div className="flex-1 w-full max-w-[1536px] mx-auto px-4 sm:px-6 py-4 flex flex-col overflow-hidden">
          <div className="flex-1 overflow-hidden rounded-xl border border-slate-200 bg-white shadow-xs flex flex-col">
            <TranslationTranscriptPanel
              segments={segments}
              translationState={translationState}
              translationExpected
              streamBadgeLabel="LIVE CAPTIONS"
              sourceBadgeLabel="Live Source"
              emptyTitle="Waiting for live speech…"
              emptyDescription="Captions and translations from the host session will appear here in real time."
            />
          </div>
        </div>
      </main>

      {/* 3. Subtle Receive-Only Footer */}
      <footer
        className="w-full py-2.5 px-6 border-t border-slate-200 bg-white/90 text-center flex-shrink-0 shadow-2xs"
        data-purpose="receive-only-footer"
      >
        <p className="text-xs text-slate-500 font-medium">
          Live captions powered by{" "}
          <span className="text-slate-800 font-semibold">
            AI Live Translator
          </span>{" "}
          · Receive-only stream
        </p>
      </footer>
    </div>
  );
}
