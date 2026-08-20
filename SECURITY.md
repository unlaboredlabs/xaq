# Security

## Reporting a vulnerability

Report vulnerabilities privately via [GitHub private vulnerability reporting](https://github.com/unlaboredlabs/xaq/security/advisories/new). If that is unavailable, email hello@unlabored.net. Do not open public issues for security reports.

Only the latest [edge release](https://github.com/unlaboredlabs/xaq/releases/tag/edge) is supported. Fixes ship through the normal edge pipeline.

## Threat model

`xaq` runs with the full permissions of its user. It can execute commands and read, create, or overwrite any accessible file. There is no approval prompt or internal sandbox — this is by design, not a vulnerability. Use a container or restricted account when you need isolation.

Reports we do treat as vulnerabilities:

- **Credential exposure.** OAuth tokens live in `~/.config/xaq/auth.json` and the Firecrawl key in `~/.config/xaq/settings.json`, both written atomically with mode `0600`. Anything that leaks their contents to logs, other users, or unintended network destinations is a bug.
- **Logging leaks.** Tracing (`XAQ_LOG`) is opt-in and must exclude prompts, file contents, and credentials.
- **Installer and updater integrity.** `install.sh` and `xaq update` verify the release manifest and SHA-256 checksums. Anything that lets a tampered binary pass verification is a bug.
- **Memory-safety or parsing issues** reachable from untrusted input: provider responses, model output, or files read by tools.
