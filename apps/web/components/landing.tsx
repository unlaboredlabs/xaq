"use client";

import { site } from "@/lib/content";
import { useCopy } from "@/lib/use-copy";

export default function Landing() {
  const { status, copy } = useCopy(site.install);
  const copyStatus =
    status === "copied" ? "copied" : status === "failed" ? "copy failed" : "";

  return (
    <main className="flex min-h-screen items-center bg-[#0a0a0a] font-mono text-[13px] leading-[1.9] text-neutral-400">
      <div className="mx-auto w-full max-w-[560px] px-6 py-24">
        <h1 className="text-neutral-100">
          <span aria-hidden="true" className="text-neutral-600">
            $ {""}
          </span>
          xaq
        </h1>
        <p className="mt-6 text-neutral-100">{site.tagline}</p>
        <p className="mt-4">{site.description}</p>

        <button
          type="button"
          onClick={() => void copy()}
          className="group mt-8 block w-full text-left focus-visible:rounded-sm focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-neutral-200"
          aria-label="Copy install command"
          title="Copy install command"
        >
          <span aria-hidden="true" className="text-neutral-600">
            $ {""}
          </span>
          <span className="text-neutral-100 underline decoration-neutral-700 underline-offset-4 group-hover:decoration-neutral-400">
            {site.install}
          </span>
          <span
            role="status"
            aria-live="polite"
            className="ml-3 text-neutral-400"
          >
            {copyStatus}
          </span>
        </button>

        <p className="mt-10 text-neutral-400">
          <a
            href={site.github}
            className="rounded-sm hover:text-neutral-200 focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-neutral-200"
          >
            github
          </a>
          <span aria-hidden="true">{"  ·  "}</span>
          <a
            href={`${site.github}/releases/tag/edge`}
            className="rounded-sm hover:text-neutral-200 focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-neutral-200"
          >
            releases
          </a>
          <span aria-hidden="true">{"  ·  "}</span>
          {site.license.toLowerCase()}
        </p>

        <p aria-hidden="true" className="mt-6 text-neutral-100">
          <span className="text-neutral-600">&gt; </span>
          <span className="cursor-blink">▊</span>
        </p>
      </div>
    </main>
  );
}
