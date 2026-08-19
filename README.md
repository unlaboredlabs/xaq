# xaq

`xaq` is a minimal coding harness for ChatGPT, Claude, and Grok subscriptions, written in Zig.

It keeps the useful center of [Pi](https://github.com/earendil-works/pi)—a model, a conversation, and four tools—without carrying a framework around it. There are no package dependencies, proxy servers, extension systems, permission modes, or alternate operating modes.

> [!WARNING]
> `xaq` has the full permissions of the user who runs it. It can execute shell commands and read, create, or overwrite any file that user can access. There is no approval prompt or internal sandbox. Use an OS container or restricted account when you need isolation.

## Status

Early and usable. The core agent loop, direct subscription authentication, token refresh, multi-turn conversations, and tool calls are implemented. Interfaces may still change.

The current version is intentionally narrow:

- providers: ChatGPT, Claude, and Grok subscriptions
- tools: `read`, `bash`, `edit`, and `write`
- append-only, cwd-scoped JSONL threads with bounded in-memory context
- direct provider OAuth and APIs—CLIProxyAPI is neither used nor supported
- sequential tool execution and incremental provider streaming

## Requirements

- Zig 0.16.0 to build
- `curl` on `PATH` at runtime
- Linux or macOS; Windows has not been tested

`curl` supplies the platform HTTPS/TLS implementation. OAuth, request construction, incremental SSE parsing, the agent loop, and all tools are Zig code. A release-small Linux x86_64 build is currently about 350 KiB, with a 512 KiB CI ceiling.

## Build

Every successful `main` build updates the rolling [edge prerelease](https://github.com/unlaboredlabs/xaq/releases/tag/edge) with tested Linux and macOS archives plus `SHA256SUMS`. Edge is built from the latest commit and may change without notice.

To build from source:

```sh
git clone https://github.com/unlaboredlabs/xaq.git
cd xaq
zig build -Doptimize=ReleaseSmall
```

The binary is written to `zig-out/bin/xaq`. To install it for the current user:

```sh
install -Dm755 zig-out/bin/xaq "$HOME/.local/bin/xaq"
```

## Authenticate

Log in once for each provider you intend to use:

```sh
xaq login chatgpt
xaq login claude
xaq login grok
```

ChatGPT uses browser PKCE login; Claude uses a similar browser flow. xaq tries to open your browser (`xdg-open`/`open`) and always prints the URL as a fallback. After login the localhost callback page fails to load—that is expected; paste its full address-bar URL or the authorization code. Grok uses device-code login.

Credentials are stored in `~/.config/xaq/auth.json`. Updates are locked, written atomically, and forced to mode `0600`. Access tokens are checked before every request and force-refreshed once after a `401`. Sensitive headers are sent to `curl` over stdin and do not appear in its process arguments.

Remove one provider's saved credentials with `xaq logout PROVIDER`.

Claude subscription behavior follows Pi's direct OAuth flow. Pi notes that third-party harness use may draw from Anthropic's **extra usage** billing rather than the included plan allowance. Check your Anthropic usage settings before relying on it.

## Use

Start an interactive conversation:

```sh
xaq
xaq --provider claude
xaq --provider grok
```

On a terminal the session opens in a fullscreen view: an alternate screen with a pinned status bar on the top row and the conversation scrolling beneath it. The bar shows provider/model, the thread ID, context pressure as a percentage of the model window, live token counts, and the current state (`ready`, `thinking…`, or the running tool). `PgUp`/`PgDn` at the prompt page through recent transcript history (unstyled, best-effort); new output snaps back to live. `--plain` or `XAQ_PLAIN=1` keeps the classic inline flow, which is also used automatically for one-shots, pipes, and terminals that are too small—the fullscreen layer is chrome around the same engine, not a separate mode.

The session opens with a `>` prompt (inline mode adds a one-line identity header). A dim `thinking…` placeholder covers the gap until the first streamed byte, then model text streams as it arrives with terminal control sequences filtered. Each tool call prints one dimmed line with a short argument preview, such as `[bash] zig build test`; failed or slow calls add a dim aftermath line (`↳ exit 2 · 12s`). Empty input re-prompts. `ctrl-c` clears input or interrupts the active provider/tool process tree (an interrupted prompt is prefilled at the next `>` for editing); pressed twice at an empty prompt it exits, as does `ctrl-d`. Bracketed paste is supported, so multi-line pastes land in the input (newlines shown as `⏎`) instead of submitting line by line. Styling is plain ANSI dim and bold, applied only on a terminal and disabled by `NO_COLOR` or `TERM=dumb`.

Lines starting with `/` are commands handled locally, never sent to the model:

| Command | Effect |
| --- | --- |
| `/help` | list commands |
| `/model [ID]` | show or switch the model mid-session |
| `/effort [LEVEL]` | pick or set a reasoning effort supported by the active model |
| `/settings` (or `/config`) | configure automatic context compaction |
| `/status` | thread, provider, model, context size, and token usage |
| `/compact` | compact older context immediately |
| `/clear` | clear the current saved thread |
| `/new` | save the current thread and start another |
| `/resume [ID]` | pick a recent thread or resume an explicit ID |
| `/exit` (or `/quit`) | leave xaq |

Typing `/` opens an inline completion popup that filters as you type: up/down selects, tab completes, enter runs the highlighted command. Unique prefixes also work directly—`/mod gpt-5.6-sol` switches the model, `/q` quits. Argument-less `/model`, `/effort`, `/resume`, and `/settings` open small inline pickers (enter confirms, `q` cancels); explicit model, effort, and thread arguments remain available for scripts and exact IDs.

All interactive drawing stays at the prompt—the fullscreen layer only adds the status bar and paging on top of it—and requires a terminal on stdin and stdout. End a line with a single `\` to continue a multiline prompt on the next line.

Interactive turns are appended to `~/.config/xaq/threads/<cwd-hash>/<thread-id>.jsonl` before the next action. The format is inspectable and crash-tolerant: a partial final line is ignored during replay. Threads are scoped per directory (run xaq from the project root for a stable namespace), and the newest 50 per directory are retained—older ones are pruned when a new thread starts. Resume the latest thread for the current directory with `xaq -c`, or select one with `xaq --resume THREAD`; resuming prints a dim orientation line (thread, provider/model, entry count) and replays the tail of the last exchange. The `/resume` picker lists each thread with its age and first prompt.

Context is compacted automatically at 80% of the active model's subscription context window. The selected compaction model summarizes the older history into a continuation handoff while a recent tail remains verbatim; a bounded local extractive summary is the fallback if the model request fails. `/settings` can toggle automatic compaction and change its threshold, model, and effort. Settings are stored in `~/.config/xaq/settings.json`; compaction model and effort choices are kept separately for each provider.

The context meter is an estimate until the provider tokenizes a request. It counts ordinary text conservatively and gives opaque encrypted reasoning items a denser estimate. `/compact` always requests immediate compaction regardless of the automatic toggle.

`xaq` also loads `~/.config/xaq/AGENTS.md` plus `AGENTS.md` files from the filesystem root down to the working directory, with strict per-file and total size limits.

Run a one-shot prompt:

```sh
xaq 'summarize this repository'
xaq --provider grok -p 'find and fix the failing test'
git diff | xaq 'review this patch'
```

A bare argument and `-p PROMPT` are equivalent, and `xaq -- "-starts-with-dash"` passes a prompt that begins with `-`. Piped stdin is the prompt when no argument is present and is prepended when an argument is also supplied; empty piped stdin with no prompt is an error rather than a silent exit. One-shot runs print no header or prompt, so output pipes cleanly, and exit `130` when interrupted, `1` on provider failure, `2` on usage mistakes—all argument errors are single-line messages on stderr, never stack traces. `xaq --version` prints the version.

Override the provider's default model when needed:

```sh
xaq --provider chatgpt --model gpt-5.5
xaq --effort high 'solve the failing test'
```

Defaults and picker metadata track the providers' current coding-capable models as of August 19, 2026:

| Provider | Model | Subscription context | Explicit efforts |
| --- | --- | ---: | --- |
| ChatGPT | `gpt-5.6-sol` (default) | 272K | low, medium, high, xhigh, max |
| ChatGPT | `gpt-5.6-terra` | 272K | low, medium, high, xhigh, max |
| ChatGPT | `gpt-5.6-luna` | 272K | low, medium, high, xhigh, max |
| ChatGPT | `gpt-5.5` | 272K | low, medium, high, xhigh |
| ChatGPT | `gpt-5.4` | 272K | low, medium, high, xhigh |
| ChatGPT | `gpt-5.4-mini` | 272K | low, medium, high, xhigh |
| ChatGPT | `gpt-5.3-codex-spark` | 128K | low, medium, high, xhigh |
| Claude | `claude-opus-5` (default) | 1M | low, medium, high, xhigh, max |
| Claude | `claude-sonnet-5` | 1M | low, medium, high, xhigh, max |
| Claude | `claude-fable-5` | 1M | low, medium, high, xhigh, max |
| Claude | `claude-haiku-4-5` | 200K | provider default only |
| Grok | `grok-4.6` (default) | 500K | low, medium, high, xhigh |

The ChatGPT values above come from the live Codex subscription catalog, not the API-key catalog. This distinction is deliberate: the [OpenAI API model pages](https://developers.openai.com/api/docs/models) advertise a 1.05M window for GPT-5.6 and GPT-5.5, while ChatGPT-plan Codex currently exposes 272K. Codex's `ultra` option for Sol and Terra is an orchestrated multi-agent mode, not exposed by this single-agent harness. Claude limits and effort support follow Anthropic's [models overview](https://platform.claude.com/docs/en/about-claude/models/overview) and [effort guide](https://platform.claude.com/docs/en/build-with-claude/effort); notably, Haiku retains a smaller window and has no effort parameter. Grok values follow the current [Grok 4.6 model page](https://docs.x.ai/developers/models/grok-4.6) and [reasoning guide](https://docs.x.ai/developers/model-capabilities/text/reasoning).

Unknown model IDs remain usable through `--model` or `/model <id>`. Because their capabilities cannot be verified, context management uses a conservative provider fallback.

## Tool contract

The default tool surface matches Pi:

| Tool | Purpose |
| --- | --- |
| `read` | Read a text file with optional line offset and limit |
| `bash` | Run a shell command in the current working directory |
| `edit` | Apply one or more exact, non-overlapping text replacements |
| `write` | Create or overwrite a text file, including parent directories |

Relative and absolute paths are accepted. `bash` uses `/bin/bash`, inherits the process environment, combines stdout and stderr in production order, and terminates the whole process group on timeout or interruption. Returned command output is capped at 50 KiB; larger streams are saved completely to a mode-`0600` file under `/tmp`, whose path is included in the result. Truncated file reads state the next line offset, with reads limited to 2,000 lines by default.

## Logging

Trace logging is off by default and opt-in through the environment, following the design of [fx](https://github.com/vercel-labs/fx)'s debug trace:

```sh
XAQ_LOG=1 xaq                 # log to ~/.config/xaq/trace.log
XAQ_LOG=/tmp/xaq.log xaq      # log to an explicit path
XAQ_LOG_SCOPES=usage,tool xaq # only emit the listed scopes
```

Lines are `<unix-millis> [scope] event=... key=value`. The `agent` scope records each provider request and response, `usage` records per-turn and session token counts (input, cached, output) as reported by the provider stream, and `tool` records each tool call with argument and result sizes and duration. Only names, counts, and sizes are logged—never prompts, file contents, or credentials.

The log is written gently: one descriptor for the life of the process, lines batched in memory and appended in at most a couple of writes per model round, and no fsync. The file is capped at 2 MiB and rotated by rename to `trace.log.old`, which moves metadata without copying data. Logging is best-effort and silently disables itself on failure.

## Design boundary

Minimalism is a constraint, not a placeholder. Additions should demonstrate measured value greater than their implementation and maintenance cost. The following are deliberately out of scope:

- an embedded API proxy or compatibility server
- MCP and plugin systems
- internal sandboxes, approval policies, and permission profiles
- plan, “yolo,” or other operating modes
- session databases, indexes, and comprehensive model-catalog subsystems (threads stay plain JSONL)
- themes, mouse support, and cell-grid TUI frameworks; the fullscreen
  view is one pinned status row plus a terminal-managed scroll region
  driving the unchanged inline engine, and `--plain` remains first-class

## Development

```sh
zig build check    # fast type-check, no install (also drives ZLS build-on-save)
zig build fmt      # format build.zig and src/ in place
zig build test     # run tests
zig build -Doptimize=ReleaseSmall
```

CI (`.github/workflows/ci.yml`) runs `zig fmt --check`, deterministic parser/thread/tool tests, and a release build on Linux and macOS for every push and pull request. Linux also enforces the 512 KiB binary ceiling and a bounded 200-process startup smoke benchmark.

Keep changes small, dependency-free, and directly related to the coding loop. Open an issue before adding a new subsystem.

## Acknowledgments

- [Pi](https://github.com/earendil-works/pi) informed the four-tool contract, full-permission security model, subscription OAuth flows, and provider wire formats.
- [OpenAI authentication documentation](https://learn.chatgpt.com/docs/auth) documents ChatGPT subscription sign-in for Codex clients.

The implementation was written for this project; no CLIProxyAPI code is included.

## License

[MIT](LICENSE)
