"use client";

import { useId } from "react";
import { useCopy } from "@/lib/use-copy";

export default function CopyCommand({ command }: { command: string }) {
  const { status, copy } = useCopy(command);
  const statusId = useId();
  const copyStatus =
    status === "copied"
      ? "copied"
      : status === "failed"
        ? "Couldn't copy. Select the command to copy it manually."
        : "";

  return (
    <div className="mt-8">
      <div className="flex items-baseline gap-3">
        <span aria-hidden="true" className="shrink-0 select-none text-neutral-600">
          $
        </span>
        <code className="min-w-0 select-all text-neutral-100 [overflow-wrap:anywhere]">
          {command}
        </code>
        <button
          type="button"
          onClick={() => void copy()}
          className="min-h-6 shrink-0 rounded-sm underline decoration-neutral-700 underline-offset-4 hover:text-neutral-200 hover:decoration-neutral-400 focus-visible:outline-2 focus-visible:outline-offset-4 focus-visible:outline-neutral-200"
          aria-label="Copy install command"
          aria-describedby={statusId}
        >
          copy
        </button>
      </div>
      <span
        id={statusId}
        role="status"
        aria-live="polite"
        className="block min-h-[1lh] text-neutral-400"
      >
        {copyStatus}
      </span>
    </div>
  );
}
