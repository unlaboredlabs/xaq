import assert from "node:assert/strict";
import test from "node:test";

import { copyText } from "./use-copy.ts";

test("copyText reports success only after the clipboard write resolves", async () => {
  let release!: () => void;
  let settled = false;
  const result = copyText("install", {
    writeText: () =>
      new Promise<void>((resolve) => {
        release = resolve;
      }),
  });
  void result.then(() => {
    settled = true;
  });

  await Promise.resolve();
  assert.equal(settled, false);
  release();
  assert.equal(await result, true);
});

test("copyText reports clipboard rejection and unavailability", async () => {
  const rejected = await copyText("install", {
    writeText: () => Promise.reject(new Error("permission denied")),
  });
  assert.equal(rejected, false);
  assert.equal(await copyText("install", undefined), false);
});
