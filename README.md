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
- text conversations held in memory for the life of the process
- direct provider OAuth and APIs—CLIProxyAPI is neither used nor supported
- sequential tool execution and buffered provider responses

## Requirements

- Zig 0.16.0 to build
- `curl` on `PATH` at runtime
- Linux or macOS; Windows has not been tested

`curl` supplies the platform HTTPS/TLS implementation. OAuth, request construction, SSE parsing, the agent loop, and all tools are Zig code. A release-small Linux x86_64 build is approximately 300 KiB.

## Build

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

ChatGPT and Grok use device-code login. Claude prints a browser URL and asks you to paste the final redirect URL or authorization code.

Credentials are stored in `~/.config/xaq/auth.json`. The file is forced to mode `0600`, and expired access tokens are refreshed automatically.

Claude subscription behavior follows Pi's direct OAuth flow. Pi notes that third-party harness use may draw from Anthropic's **extra usage** billing rather than the included plan allowance. Check your Anthropic usage settings before relying on it.

## Use

Start an interactive conversation:

```sh
xaq
xaq --provider claude
xaq --provider grok
```

Run a one-shot prompt:

```sh
xaq -p 'summarize this repository'
xaq --provider grok -p 'find and fix the failing test'
```

Override the provider's default model when needed:

```sh
xaq --provider chatgpt --model gpt-5.6-sol
```

Current defaults follow Pi's provider choices at the time of implementation:

| Provider | Default model |
| --- | --- |
| `chatgpt` | `gpt-5.5` |
| `claude` | `claude-opus-4-8` |
| `grok` | `grok-4.6` |

Subscription model catalogs change independently of `xaq`; use `--model` if a default is no longer available to your account.

## Tool contract

The default tool surface matches Pi:

| Tool | Purpose |
| --- | --- |
| `read` | Read a text file with optional line offset and limit |
| `bash` | Run a shell command in the current working directory |
| `edit` | Apply one or more exact, non-overlapping text replacements |
| `write` | Create or overwrite a text file, including parent directories |

Relative and absolute paths are accepted. `bash` inherits the process environment. Tool output is capped at 50 KiB, with file reads limited to 2,000 lines by default.

## Design boundary

Minimalism is a constraint, not a placeholder. Additions should demonstrate measured value greater than their implementation and maintenance cost. The following are deliberately out of scope:

- an embedded API proxy or compatibility server
- MCP and plugin systems
- internal sandboxes, approval policies, and permission profiles
- plan, “yolo,” or other operating modes
- persistent session databases and bundled model catalogs
- themes or a full-screen terminal UI

## Development

```sh
zig fmt --check build.zig src/*.zig
zig build test
zig build -Doptimize=ReleaseSmall
```

Keep changes small, dependency-free, and directly related to the coding loop. Open an issue before adding a new subsystem.

## Acknowledgments

- [Pi](https://github.com/earendil-works/pi) informed the four-tool contract, full-permission security model, subscription OAuth flows, and provider wire formats.
- [OpenAI authentication documentation](https://learn.chatgpt.com/docs/auth) documents ChatGPT subscription sign-in for Codex clients.

The implementation was written for this project; no CLIProxyAPI code is included.

## License

[MIT](LICENSE)
