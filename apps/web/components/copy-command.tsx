"use client";

import { useCopy } from "@/lib/use-copy";

export default function CopyCommand({ command }: { command: string }) {
  const { status, copy } = useCopy(command);
  const copyStatus =
    status === "copied" ? "copied" : status === "failed" ? "copy failed" : "";

  return (
    <div className="mt-8 flex items-baseline gap-3">
      <button
        type="button"
        onClick={() => void copy()}
        className="group min-w-0 text-left focus-visible:rounded-sm focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-neutral-200"
        aria-label="Copy install command"
        aria-describedby="copy-status"
        title="Copy install command"
      >
        <span aria-hidden="true" className="text-neutral-600">
          $ {""}
        </span>
        <span className="text-neutral-100 underline decoration-neutral-700 underline-offset-4 group-hover:decoration-neutral-400">
          {command}
        </span>
      </button>
      <span
        id="copy-status"
        role="status"
        aria-live="polite"
        className="shrink-0 text-neutral-400"
      >
        {copyStatus}
      </span>
    </div>
  );
}
