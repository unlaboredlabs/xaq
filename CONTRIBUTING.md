# Contributing

Minimalism is a project constraint. Proxy servers, MCP and plugin systems, internal sandboxes, session databases, themes, and full cell-grid TUI frameworks are deliberately out of scope. **Open an issue before adding a new subsystem**, a dependency, or anything that grows the binary.

## Build and test

Install Zig 0.16.0 and `curl`, then:

```sh
zig build check    # type-check without installing
zig build fmt      # format Zig sources
zig build test     # run tests
zig build perf     # enforce startup and prompt-readiness limits (Linux)
zig build -Doptimize=ReleaseSmall
python3 tests/cli_test.py zig-out/bin/xaq # offline CLI recovery/cancellation tests
python3 tests/selection_test.py zig-out/bin/xaq # fullscreen selection and clipboard settings
```

CI additionally runs `zig fmt --check build.zig src tools`, a `ReleaseSmall` build, `shellcheck` over `install.sh tools/*.sh tests/*.sh`, and the shell suites in `tests/`. The Linux performance gate limits help and version startup to a 2 ms mean and 5 ms p95, and fullscreen prompt readiness to 15 ms p95. It reports binary size without enforcing a size limit.

For the landing page in `apps/web`:

```sh
pnpm install
pnpm lint && pnpm typecheck && pnpm test && pnpm build
```

## Pull requests

- Keep them small and focused — one change per PR.
- Add or update tests for behavior changes. Zig tests live inline in `src/*.zig`; shell tests in `tests/`.
- Run `zig build fmt` before pushing.
- Fork PRs run CI on GitHub-hosted runners. All checks must pass before merge.
