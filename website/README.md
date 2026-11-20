# Silta website

The public landing page for Silta, published with GitHub Pages at
<https://valtteriluomapareto.github.io/silta/>. It is a static [Astro](https://astro.build)
site with plain CSS and no UI framework, and it ships no JavaScript except the Copy
button in the closing section.

The design source is the Paper file "Silta", page "Website", with two artboards:
"Landing — Desktop" (1440 wide) and "Landing — Mobile" (390 wide). The site matches
both widths and adapts between them.

## Prerequisites

Node 24.22.3, as pinned in [`.nvmrc`](.nvmrc), which CI reads too (`nvm use` picks it
up). Astro itself needs Node 22.23.4 or later. Nothing else: the site does not need the Swift
toolchain.

## Commands

Run every command from `website/`. Start with `npm ci`, which installs exactly what
`package-lock.json` pins.

| Command | What it does |
|---|---|
| `npm run dev` | Dev server with hot reload at <http://localhost:4321/silta/> |
| `npm run build` | Static build into `dist/` |
| `npm run preview` | Serves `dist/` at <http://localhost:4321/silta/>, as Pages would |
| `npm run check` | `astro check`: TypeScript and template diagnostics |
| `npm run validate` | Prettier check, `astro check`, then the build: the gate CI runs |
| `npm run format` | Formats every file with Prettier |

Run `npm run validate` before pushing. It ends with `scripts/check-dist.mjs`, which
checks that every internal link and asset in `dist/` sits under the base path and
resolves, fragments included. A website-only change doesn't need `scripts/verify.sh`.
`scripts/run-guards.sh` checks this README's links and, through
`check_website_links.py`, the `blob()` links in `src/consts.ts` and the asset copies;
CI's website build runs those two guards on Linux.

## Layout

| Path | What it holds |
|---|---|
| `src/pages/index.astro` | The landing page: the sections in order |
| `src/pages/404.astro` | The not-found page Pages serves for unknown paths |
| `src/layouts/MarketingLayout.astro` | `<head>`: title, description, canonical URL, OpenGraph, Twitter card, JSON-LD and fonts; the skip link and `<main>` |
| `src/components/` | One component per section, in page order: `Nav`, `Hero`, `TrustBar`, `Why`, `HowItWorks`, `Features`, `LocalBand`, `OpenSource`, `ClosingCTA`, `Footer`; plus `Terminal` (the dark terminal window), `Wordmark` and `GitHubIcon` |
| `src/styles/site.css` | Design tokens, base styles and shared classes (`.container`, `.eyebrow`, `.section-header`, `.card`, `.card-grid`, `.arrow-link`) |
| `src/consts.ts` | Every outbound link, and the command the Copy button copies |
| `src/utils.ts` | `withBase()`, which prefixes the Pages base path |
| `public/` | Files served as they are: the mark (favicon) and the Board screenshot (hero and OpenGraph image) |
| `astro.config.mjs` | `site` and `base`, derived from `GITHUB_REPOSITORY`; the sitemap |

Component styles are scoped in each component's `<style>` block. A style used by
more than one section belongs in `site.css`.

## Design tokens

Each Paper design token is a custom property in `src/styles/site.css` with the same
name and value: `--color-*`, `--font-*`, `--text-*`, `--tracking-*`, `--breakpoint-*`,
`--container-*`, `--spacing-*` and `--radius-*`. The only additions are font fallbacks
and a few site-only values at the end of `:root`, such as `--page-gutter`.

| Paper | CSS |
|---|---|
| `--font-sans: "Inter"` | `'Inter Variable'` from `@fontsource-variable/inter/opsz.css`, then system fallbacks |
| `--font-mono: "JetBrains Mono"` | `'JetBrains Mono Variable'` from `@fontsource-variable/jetbrains-mono`, then system fallbacks |
| Hex with alpha, such as `#0E1C2238` | `rgb(14 28 34 / 22%)` |
| Inline sizes that are not tokens, such as the 30px band title | Literal values in the component |

Inter must load with its optical-size axis (the `opsz.css` entry). Without it,
display text sets about 5% wider than in Paper, and headings wrap differently.

To update the tokens after a design change, read them from Paper with
`get_tokens` (CSS format) and copy the changed values into `:root`. For a layout
change, read the artboard with `get_jsx` and `get_computed_styles`, not from a
screenshot. The desktop values apply from 1200 px for the hero and from 1080 px for
the two-column steps, the open-source card and the three-column grids. The mobile
values apply below 768 px.

## Updating copy

Copy lives in the component of its section. Lists that repeat a shape (problems,
steps, features, trust items) are arrays in the component's frontmatter. Terminal
transcripts are `Line[]` arrays; `Terminal.astro` explains the segment format.

Copy states only what Silta does today. Check a claim against the
[README](../README.md) and the [spec](../docs/spec.md) before publishing it, and keep
example names in the fictional Acme workspace. Command transcripts follow the README's
[worked example](../README.md#a-change-of-watch). Update the Paper design in the same
change, so the design stays the source of truth.

Outbound links point at files on `main` in this repository. Change them in
`src/consts.ts`.

## Screenshots and images

`public/board-light.png` is a copy of `docs/assets/board-light.png`, and
`public/silta-mark-light.svg` a copy of `docs/assets/silta-mark-light.svg`. The site
never links into `docs/`. When an asset in `docs/assets/` changes, copy it here in the
same change.

The Board screenshots are offscreen renders of the Debug `v2` fixture, made with
`-SiltaSnapshot` and the `board` route (`-SiltaDark` for `board-dark.png`), with the
snapshot's real `sidebar.png` composited in, at 1600 × 956. The
[Mac control-plane guide](../docs/mac-app-control.md#fixture-and-offscreen-output)
covers the flags, routes and output files. The hero crops the screenshot from the top
left, so keep the board's first columns in that corner. The mark is drawn from the app
icon layers; see [app-icon.md](../docs/app-icon.md).

## Deploys

[`website-build.yml`](../.github/workflows/website-build.yml) runs `npm ci`,
`npm run validate` and the markdown link guard. CI runs it for pull requests that touch
the website ([CONTRIBUTING](../CONTRIBUTING.md#commands) says when).
[`website.yml`](../.github/workflows/website.yml) runs it again and deploys `dist/` to
GitHub Pages:

- **Push to `main`:** a merge that changed `website/` or either website workflow
  builds and deploys. Runs share the `pages` concurrency group, so a newer run waits
  and a deploy is never cancelled halfway.
- **Manual:** run the "Website" workflow on `main` from the Actions tab to rebuild and
  deploy.

`astro.config.mjs` derives the URL from `GITHUB_REPOSITORY`: the site is
`https://<owner>.github.io` and the base path is `/<repo>`. A local build uses
`valtteriluomapareto/silta`. Every internal link and asset path goes through
`withBase()` or is relative, so the site works under the base path.

Pages must deploy from GitHub Actions: Settings → Pages → Build and deployment →
Source → "GitHub Actions". The first deploy creates the `github-pages` environment.
