"use client";

import { useEffect, useMemo, useRef } from "react";

import type { TranscriptSegment as Segment } from "@/lib/realtime/transcript";
import { groupTranscriptSegments } from "@/lib/realtime/transcript-blocks";

import { TranscriptBlock } from "./transcript-block";

type TranscriptPanelProps = {
  segments: readonly Segment[];
  emptyTitle?: string;
  emptyDescription?: string;
};

export function TranscriptPanel({
  segments,
  emptyTitle = "Waiting for speech…",
  emptyDescription =
    "Captions will appear here when the connected mobile speaker starts talking.",
}: TranscriptPanelProps) {
  const endRef = useRef<HTMLDivElement>(null);
  const blocks = useMemo(() => groupTranscriptSegments(segments), [segments]);
  const latestText = blocks.at(-1)?.text;

  useEffect(() => {
    if (blocks.length === 0) {
      return;
    }

    const timer = window.setTimeout(() => {
      endRef.current?.scrollIntoView({
        behavior: "smooth",
        block: "end",
      });
    }, 120);

    return () => window.clearTimeout(timer);
  }, [blocks.length, latestText]);

  return (
    <div className="flex min-h-[420px] flex-1 flex-col overflow-hidden bg-[#fbfbff] sm:min-h-[500px] lg:max-h-[620px]">
      <div className="flex flex-wrap items-center justify-between gap-3 border-b border-border-default/70 bg-white/75 px-4 py-3 backdrop-blur-sm sm:px-6">
        <div>
          <p className="text-xs font-semibold uppercase tracking-[0.05em] text-text-secondary">
            Live transcript
          </p>
          <p className="mt-0.5 text-sm font-semibold text-text-primary">
            Vietnamese speech
          </p>
        </div>
        <div className="flex h-7 items-end gap-1" aria-hidden="true">
          {[45, 75, 55, 100, 65, 85, 40].map((height, index) => (
            <span
              key={height + index}
              className="w-1 rounded-full bg-brand-primary/70 motion-safe:animate-pulse"
              style={{ height: `${height}%`, animationDelay: `${index * 90}ms` }}
            />
          ))}
        </div>
      </div>

      <div
        className="flex-1 overflow-y-auto px-4 py-6 sm:px-6 sm:py-8"
        aria-live="polite"
        aria-relevant="additions text"
      >
        {blocks.length === 0 ? (
          <div className="flex min-h-[330px] flex-col items-center justify-center text-center sm:min-h-[390px]">
            <div className="flex size-16 items-center justify-center rounded-2xl border border-brand-primary/15 bg-brand-primary/[0.06] text-brand-primary">
              <svg
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="1.8"
                strokeLinecap="round"
                strokeLinejoin="round"
                className="size-8"
                aria-hidden="true"
              >
                <path d="M4 12v2a4 4 0 0 0 4 4h1" />
                <path d="M15 10v4" />
                <path d="M12 7v10" />
                <path d="M9 10v4" />
                <path d="M18 8v8" />
              </svg>
            </div>
            <h2 className="mt-5 font-display text-xl font-semibold text-text-primary">
              {emptyTitle}
            </h2>
            <p className="mt-2 max-w-sm text-sm leading-6 text-text-secondary">
              {emptyDescription}
            </p>
          </div>
        ) : (
          <ol className="space-y-6">
            {blocks.map((block) => (
              <TranscriptBlock key={block.id} block={block} />
            ))}
          </ol>
        )}
        <div ref={endRef} aria-hidden="true" />
      </div>
    </div>
  );
}
