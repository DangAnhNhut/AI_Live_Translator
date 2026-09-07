import Link from "next/link";

type HostSidebarProps = {
  sessionId: string;
  isLive?: boolean;
};

export function HostSidebar({ sessionId, isLive = false }: HostSidebarProps) {
  return (
    <aside
      aria-label="Application navigation"
      className="hidden w-64 flex-shrink-0 flex-col justify-between border-r border-slate-200 bg-white md:flex"
    >
      <div className="flex flex-col p-5">
        {/* Brand Header */}
        <Link
          href="/"
          className="flex items-center gap-3 border-b border-slate-100 pb-5 transition hover:opacity-90"
        >
          <div
            className="flex size-9 flex-shrink-0 items-center justify-center rounded-xl bg-brand-primary text-white shadow-sm"
            aria-hidden="true"
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
              <path d="m5 8 6 6" />
              <path d="m4 14 6-6 2-3" />
              <path d="M2 5h12" />
              <path d="M7 2h1" />
              <path d="m22 22-5-10-5 10" />
              <path d="M14 18h6" />
            </svg>
          </div>
          <div className="min-w-0">
            <span className="block truncate font-display text-base font-bold tracking-tight text-slate-900">
              AI Live Translator
            </span>
            <span className="block text-[11px] font-medium text-slate-400">
              Web Audio Workspace
            </span>
          </div>
        </Link>

        {/* Navigation */}
        <nav className="mt-6 flex flex-col gap-1.5" aria-label="Session modes">
          <p className="px-2 text-[11px] font-bold uppercase tracking-wider text-slate-400">
            Session Mode
          </p>

          <div
            aria-current="page"
            className="flex items-center justify-between rounded-xl bg-brand-primary px-3.5 py-2.5 text-sm font-semibold text-white shadow-sm"
          >
            <div className="flex items-center gap-3">
              <svg
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                strokeLinecap="round"
                strokeLinejoin="round"
                className="size-4.5"
                aria-hidden="true"
              >
                <path d="M12 2a3 3 0 0 0-3 3v7a3 3 0 0 0 6 0V5a3 3 0 0 0-3-3Z" />
                <path d="M19 10v2a7 7 0 0 1-14 0v-2" />
                <line x1="12" x2="12" y1="19" y2="22" />
              </svg>
              <span>Live Host</span>
            </div>
            {isLive ? (
              <span className="relative flex size-2">
                <span className="absolute inline-flex h-full w-full animate-ping rounded-full bg-emerald-300 opacity-75" />
                <span className="relative inline-flex size-2 rounded-full bg-emerald-400" />
              </span>
            ) : (
              <span className="size-2 rounded-full bg-white/40" />
            )}
          </div>

          <Link
            href={`/live/${sessionId}`}
            target="_blank"
            rel="noopener noreferrer"
            className="flex items-center justify-between rounded-xl px-3.5 py-2.5 text-sm font-medium text-slate-600 transition hover:bg-slate-50 hover:text-slate-900"
          >
            <div className="flex items-center gap-3">
              <svg
                viewBox="0 0 24 24"
                fill="none"
                stroke="currentColor"
                strokeWidth="2"
                strokeLinecap="round"
                strokeLinejoin="round"
                className="size-4.5 text-slate-400"
                aria-hidden="true"
              >
                <path d="M2 12s3-7 10-7 10 7 10 7-3 7-10 7-10-7-10-7Z" />
                <circle cx="12" cy="12" r="3" />
              </svg>
              <span>Live Viewer</span>
            </div>
            <svg
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth="2"
              strokeLinecap="round"
              strokeLinejoin="round"
              className="size-3.5 text-slate-400"
              aria-hidden="true"
            >
              <path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6" />
              <polyline points="15 3 21 3 21 9" />
              <line x1="10" x2="21" y1="14" y2="3" />
            </svg>
          </Link>
        </nav>
      </div>

      {/* Footer */}
      <div className="border-t border-slate-100 p-4">
        <Link
          href="/"
          className="flex items-center gap-2 rounded-lg px-2.5 py-2 text-xs font-medium text-slate-500 transition hover:bg-slate-50 hover:text-slate-800"
        >
          <svg
            viewBox="0 0 24 24"
            fill="none"
            stroke="currentColor"
            strokeWidth="2"
            strokeLinecap="round"
            strokeLinejoin="round"
            className="size-4 text-slate-400"
            aria-hidden="true"
          >
            <path d="m3 9 9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z" />
            <polyline points="9 22 9 12 15 12 15 22" />
          </svg>
          <span>Return Home</span>
        </Link>
      </div>
    </aside>
  );
}
