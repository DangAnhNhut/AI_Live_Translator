import {
  getHostStatusContent,
  type HostSessionState,
} from "@/lib/host/host-session";

type HostStatusProps = {
  state: HostSessionState;
  showDetail?: boolean;
};

const STATUS_STYLES: Record<HostSessionState, string> = {
  ready: "border-slate-200 bg-slate-50 text-slate-600",
  requesting_permission:
    "border-brand-primary/20 bg-brand-primary/[0.06] text-brand-primary-strong",
  connecting:
    "border-brand-primary/20 bg-brand-primary/[0.06] text-brand-primary-strong",
  live: "border-green-200 bg-green-50 text-green-700",
  stopping: "border-amber-200 bg-amber-50 text-amber-700",
  error: "border-red-200 bg-red-50 text-state-error",
};

export function HostStatus({ state, showDetail = false }: HostStatusProps) {
  const content = getHostStatusContent(state);

  return (
    <div role="status" aria-live="polite" className="min-w-0">
      <div
        className={`inline-flex items-center gap-2 rounded-full border px-3 py-1.5 text-xs font-semibold uppercase tracking-[0.05em] ${STATUS_STYLES[state]}`}
      >
        <span
          className={`size-2 rounded-full ${state === "live" ? "bg-state-live motion-safe:animate-pulse" : "bg-current opacity-65"}`}
          aria-hidden="true"
        />
        {content.label}
      </div>
      {showDetail ? (
        <p className="mt-3 text-sm leading-6 text-text-secondary">
          {content.detail}
        </p>
      ) : null}
    </div>
  );
}
