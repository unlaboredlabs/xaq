#!/usr/bin/env node
// Wrapper around `next dev` that accepts Vite-style `--host [addr]`
// and maps it to Next's `--hostname`. All other flags pass through.
import { spawn } from "node:child_process";

const args = process.argv.slice(2);
const mapped = [];

for (let i = 0; i < args.length; i++) {
  const arg = args[i];
  if (arg === "--host") {
    const next = args[i + 1];
    if (next && !next.startsWith("-")) {
      mapped.push("--hostname", next);
      i++;
    } else {
      mapped.push("--hostname", "0.0.0.0");
    }
  } else if (arg.startsWith("--host=")) {
    mapped.push("--hostname", arg.slice("--host=".length) || "0.0.0.0");
  } else {
    mapped.push(arg);
  }
}

const child = spawn("next", ["dev", ...mapped], {
  stdio: "inherit",
  shell: process.platform === "win32",
});

child.on("exit", (code, signal) => {
  if (signal) process.kill(process.pid, signal);
  else process.exit(code ?? 0);
});
