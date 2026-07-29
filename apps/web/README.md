# Conn web

Vercel-ready React + Vite landing page for Conn, built as a workspace inside
the native app repository.

```bash
pnpm install
pnpm web:dev
```

For Vercel, import the repository and set the Root Directory to `apps/web`. The framework preset is detected as Vite.

The interactive product surface lives in `src/App.tsx` and deliberately mirrors
the shipping v0.2 alpha: collapsed status, the visible Session sidebar, grouped
Runs, harness identity, the composite model-and-reasoning control, and
draft-first New Session flow.

Append `?banner=1` while running the site to render the dedicated 2560×1280
social/banner composition used by `.github/assets/conn-banner.png`.

The Codex harness badge uses OpenAI's monochrome template mark from the
installed ChatGPT application bundle. It is included as
`public/openai-blossom.png` and must remain unmodified.
