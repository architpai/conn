# Conn web

Vercel-ready React + Vite landing page for Conn, built as a workspace inside
the native app repository.

```bash
pnpm install
pnpm web:dev
```

For Vercel, import the repository and set the Root Directory to `apps/web`. The framework preset is detected as Vite.

The interactive product surface lives in `src/App.tsx` and deliberately mirrors
the shipping v0.2.1 alpha: collapsed status, the visible Session sidebar,
Codex and Pi attribution, dismissal, grouped Runs, model visibility, the
composite model-and-reasoning control, and draft-first New Session flow.

Append `?banner=1` while running the site to render the dedicated 2560×1280
social/banner composition used by `.github/assets/conn-banner.png`.

The Codex badge uses OpenAI's official monochrome Blossom downloaded from the
OpenAI brand page. The Pi badge uses Pi's official upstream mark. They are
included as `public/openai-blossom.svg` and `public/pi-harness-badge.svg`,
remain unmodified, and match the assets packaged in the native adapters.
