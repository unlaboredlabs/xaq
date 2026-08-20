# xaq.sh

Landing page for `xaq`, built with Next.js 16 (App Router, Turbopack) and Tailwind v4 in a pnpm workspace.

```sh
pnpm install            # from repo root
pnpm dev                # http://localhost:3000
pnpm dev --host         # bind 0.0.0.0 (also --host <addr>)
pnpm lint
pnpm typecheck
pnpm test
pnpm build
```

A single minimal page (`components/landing.tsx`): dark shell transcript — `$ xaq`, tagline, click-to-copy install line, blinking cursor. Copy lives in `lib/content.ts`.

`/install` redirects to the raw `install.sh`, configured in `next.config.ts` (this replaced the old root `vercel.json`). When deploying to Vercel, set the project **Root Directory** to `apps/web` before merging — otherwise the `/install` redirect drops until the setting is flipped.
