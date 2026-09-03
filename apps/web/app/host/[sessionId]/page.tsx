import type { Metadata } from "next";

import { HostHeader } from "@/components/host/host-header";
import { isValidSessionId } from "@/lib/realtime/socket-url";

import { HostSessionClient } from "./host-session-client";

type HostSessionPageProps = {
  params: Promise<{ sessionId: string }>;
};

export const metadata: Metadata = {
  title: "Host Session",
};

export default async function HostSessionPage({
  params,
}: HostSessionPageProps) {
  const { sessionId } = await params;

  if (!isValidSessionId(sessionId)) {
    return <InvalidHostSession />;
  }

  return <HostSessionClient key={sessionId} sessionId={sessionId} />;
}

function InvalidHostSession() {
  return (
    <div className="min-h-screen bg-background text-text-primary">
      <HostHeader />
      <main className="mx-auto flex w-full max-w-[1280px] items-center justify-center px-4 py-16 sm:px-8 lg:px-12">
        <section className="w-full max-w-xl rounded-2xl border border-red-200 bg-white p-8 text-center shadow-[0_10px_30px_-16px_rgba(17,24,39,0.16)] sm:p-12">
          <div className="mx-auto flex size-14 items-center justify-center rounded-2xl bg-red-50 text-state-error">
            <svg
              viewBox="0 0 24 24"
              fill="none"
              stroke="currentColor"
              strokeWidth="2"
              strokeLinecap="round"
              strokeLinejoin="round"
              className="size-7"
              aria-hidden="true"
            >
              <circle cx="12" cy="12" r="9" />
              <path d="M12 7v6" />
              <path d="M12 17h.01" />
            </svg>
          </div>
          <p className="mt-5 text-xs font-semibold uppercase tracking-[0.05em] text-state-error">
            Invalid host link
          </p>
          <h1 className="mt-3 font-display text-2xl font-semibold text-text-primary sm:text-3xl">
            This host session ID isn&apos;t valid
          </h1>
          <p className="mt-3 text-sm leading-6 text-text-secondary sm:text-base">
            Session IDs may contain letters, numbers, periods, underscores, and
            hyphens, up to 64 characters.
          </p>
        </section>
      </main>
    </div>
  );
}
