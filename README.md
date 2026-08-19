# xaq

`xaq` is a minimal coding harness for ChatGPT, Claude, and Grok subscriptions, written in Zig.

It keeps the useful center of [Pi](https://github.com/earendil-works/pi), a model, a conversation, and a small tool set, without carrying a framework around it. The CLI has no package dependencies, proxy servers, extension systems, permission modes, or alternate operating modes.

> [!WARNING]
> The `xaq` CLI has the full permissions of the user who runs it. It can execute shell commands and read, create, or overwrite any file that user can access. There is no CLI approval prompt or internal sandbox. Use an OS container or restricted account when you need isolation. Embedding hosts can disable built-in tools or admit calls with `PermissionHost`.

## Status

Early and usable. The core agent loop, direct subscription authentication, token refresh, multi-turn conversations, and tool calls are implemented. Interfaces may still change.

The current version is intentionally narrow:

- providers: ChatGPT, Claude, and Grok subscriptions
- tools: `read`, `bash`, `edit`, and `write`, subagents, plus optional Firecrawl web tools
- append-only, cwd-scoped JSONL threads with bounded in-memory context
- direct provider OAuth and APIs; CLIProxyAPI is neither used nor supported
- sequential parent tool execution, up to four concurrent subagents, and incremental provider streaming

## Requirements

- Zig 0.16.0 to build
- `curl` on `PATH` at runtime
- Linux or macOS; Windows has not been tested

`curl` supplies the platform HTTPS/TLS implementation. OAuth, request construction, incremental SSE parsing, the agent loop, and all tools are Zig code. A release-small Linux x86_64 build is currently about 500 KiB, with a 512 KiB CI ceiling.

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

ChatGPT uses browser PKCE login; Claude uses a similar browser flow. xaq tries to open your browser (`xdg-open`/`open`) and always prints the URL as a fallback. After login the localhost callback page fails to load. That is expected; paste its full address-bar URL or the authorization code. Grok uses device-code login.

Credentials are stored in `~/.config/xaq/auth.json`. Updates are locked, written atomically, and forced to mode `0600`. Access tokens are checked before every request and force-refreshed once after a `401`. Sensitive headers are sent to `curl` over stdin and do not appear in its process arguments.

Remove one provider's saved credentials with `xaq logout PROVIDER`.

Claude subscription behavior follows Pi's direct OAuth flow. Pi notes that third-party harness use may draw from Anthropic's "extra usage" billing rather than the included plan allowance. Check your Anthropic usage settings before relying on it.

To enable web access, run `/firecrawl` in an interactive session and paste a [Firecrawl API key](https://www.firecrawl.dev/app/api-keys) into the hidden prompt. The key is stored in `~/.config/xaq/settings.json`, whose updates use mode `0600`. `web_fetch` and `web_search` are omitted from model requests until a key is configured. `/firecrawl status` shows whether they are on, and `/firecrawl clear` removes the key and disables them.

## Use

Start an interactive conversation:

```sh
xaq
xaq --provider claude
xaq --provider grok
```

On a terminal the session opens in a fullscreen view with a one-cell outer margin. The top bar shows the provider, model, explicit effort, and fast mode on the left. Git worktree, branch, dirty state (`*`), and a shortened thread ID sit on the right. Lower-priority fields disappear as the terminal narrows. The conversation scrolls in the middle, and the prompt lives in a bordered input box fixed near the bottom. A blank row separates the input box from the info bar, and another sits below it. The info bar carries the working detail: context pressure as a percentage of the model window, live token counts, active and queued subagent counts, current activity (`ready`, `thinking…`, the running tool, `compacting…`), and key hints. Git status refreshes at startup and after shell, edit, or write tools. The completion popup and pickers overlay the bottom of the transcript, above the box. `PgUp`/`PgDn` at the prompt page through recent history; new output snaps back to live. Resizes reflow the retained transcript. If the window drops below 40 columns or 10 rows, fullscreen drawing pauses until it has enough room again. `--plain` or `XAQ_PLAIN=1` keeps the classic inline flow, which is also used automatically for one-shots, pipes, and terminals that are too small. The fullscreen layer is chrome around the same engine, not a separate mode.

The session opens with a `>` prompt (inline mode adds a one-line identity header). A dim `thinking…` placeholder covers the gap until the first streamed byte, then model text streams as it arrives with terminal control sequences filtered. Markdown headings (deeper levels keep dim `#` markers), emphasis, links, lists, quotes, tables (dim cell borders and separator rules), inline code, and fenced code render incrementally on terminals; saved threads and piped output retain the original markdown. Each tool call prints one dimmed line with a short argument preview, such as `[bash] zig build test`; failed or slow calls add a dim aftermath line (`↳ exit 2 · 12s`), and `/verbose` echoes a clamped preview of every tool result. Empty input re-prompts. A provider error (for example a mistyped `/model` ID) prints its HTTP status and message, then returns to the prompt with the failed text prefilled; it never ends the session. `ctrl-c` clears input or interrupts the active provider/tool process tree (an interrupted prompt is prefilled at the next `>` for editing); pressed twice at an empty prompt it exits, as does `ctrl-d`. Editing follows readline habits: ctrl-a/e and home/end, alt-b/f by word, ctrl-w and alt-backspace delete the previous word, ctrl-u and ctrl-k kill to the ends of the line. Prompt history persists across sessions in `~/.config/xaq/history.jsonl` (the newest 64 entries). Bracketed paste is supported, so multi-line pastes land in the input (newlines shown as `⏎`) instead of submitting line by line. Interactive and piped prompts accept up to 4 MiB. Prompts larger than 4 KiB use a byte-and-line summary when echoed to the terminal, while the full text goes to the model. Interactive input beyond 4 MiB is consumed, clipped, and reported. Oversized piped input exits with a clear error. ANSI styling is applied only on a terminal and disabled by `NO_COLOR` or `TERM=dumb`; `NO_COLOR` keeps structural markdown formatting without text styles.

Lines starting with `/` are commands handled locally, never sent to the model:

| Command | Effect |
| --- | --- |
| `/help` | list commands |
| `/model [ID]` | pick model, effort, and speed, or set an exact model ID |
| `/effort [LEVEL]` | pick or set a reasoning effort supported by the active model |
| `/fast [on\|off\|status]` | toggle or inspect the provider's faster premium tier |
| `/verbose [on\|off]` | echo a clamped preview of each tool result |
| `/firecrawl [status\|clear]` | configure or disable Firecrawl web tools |
| `/agents` | list subagents and their current status |
| `/settings` (or `/config`) | configure context compaction and subagents |
| `/status` | thread, provider, model, fast mode, context size, and token usage |
| `/compact` | compact older context immediately |
| `/clear` | clear the current saved thread |
| `/new` | save the current thread and start another |
| `/resume [ID]` | pick a recent thread or resume an explicit ID |
| `/exit` (or `/quit`) | leave xaq |

Typing `/` opens an inline completion popup that filters as you type: up/down selects, tab completes, enter runs the highlighted command. Unique prefixes also work directly: `/mod gpt-5.6-sol` switches the model, `/q` quits. The argument-less `/model` picker continues into reasoning effort, then `normal` or `fast` when the selected model supports fast mode. It applies the combined choice only after the last step; cancelling a step changes nothing. Fast defaults to selected in that flow, matching [fx](https://github.com/vercel-labs/fx). `/fast` toggles fast mode directly; `/fast on`, `/fast off`, and `/fast status` are explicit forms. Argument-less `/effort`, `/resume`, and `/settings` keep their focused pickers. Explicit model, effort, and thread arguments remain available for scripts and exact IDs.

The model can delegate through three tools: `Agent`, `get_subagent_result`, and `steer_subagent`. `Agent` runs in the background by default, returns an ID at once, and queues work after four concurrent agents. Several `Agent` calls in one model turn start together. `get_subagent_result` checks status or waits for completion; `steer_subagent` adds a user message before the worker's next model turn. Completed background results enter the parent conversation as structured notifications unless the parent already fetched them. `/settings` can disable the tools, set the concurrency limit from one to eight, and change the default to foreground. These choices persist in `~/.config/xaq/settings.json` and apply to the open session at once.

Each subagent is a separate `xaq` process with its own model context, the same working directory, and all local tools. Its prompt defines the job. Worker prompts, results, errors, and steering messages live in a mode-`0700` temporary directory for the session. Starting a new thread, resuming another thread, or exiting stops unfinished workers and removes that directory.

All interactive drawing stays at the prompt (the fullscreen layer only adds the status bar and paging on top of it) and requires a terminal on stdin and stdout. End a line with a single `\` to continue a multiline prompt on the next line; continuation lines show a dim `↳` marker instead of the prompt block.

Interactive turns and session choices such as model, effort, and fast mode are appended to `~/.config/xaq/threads/<cwd-hash>/<thread-id>.jsonl` before the next action. The format is inspectable and crash-tolerant: replay ignores a partial final line. Threads are scoped per directory (run xaq from the project root for a stable namespace), and the newest 50 per directory are retained; older ones are pruned when a new thread starts. Resume the latest thread for the current directory with `xaq -c`, or select one with `xaq --resume THREAD`; resuming prints a dim orientation line (thread, provider/model, entry count) and replays the tail of the last exchange. The `/resume` picker lists each thread with its age and first prompt, and `xaq threads` prints the same listing from the shell so thread IDs are discoverable without opening a session.

xaq compacts context automatically at 80% of the active model's subscription context window. The selected compaction model summarizes the older history into a continuation handoff while a recent tail remains verbatim; a bounded local extractive summary is the fallback if the model request fails. `/settings` can toggle automatic compaction and change its threshold, model, and effort. Settings are stored in `~/.config/xaq/settings.json`; compaction model and effort choices are kept separately for each provider.

The context meter is an estimate until the provider tokenizes a request. It counts ordinary text conservatively and gives opaque encrypted reasoning items a denser estimate. `/compact` always requests immediate compaction regardless of the automatic toggle.

`xaq` also loads `~/.config/xaq/AGENTS.md` plus `AGENTS.md` files from the filesystem root down to the working directory, with strict per-file and total size limits.

Run a one-shot prompt:

```sh
xaq 'summarize this repository'
xaq --provider grok -p 'find and fix the failing test'
git diff | xaq 'review this patch'
```

A bare argument and `-p PROMPT` are equivalent, and `xaq -- "-starts-with-dash"` passes a prompt that begins with `-`. Piped stdin is the prompt when no argument is present and is prepended when an argument is also supplied; empty piped stdin with no prompt is an error rather than a silent exit. One-shot runs print no header or prompt, so output pipes cleanly: when stdout is not a terminal, tool call and compaction trace lines go to stderr, and stdout carries only the answer text. Exit codes are `130` when interrupted, `1` on provider failure (with the provider's HTTP status and message on stderr), `2` on usage mistakes. All argument errors are single-line messages on stderr, never stack traces. `xaq --version` prints the version.

Override the provider's default model when needed:

```sh
xaq --provider chatgpt --model gpt-5.5
xaq --effort high 'solve the failing test'
xaq --fast 'solve it using the faster service tier'
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

The ChatGPT values above come from the live Codex subscription catalog, not the API-key catalog. That is deliberate. The [OpenAI API model pages](https://developers.openai.com/api/docs/models) advertise a 1.05M window for GPT-5.6 and GPT-5.5, while ChatGPT-plan Codex currently exposes 272K. Codex's `ultra` option for Sol and Terra is a separate orchestrated mode; selecting an effort in xaq does not enable it. Claude limits and effort support follow Anthropic's [models overview](https://platform.claude.com/docs/en/about-claude/models/overview) and [effort guide](https://platform.claude.com/docs/en/build-with-claude/effort); notably, Haiku retains a smaller window and has no effort parameter. Grok values follow the current [Grok 4.6 model page](https://docs.x.ai/developers/models/grok-4.6) and [reasoning guide](https://docs.x.ai/developers/model-capabilities/text/reasoning).

Fast mode follows each subscription API's native contract: OpenAI's `service_tier: "fast"` for Sol, Terra, Luna, GPT-5.5, and GPT-5.4, and Anthropic's `speed: "fast"` beta for Claude Opus 5 and explicit Opus 4.8 IDs. Unsupported models are rejected instead of silently running at standard speed, and changing to one turns fast mode off. Both providers charge fast requests at a higher subscription usage rate; see OpenAI's [speed controls](https://learn.chatgpt.com/docs/agent-configuration/speed) and Anthropic's [fast mode guide](https://platform.claude.com/docs/en/build-with-claude/fast-mode).

Unknown model IDs remain usable through `--model` or `/model <id>`. Because their capabilities cannot be verified, context management uses a conservative provider fallback.

## Embed

The package exports a native Zig module named `xaq`. It runs the headless agent loop in-process and does not read process environment variables, install signal handlers, change terminal state, or open xaq's credential, settings, and thread files. Add the package module to a host executable:

```zig
const xaq_dependency = b.dependency("xaq", .{
    .target = target,
    .optimize = optimize,
});
executable.root_module.addImport("xaq", xaq_dependency.module("xaq"));
```

Create one `xaq.Agent` per independent conversation. `prompt` blocks the calling thread while it streams raw text to an optional `Io.Writer`; a UI host can call it on a worker. Separate agents have separate history and cancellation state.

```zig
const std = @import("std");
const xaq = @import("xaq");

var embedded = try xaq.Agent.init(allocator, .{
    .io = io,
    .provider = .chatgpt,
    .cwd = "/srv/workspace",
    .credential = .{
        .access = access_token,
        .refresh = "",
        .expires = std.math.maxInt(i64),
        .account_id = chatgpt_account_id,
    },
});
defer embedded.deinit();

const turn = try embedded.prompt("Review the current diff.", .{
    .output = response_writer,
});
```

The host may replace each external boundary:

- `CredentialSource` loads and refreshes credentials. A fixed `Credential` is also accepted.
- `Transport` receives the provider URL, headers, request body, cancellation token, and an SSE line callback. The default transport launches `curl`.
- `ToolHost` executes host-defined tools declared with `ToolDefinition`; results are capped at 50 KiB before entering history. Built-in filesystem and shell tools are off by default; enable `local_tools` only when the embedded agent should have those permissions.
- `PermissionHost` admits or denies each tool call before execution. A denial becomes a tool result so the model can continue without it.
- `EventSink` receives request, text delta, tool, usage, completion, and cancellation events.

Pass `initial_history` to restore host-owned state and read `history()` after a successful turn. Reacquire the top-level history slice after each prompt; its nested payloads and `Turn.text` remain valid until `reset()` or `deinit()`. Event payloads last only for their callback. `Turn.stop_reason` distinguishes a completed answer from the configured tool-round limit. Only one `prompt` may run on an agent at a time. `cancel()` is thread-safe and terminates a default-transport or built-in-tool child process without affecting other agents.

The public contract is in [`src/embed.zig`](src/embed.zig), with `api_version = 1`. This is a native Zig API, not parity with fx's distribution formats. xaq does not ship ACP, Node-API, WebAssembly, or an embeddable terminal.

## Tool contract

The local tools match Pi's defaults:

| Tool | Purpose |
| --- | --- |
| `read` | Read a text file with optional line offset and limit |
| `bash` | Run a shell command in the current working directory |
| `edit` | Apply one or more exact, non-overlapping text replacements |
| `write` | Create or overwrite a text file, including parent directories |

Two more tools appear only after `/firecrawl` setup:

| Tool | Purpose |
| --- | --- |
| `web_fetch` | Fetch a public URL through Firecrawl and return its main content as Markdown |
| `web_search` | Search through Firecrawl and return result titles, URLs, and descriptions |

The parent agent also receives three coordination tools. Subagent workers do not receive them, so delegation cannot recurse:

| Tool | Purpose |
| --- | --- |
| `Agent` | Start or queue a separate subagent process |
| `get_subagent_result` | Check status or wait for a subagent result |
| `steer_subagent` | Redirect a running or queued subagent |

Relative and absolute paths are accepted. `bash` uses `/bin/bash`, inherits the process environment, combines stdout and stderr in production order, and terminates the whole process group on timeout or interruption. Returned command output is capped at 50 KiB; larger streams are saved completely to a mode-`0600` file under `/tmp`, whose path is included in the result. Truncated file reads state the next line offset, with reads limited to 2,000 lines by default.

## Logging

Trace logging is off by default and opt-in through the environment, following the design of [fx](https://github.com/vercel-labs/fx)'s debug trace:

```sh
XAQ_LOG=1 xaq                 # log to ~/.config/xaq/trace.log
XAQ_LOG=/tmp/xaq.log xaq      # log to an explicit path
XAQ_LOG_SCOPES=usage,tool xaq # only emit the listed scopes
```

Lines are `<unix-millis> [scope] event=... key=value`. The `agent` scope records each provider request and response, `usage` records per-turn and session token counts (input, cached, output) as reported by the provider stream, and `tool` records each tool call with argument and result sizes and duration. Only names, counts, and sizes are logged, never prompts, file contents, or credentials.

Logging overhead stays small: one descriptor for the life of the process, lines batched in memory and appended in at most a couple of writes per model round, and no fsync. The file is capped at 2 MiB and rotated by rename to `trace.log.old`, which moves metadata without copying data. Logging is best-effort and silently disables itself on failure.

## Design boundary

Minimalism is a constraint, not a placeholder. Additions should demonstrate measured value greater than their implementation and maintenance cost. The following are deliberately out of scope:

- an embedded API proxy or compatibility server
- MCP and plugin systems
- internal sandboxes, approval policies, and permission profiles
- plan, "yolo," or other operating modes
- session databases, indexes, and comprehensive model-catalog subsystems (threads stay plain JSONL)
- themes, mouse support, and cell-grid TUI frameworks; the fullscreen
  view is one pinned status row plus a terminal-managed scroll region
  driving the unchanged inline engine, and `--plain` remains first-class

## Development

```sh
zig build check    # fast type-check, no install (also drives ZLS build-on-save)
zig build fmt      # format build.zig and src/ in place
zig build test     # run tests
zig build perf     # test ReleaseSmall size and startup performance
zig build -Doptimize=ReleaseSmall
```

`zig build perf` builds a stripped host ReleaseSmall binary, warms it up, then runs `xaq --help` 200 times. It reports binary size, p50 and p95 startup, mean startup, and peak RSS. The command exits nonzero above the 512 KiB size ceiling or 25 ms mean startup ceiling. Use `zig build perf -- --runs 1000` for a larger sample, or add `--no-check` to collect numbers without enforcing the ceilings.

CI (`.github/workflows/ci.yml`) runs `zig fmt --check`, deterministic parser/thread/tool tests, and a release build on Linux and macOS for every push and pull request. Linux runs the same `zig build perf` check used locally.

Keep changes small, dependency-free, and directly related to the coding loop. Open an issue before adding a new subsystem.

## Acknowledgments

- [Pi](https://github.com/earendil-works/pi) informed the four-tool contract, full-permission security model, subscription OAuth flows, and provider wire formats.
- [tintinweb/pi-subagents](https://github.com/tintinweb/pi-subagents) informed the `Agent` tool contract, background-first flow, status display, result retrieval, and steering UX.
- [OpenAI authentication documentation](https://learn.chatgpt.com/docs/auth) documents ChatGPT subscription sign-in for Codex clients.

The implementation was written for this project; no CLIProxyAPI code is included.

## License

[MIT](LICENSE)
