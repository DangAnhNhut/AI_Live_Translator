import type { ViewerConnectionStatus } from "@/lib/realtime/viewer-socket";

const STATUS_CONTENT: Record<
  ViewerConnectionStatus,
  { label: string; detail: string; className: string; dotClassName: string }
> = {
  connecting: {
    label: "Connecting",
    detail: "Opening the live caption feed.",
    className: "border-slate-200 bg-slate-50 text-slate-700",
    dotClassName: "bg-slate-400 animate-pulse",
  },
  live: {
    label: "LIVE",
    detail: "Captions are arriving in real time.",
    className: "border-green-200 bg-green-50 text-green-700",
    dotClassName: "bg-state-live animate-pulse",
  },
  reconnecting: {
    label: "Reconnecting",
    detail: "Connection interrupted. Retrying automatically.",
    className: "border-amber-200 bg-amber-50 text-amber-800",
    dotClassName: "bg-amber-500 animate-pulse",
  },
  disconnected: {
    label: "Disconnected",
    detail: "The live caption feed is disconnected.",
    className: "border-slate-200 bg-slate-50 text-slate-700",
    dotClassName: "bg-slate-400",
  },
  error: {
    label: "Connection error",
    detail: "We couldn’t reach the live caption feed.",
    className: "border-red-200 bg-red-50 text-state-error",
    dotClassName: "bg-state-error",
  },
};

type ConnectionStatusProps = {
  status: ViewerConnectionStatus;
  showDetail?: boolean;
  announce?: boolean;
};

export function ConnectionStatus({
  status,
  showDetail = false,
  announce = false,
}: ConnectionStatusProps) {
  const content = STATUS_CONTENT[status];

  return (
    <div
      role={announce ? "status" : undefined}
      aria-live={announce ? "polite" : undefined}
      aria-atomic={announce ? "true" : undefined}
    >
      <div
        className={`inline-flex items-center gap-2 rounded-full border px-3 py-1.5 text-xs font-bold uppercase tracking-[0.05em] ${content.className}`}
      >
        <span
          aria-hidden="true"
          className={`size-2.5 rounded-full ${content.dotClassName}`}
        />
        {content.label}
      </div>
      {showDetail ? (
        <p className="mt-3 text-sm leading-5 text-text-secondary">
          {content.detail}
        </p>
      ) : null}
    </div>
  );
}
