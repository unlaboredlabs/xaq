"use client";

import { useCallback, useEffect, useRef, useState } from "react";

type ClipboardWriter = Pick<Clipboard, "writeText">;
export type CopyStatus = "idle" | "copied" | "failed";

export async function copyText(
  text: string,
  clipboard: ClipboardWriter | undefined,
): Promise<boolean> {
  if (!clipboard) return false;
  try {
    await clipboard.writeText(text);
    return true;
  } catch {
    return false;
  }
}

export function useCopy(text: string) {
  const [status, setStatus] = useState<CopyStatus>("idle");
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const attempt = useRef(0);

  useEffect(
    () => () => {
      attempt.current += 1;
      if (timer.current) clearTimeout(timer.current);
    },
    [],
  );

  const copy = useCallback(async () => {
    const currentAttempt = ++attempt.current;
    if (timer.current) clearTimeout(timer.current);
    timer.current = null;

    const clipboard =
      typeof navigator === "undefined" ? undefined : navigator.clipboard;
    const copied = await copyText(text, clipboard);
    if (attempt.current !== currentAttempt) return;

    setStatus(copied ? "copied" : "failed");
    timer.current = setTimeout(() => {
      timer.current = null;
      setStatus("idle");
    }, 1600);
  }, [text]);

  return { status, copy };
}
