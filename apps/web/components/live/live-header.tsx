import Image from "next/image";

export function LiveHeader() {
  return (
    <header className="border-b border-border-default/80 bg-white/90 backdrop-blur-xl">
      <div className="mx-auto flex h-20 w-full max-w-[1280px] items-center justify-between px-4 sm:px-8 lg:px-12">
        <div className="flex items-center gap-3">
          <Image
            src="/app-icon.jpg"
            alt=""
            width={36}
            height={36}
            priority
            className="size-9 rounded-lg shadow-sm"
          />
          <span className="font-display text-lg font-bold tracking-[-0.02em] text-text-primary sm:text-xl">
            AI Live Translator
          </span>
        </div>

        <div className="rounded-full border border-brand-primary/15 bg-brand-primary/5 px-3 py-1.5 text-xs font-semibold uppercase tracking-[0.05em] text-brand-primary">
          Viewer mode
        </div>
      </div>
    </header>
  );
}
