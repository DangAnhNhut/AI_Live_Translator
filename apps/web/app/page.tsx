import Link from "next/link";
import { HomeLaunchpad } from "@/components/home/home-launchpad";

export default function HomePage() {
  return (
    <div className="min-h-screen bg-surface-background text-text-primary flex flex-col justify-between selection:bg-brand-primary/15 selection:text-brand-primary-strong">
      {/* Top Product Header */}
      <header className="sticky top-0 z-30 w-full border-b border-slate-200/80 bg-white/90 backdrop-blur-md shadow-[0_1px_2px_rgba(0,0,0,0.02)]">
        <div className="max-w-6xl mx-auto px-4 sm:px-6 lg:px-8 h-16 flex items-center justify-between">
          <Link
            href="/"
            className="flex items-center gap-3 transition-opacity hover:opacity-90"
          >
            <div
              className="size-9 rounded-xl bg-brand-primary text-white flex items-center justify-center shadow-sm shadow-brand-primary/25 shrink-0"
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
            <div className="flex flex-col">
              <span className="font-display font-bold text-base text-slate-900 tracking-tight leading-tight">
                AI Live Translator
              </span>
              <span className="text-[11px] font-medium text-text-secondary leading-none">
                Bilingual Workstation
              </span>
            </div>
          </Link>

        </div>
      </header>

      {/* Main Launchpad Container */}
      <main className="flex-1 max-w-5xl w-full mx-auto px-4 sm:px-6 lg:px-8 pt-5 pb-8 sm:pt-6 sm:pb-10 flex flex-col justify-center">
        <HomeLaunchpad />
      </main>

      {/* Minimal Product Footer */}
      <footer className="w-full border-t border-slate-200/80 bg-white/70 py-6 px-4 text-center text-xs text-text-secondary">
        <div className="max-w-6xl mx-auto flex flex-col sm:flex-row items-center justify-between gap-2 text-[12px]">
          <span>AI Live Translator</span>
          <span className="text-slate-400">Realtime Speech Translation</span>
        </div>
      </footer>
    </div>
  );
}
