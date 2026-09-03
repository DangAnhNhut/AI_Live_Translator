import type { TranscriptBlock as Block } from "@/lib/realtime/transcript-blocks";

type TranscriptBlockProps = {
  block: Block;
};

export function TranscriptBlock({ block }: TranscriptBlockProps) {
  const isInterim = block.kind === "interim";

  return (
    <li className="flex gap-3 sm:gap-4">
      <div
        aria-hidden="true"
        className={`mt-0.5 flex size-9 shrink-0 items-center justify-center rounded-xl text-white shadow-sm sm:size-10 ${
          isInterim ? "bg-brand-primary" : "bg-brand-accent"
        }`}
      >
        <svg
          viewBox="0 0 24 24"
          fill="none"
          stroke="currentColor"
          strokeWidth="2"
          strokeLinecap="round"
          strokeLinejoin="round"
          className="size-5"
        >
          <path d="M4 12v2a4 4 0 0 0 4 4h1" />
          <path d="M15 10v4" />
          <path d="M12 8v8" />
          <path d="M9 10v4" />
          <path d="M18 8v8" />
        </svg>
      </div>

      <div
        className={`min-w-0 flex-1 rounded-2xl border px-4 py-3.5 sm:px-5 sm:py-4 ${
          isInterim
            ? "border-brand-primary/25 bg-brand-primary/[0.045] shadow-[0_4px_20px_-8px_rgba(79,95,231,0.2)]"
            : "border-border-default bg-white"
        }`}
      >
        <div className="mb-1.5 flex flex-wrap items-center gap-x-2 gap-y-1 text-xs font-semibold uppercase tracking-[0.05em]">
          <span className="text-text-secondary">Speech</span>
          <span aria-hidden="true" className="text-slate-300">
            •
          </span>
          <span className={isInterim ? "text-brand-primary" : "text-slate-500"}>
            {isInterim ? "Listening…" : "Final"}
          </span>
          {block.language ? (
            <span className="ml-auto normal-case tracking-normal text-slate-400">
              {block.language.toUpperCase()}
            </span>
          ) : null}
        </div>
        <p
          className={`break-words text-[16px] leading-6 text-text-primary sm:text-[18px] sm:leading-7 ${
            isInterim ? "opacity-80" : ""
          }`}
        >
          {block.text}
        </p>
      </div>
    </li>
  );
}
