"use client";

import { site } from "@/lib/content";
import { useCopy } from "@/lib/use-copy";

export default function Landing() {
  const { copied, copy } = useCopy(site.install);

  return (
    <main className="flex min-h-screen items-center bg-[#0a0a0a] font-mono text-[13px] leading-[1.9] text-neutral-400">
      <div className="mx-auto w-full max-w-[560px] px-6 py-24">
        <p className="text-neutral-100">
          <span className="text-neutral-600">$ </span>xaq
        </p>
        <p className="mt-6 text-neutral-100">{site.tagline}</p>
        <p className="mt-4">{site.description}</p>

        <button
          onClick={copy}
          className="group mt-8 block w-full text-left"
          title="copy"
        >
          <span className="text-neutral-600">$ </span>
          <span className="text-neutral-100 underline decoration-neutral-700 underline-offset-4 group-hover:decoration-neutral-400">
            {site.install}
          </span>
          <span className="ml-3 text-neutral-600">
            {copied ? "copied" : ""}
          </span>
        </button>

        <p className="mt-10 text-neutral-600">
          <a href={site.github} className="hover:text-neutral-200">
            github
          </a>
          {"  ·  "}
          <a
            href={`${site.github}/releases/tag/edge`}
            className="hover:text-neutral-200"
          >
            releases
          </a>
          {"  ·  "}
          {site.license.toLowerCase()}
        </p>

        <p className="mt-6 text-neutral-100">
          <span className="text-neutral-600">&gt; </span>
          <span className="cursor-blink">▊</span>
        </p>
      </div>
    </main>
  );
}
