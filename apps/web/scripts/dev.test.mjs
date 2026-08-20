import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { access, chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import test from "node:test";
import { setTimeout as delay } from "node:timers/promises";
import { fileURLToPath } from "node:url";

const script = fileURLToPath(new URL("./dev.mjs", import.meta.url));
const appRoot = path.dirname(path.dirname(script));

async function waitForFile(file) {
  for (let attempt = 0; attempt < 100; attempt += 1) {
    try {
      await access(file);
      return;
    } catch {
      await delay(20);
    }
  }
  throw new Error(`timed out waiting for ${file}`);
}

test("dev wrapper forwards termination signals to Next", { timeout: 5000 }, async (t) => {
  const scratch = await mkdtemp(path.join(tmpdir(), "xaq-web-dev-test-"));
  const fakeNext = path.join(scratch, "next");
  const readyMarker = path.join(scratch, "ready");
  const signalMarker = path.join(scratch, "signal");
  await writeFile(
    fakeNext,
    `#!/usr/bin/env node
import { writeFileSync } from "node:fs";
writeFileSync(process.env.READY_MARKER, "ready");
process.on("SIGTERM", () => {
  writeFileSync(process.env.SIGNAL_MARKER, "SIGTERM");
  process.removeAllListeners("SIGTERM");
  process.kill(process.pid, "SIGTERM");
});
setInterval(() => {}, 1000);
`,
  );
  await chmod(fakeNext, 0o755);

  const wrapper = spawn(process.execPath, [script], {
    cwd: appRoot,
    env: {
      ...process.env,
      PATH: `${scratch}${path.delimiter}${process.env.PATH ?? ""}`,
      READY_MARKER: readyMarker,
      SIGNAL_MARKER: signalMarker,
    },
    stdio: "ignore",
  });
  t.after(async () => {
    if (wrapper.exitCode === null && wrapper.signalCode === null) {
      wrapper.kill("SIGKILL");
    }
    await rm(scratch, { recursive: true, force: true });
  });

  await waitForFile(readyMarker);
  const exited = new Promise((resolve) => {
    wrapper.once("exit", (code, signal) => resolve({ code, signal }));
  });
  wrapper.kill("SIGTERM");

  assert.deepEqual(await exited, { code: null, signal: "SIGTERM" });
  assert.equal(await readFile(signalMarker, "utf8"), "SIGTERM");
});
