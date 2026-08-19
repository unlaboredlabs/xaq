# xaq

**A coding agent in about 540 KiB.**

One binary. One conversation. Four local tools. `xaq` connects directly to ChatGPT, Claude, and Grok subscriptions without a daemon, package runtime, proxy server, or plugin system. It is written in Zig and inspired by [Vercel's `fx`](https://github.com/vercel-labs/fx) and [Pi](https://github.com/earendil-works/pi).

> [!WARNING]
> `xaq` has the full permissions of the user who runs it. It can execute commands and read, create, or overwrite any accessible file. There is no approval prompt or internal sandbox. Use a container or restricted account when you need isolation.

Early and usable. Interfaces may still change.

## Install

Install the latest edge build on Linux or macOS:

```sh
curl -fsSL https://xaq.sh/install | sh
```

The installer verifies `SHA256SUMS` and writes the binary to `~/.local/bin`. Set `XAQ_INSTALL_DIR` to use another directory. Update it from the same rolling release with:

```sh
xaq update
```

For now, both commands use only the rolling [edge release](https://github.com/unlaboredlabs/xaq/releases/tag/edge). Edge tracks the latest successful `main` build and may change without notice.

To build from source, install Zig 0.16.0 and `curl`, then run:

```sh
git clone https://github.com/unlaboredlabs/xaq.git
cd xaq
zig build -Doptimize=ReleaseSmall
install -Dm755 zig-out/bin/xaq "$HOME/.local/bin/xaq"
```

## Authenticate

Log in to each provider you want to use:

```sh
xaq login chatgpt
xaq login claude
xaq login grok
```

ChatGPT and Claude use browser login. If the localhost callback page fails to load, copy its full address-bar URL or the authorization code back into `xaq`. Grok uses device-code login.

Already inside an interactive session? Run `/login` to connect or replace any provider login without leaving `xaq`.

Credentials live in `~/.config/xaq/auth.json`, written atomically with mode `0600`. Remove one with `xaq logout PROVIDER`. Anthropic may count third-party harness use as extra usage, so check your usage settings before relying on the included plan allowance.

## Use

Start an interactive session:

```sh
xaq
xaq --provider claude
xaq --provider grok
```

On a capable terminal, `xaq` opens a compact fullscreen view with a scrolling transcript, fixed prompt, status bars, command completion, and thread picker. While the agent is running, Enter steers it at the next safe model boundary and Alt+Enter queues a follow-up for after the current exchange. Both queues are FIFO; the status bar shows their pending counts. Mid-run input is a fullscreen feature; `--plain` and `XAQ_PLAIN=1` retain terminal type-ahead. Up and Down search prompt history using the text already typed, and Down restores the draft after the newest match. `ctrl-c` clears the prompt or interrupts active work; `ctrl-d` exits.

Type `@` to search project files, then use Up and Down to select one and Tab or Enter to insert its path. Tab also completes relative path tokens such as `src/ag`. The index is built on demand and stays in memory for the current prompt.

Tool activity stays in the info bar while it runs. Completed calls enter the transcript as dim one-line summaries such as `Read src/main.zig`, `Edited src/tui.zig · 2 edits`, or `Ran zig build test · 3.1s`. Three or more consecutive reads and web lookups collapse into one `Explored…` line; failures and file-changing actions always remain visible. `/verbose on` adds a bounded result preview.

Prefix a prompt with `!` to run a shell command directly. `!command` includes the command and output in model context; `!!command` runs it without adding either to context.

Type `/` to browse local commands:

| Command | What it does |
| --- | --- |
| `/login [PROVIDER]` | connect a ChatGPT, Claude, or Grok subscription |
| `/model [ID]` | choose a model |
| `/effort [LEVEL]` | set reasoning effort |
| `/fast [on\|off\|status]` | control the provider's premium speed tier |
| `/verbose [on\|off]` | show tool-result previews |
| `/firecrawl [status\|clear]` | configure web tools |
| `/agents` | list subagents |
| `/settings` | configure compaction and subagents |
| `/status` | show session and token details |
| `/compact` | compact context now |
| `/clear` | clear the current thread |
| `/new` | start a new conversation |
| `/resume [ID]` | resume a saved thread |
| `/rewind [TURNS]` | remove recent conversation turns, keeping file changes |
| `/fork` | copy the current conversation to a new thread |
| `/help` | list commands |
| `/exit` | leave `xaq` |

Run one prompt without opening a session:

```sh
xaq 'summarize this repository'
xaq --provider grok -p 'find and fix the failing test'
git diff | xaq 'review this patch'
```

Attach images with `-i` or `--image`. Repeat the option to send up to four images with one prompt:

```sh
xaq -i screenshot.png 'explain this error'
xaq -i before.png -i after.png 'compare these layouts'
```

In an interactive session, press `Ctrl-V` to attach an image from the desktop clipboard, or drop an image file into the prompt. Attached paths collapse to numbered markers such as `[Image #1]`. Linux clipboard paste uses `wl-paste` or `xclip`; dropped paths work without either utility. You can also type a path, prefixing a relative path with `@` when it could be mistaken for normal text, such as `@screenshots/error.png`. PNG, JPEG, GIF, and WebP files up to 5 MiB each are supported. Grok accepts PNG and JPEG only. Image attachments are saved in thread history, so resumed conversations keep them.

One-shot stdout contains only the answer, so it pipes cleanly. Tool traces go to stderr. A bare argument and `-p PROMPT` are equivalent; use `--` before a prompt that starts with `-`.

Use `--output-format json` when a script needs the final answer and run metadata as one JSON object:

```sh
xaq --output-format json 'review the staged changes' | jq -r '.text'
```

The object includes `text`, `stop_reason`, `provider`, `model`, `thread_id`, token `usage`, `num_turns`, and `tool_calls`. Use `--output-format streaming-json` for live JSONL events. Its event types are `start`, `turn_start`, `text`, `tool_call`, `tool_result`, `usage`, `end`, and `error`; `end` is the authoritative final result. Structured formats work only on one-shot runs and keep tool traces on stderr.

Override model behavior when needed:

```sh
xaq --model gpt-5.5 --effort high
xaq --fast 'solve the failing test'
```

The defaults are `gpt-5.6-sol`, `claude-opus-5`, and `grok-4.6`. Run `/model` for the curated choices. Exact model IDs also work, though `xaq` uses conservative context limits when it does not recognize one. Fast mode is available only on models whose subscription API supports it and consumes plan usage at a higher rate.

Run `xaq --help` for the complete CLI syntax.

## Threads and context

Interactive turns are saved as cwd-scoped JSONL under `~/.config/xaq/threads/`. Resume the latest thread with `xaq -c`, choose one with `/resume`, or list IDs with `xaq threads`. Resuming replays its user and assistant messages into the transcript. The newest 50 threads per directory are retained. Start with `xaq --no-save` to keep the conversation and its prompt history only in memory.

`/rewind` removes the latest user turn and everything after it from the transcript without reverting files. Pass a count to remove more turns. `/fork` copies the visible transcript into a new thread and makes that copy active, leaving the original unchanged.

At 80% of the selected model's subscription context window, `xaq` summarizes older history and keeps a recent tail verbatim. `/settings` changes the threshold, compaction model, effort, and subagent defaults.

`xaq` also loads `~/.config/xaq/AGENTS.md` and each `AGENTS.md` from the filesystem root to the working directory.

## Tools

The model receives four local tools:

| Tool | Purpose |
| --- | --- |
| `read` | read text files |
| `bash` | run commands |
| `edit` | replace exact text |
| `write` | create or overwrite files |

The parent agent can also start, inspect, and steer subagents. Workers are separate `xaq` processes in the same working directory, with up to four running at once by default. `/settings` can disable them or change the limit.

For web access, run `/firecrawl` and enter a [Firecrawl API key](https://www.firecrawl.dev/app/api-keys). This adds `web_fetch` and `web_search`. The key is stored in `~/.config/xaq/settings.json` with mode `0600`.

## Embed

The package exports a native Zig module named `xaq` for running the headless agent loop in-process:

```zig
const dep = b.dependency("xaq", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("xaq", dep.module("xaq"));
```

Create one `xaq.Agent` per conversation. The host can provide credentials, transport, tools, permissions, events, images, and initial history. Built-in filesystem and shell tools are off by default when embedded. The public contract is in [`src/embed.zig`](src/embed.zig) and currently has `api_version = 2`.

## Logging

Tracing is opt-in and excludes prompts, file contents, and credentials:

```sh
XAQ_LOG=1 xaq
XAQ_LOG=/tmp/xaq.log XAQ_LOG_SCOPES=usage,tool xaq
```

The default log is `~/.config/xaq/trace.log`. It rotates at 2 MiB.

## Develop

```sh
zig build check    # type-check without installing
zig build fmt      # format Zig sources
zig build test     # run tests
zig build perf     # enforce size and startup limits
```

CI checks formatting, tests, and release builds on Linux and macOS. The performance gate caps the stripped Linux x86_64 binary at 1 MiB and mean startup at 25 ms.

Minimalism is a project constraint. Proxy servers, MCP and plugin systems, internal sandboxes, session databases, themes, and full cell-grid TUI frameworks are deliberately out of scope. Open an issue before adding a new subsystem.

## Acknowledgments

- [Pi](https://github.com/earendil-works/pi) informed the tool contract, permission model, OAuth flows, and provider formats.
- [tintinweb/pi-subagents](https://github.com/tintinweb/pi-subagents) informed subagent coordination.
- [fx](https://github.com/vercel-labs/fx) informed fast-mode selection and trace logging.

## License

[MIT](LICENSE)
