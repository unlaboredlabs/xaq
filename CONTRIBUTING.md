# Contributing

Minimalism is a project constraint. Proxy servers, MCP and plugin systems, internal sandboxes, session databases, themes, and full cell-grid TUI frameworks are deliberately out of scope. **Open an issue before adding a new subsystem**, a dependency, or anything that grows the binary.

## Build and test

Install Zig 0.16.0 and `curl`, then:

```sh
zig build check    # type-check without installing
zig build fmt      # format Zig sources
zig build test     # run tests
zig build perf     # enforce size and startup limits (Linux)
```

CI additionally runs `zig fmt --check build.zig src tools`, a `ReleaseSmall` build, `shellcheck` over `install.sh tools/*.sh tests/*.sh`, and the shell suites in `tests/`. The performance gate caps the stripped Linux x86_64 binary at 1 MiB and mean startup at 25 ms; changes that break it will not merge.

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
