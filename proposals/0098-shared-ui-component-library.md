## Shared UI Component Library for Prometheus and Alertmanager

* **Owners:**
  * @sysadmind

* **Implementation Status:** `Not implemented`

* **Related Issues and PRs:**
  * https://github.com/prometheus/alertmanager/pull/5031
  * https://github.com/prometheus/prometheus/pull/14872
  * https://github.com/prometheus/docs/pull/2656

* **Other docs or links:**
  * https://github.com/AndrejKiri/prometheus-design-system
  * https://github.com/prometheus-community/ux-research
  * https://prometheus.io/blog/2026/04/08/introducing-ux-research-working-group/
  * https://github.com/mantinedev/extension-template
  * https://www.npmjs.com/org/prometheus-io
  * https://github.com/prometheus/org-infra

> TL;DR: Prometheus and Alertmanager are both building new UIs on Mantine and React, and are already copying components between repositories by hand. We propose creating `prometheus/ui-common`, a new repository in the `prometheus/` GitHub org publishing `@prometheus-io/ui-common` to npm on independent semantic versioning, to hold the React components and design tokens shared by both UIs. The docs site behind prometheus.io, also a Mantine application, is a secondary consumer of the token layer.

## Why

Prometheus and Alertmanager are independently building web UIs on the same foundation: **Mantine 9 and React 19**. Prometheus's lives in [`web/ui/mantine-ui`](https://github.com/prometheus/prometheus/tree/main/web/ui/mantine-ui) and was released as part of Prometheus v3.0. Alertmanager's lives in [`ui/mantine-ui`](https://github.com/prometheus/alertmanager/tree/main/ui/mantine-ui), is served at `/ui/` alongside the legacy Elm app, and is still in early development.

That shared foundation is an opportunity but will get harder with time. Today the two codebases agree on their major dependencies, so a shared library is mostly a packaging exercise. Every component added to Alertmanager without one makes the eventual convergence more expensive, and the components being written now like badges, cards, layout shells, and filter controls are exactly the ones both projects need.

A third repository shares that foundation, if less directly. The [docs repo](https://github.com/prometheus/docs) that serves as the source for [prometheus.io](https://prometheus.io/) is a Next.js site built on Mantine (v8 as of this writing) and React 19. Its stake here is narrower and mostly one-directional: it is a documentation and marketing site, so it has little use for badges, filter controls, or data tables, and little to offer in the other direction beyond small utilities like a theme switcher.

Design tokens are the exception, and there the docs site is not a bystander but the current source of truth: its `src/theme.ts` is the only one of the three codebases that defines the Prometheus brand palette as code — an orange `prometheusColor` tuple set as `primaryColor` — while Prometheus's UI ships Mantine's default blue and Alertmanager's theme is an empty stub. Anyone walking from prometheus.io into the Prometheus UI and then into Alertmanager's crosses three different visual treatments of the same project. Sharing tokens with the docs site is what fixes that, and it is cheap: tokens can be consumed without the component layer. Prometheus and Alertmanager remain the primary beneficiaries of this proposal; the docs site is a secondary one that comes close to free.

This is not a hypothetical concern. Alertmanager's UI was seeded from Prometheus's, and the copies are still visibly copies:

* `ErrorBoundary.tsx`, `InfoPageCard.tsx`, and `InfoPageStack.tsx` exist in both repositories in near-identical form.
* `ThemeSelector.tsx` is duplicated between Prometheus's UI and the docs site, down to identical `aria-label` and `title` strings and the same three-way `light` → `dark` → `auto` cycle. The copies have already drifted: the docs version uses outline `IconSun`/`IconMoon` where Prometheus uses the filled variants, adds `variant="subtle"`, and sprinkles `suppressHydrationWarning` for Next.js SSR. Alertmanager has no theme selector at all yet.
* Alertmanager's `LabelPill.module.css` reproduces its `light-dark()` color values verbatim from Prometheus's `Badge.module.css`.
* Alertmanager's `src/data/api.ts` mirrors Prometheus's `src/api/api.ts`, adapted for Alertmanager's v2 API.

Sharing this code would also give the project's design work somewhere to land. The [Prometheus Design System](https://github.com/AndrejKiri/prometheus-design-system) is a proposal from one member of the UX Research Working Group, developed in a personal repository: it has produced design tokens, a Figma plugin, and specifications for 19 components, but it is not an official project artifact and contains no React source, so there is currently no vehicle to turn it into shipped UI. Adopting that work into a maintained repository as part of this proposal is what would make it official. It would provide a token set the project owns and every UI can depend on.

### Pitfalls of the current solution

The current solution is copy-paste, and it is already failing in ways that will get worse:

* **Fixes do not propagate.** A bug fixed in one repository's `ErrorBoundary` stays fixed only there. Nobody is notified that a copy exists elsewhere.
* **The copies drift on contact.** Alertmanager's copies were edited on arrival to remove an icon dependency. Each such edit makes the next sync harder and makes it less obvious the files were ever the same.
* **No shared visual language.** Components can be copied; design tokens cannot be copied usefully, because there is nothing to copy them from. Prometheus's theme is defined inline in `App.tsx` and sets no brand color, so the UI is Mantine-default blue. The docs site is the only one of the three with both a Prometheus-colored theme and a working color scheme toggle, and nothing connects it to the other two. The two UIs will look meaningfully different even where their components match, and neither looks like prometheus.io.
* **The toolchains are diverging with nothing pulling them back.** Both UIs are on Mantine 9 and React 19, but almost nothing else agrees:

  |                                    | Alertmanager `ui/mantine-ui` | Prometheus `web/ui`                                          | Docs `prometheus/docs`          |
  | ---------------------------------- | ---------------------------- | ------------------------------------------------------------ | ------------------------------- |
  | Mantine / React                    | 9 / 19                       | 9 / 19                                                       | 8 / 19                          |
  | Package manager                    | npm, no workspace            | pnpm workspaces                                              | npm, no workspace               |
  | Lint / format                      | Biome                        | ESLint 9 + Prettier                                          | ESLint 9 (`eslint-config-next`) |
  | Bundler / TypeScript / test runner | Vite 8 / 7 / Vitest 4        | Vite 6 / 5.9 / Vitest 3                                      | Next 16 / 5 / none              |
  | Theme                              | `src/theme.ts`, empty stub   | inline `createTheme` in `App.tsx`                            | `src/theme.ts`, brand palette   |
  | Dark mode                          | not implemented              | fully implemented                                            | fully implemented               |
  | Supply-chain `.npmrc`              | none                         | `allow-git=none`, `ignore-scripts=true`, `min-release-age=3` | none                            |

  The docs column is context, not a convergence target — it is a statically exported Next.js site rather than a Vite SPA, and its tooling should match Next's conventions. Its Mantine 8 pin is an upgrade for the docs repo to make before it adopts the token layer, not a constraint on the library.

* **Contributors cannot move between the two.** Someone who has learned the Prometheus UI has to relearn the tooling, lint rules, and test setup to fix the same bug in Alertmanager.

## Goals

* One implementation and one visual language for the components both UIs need.
* **Independent semantic versioning**, so each consumer upgrades on its own cadence and breaking changes can actually be signalled.
* Distribution that satisfies the supply-chain policy Prometheus already enforces — packages come from the npm registry, not from git.
* A place for design tokens to live as code, so the design system work has a delivery path and prometheus.io, Prometheus, and Alertmanager can converge on one visual language.
* Cross-repository friction no worse than the existing Go workflow around [`prometheus/common`](https://github.com/prometheus/common).

### Audience

* **Maintainers and contributors of the Prometheus and Alertmanager web UIs** — the primary audience, and the ones this proposal is addressed to.
* **The [UX Research Working Group](https://github.com/prometheus-community/ux-research)** — a stakeholder and the natural venue for design review; per its charter it explicitly does not own technical direction.
* **[Docs repo](https://github.com/prometheus/docs) maintainers** — a secondary audience: the token layer is meant for them, the component layer mostly is not.

## Non-Goals

* **A supported public product.** In v0 the consumers are Prometheus and Alertmanager, with the docs site expected to consume tokens only. Other projects may use it, but API stability guarantees and support for third-party consumers are out of scope until there is reason to take that on.
* **A component library for prometheus.io.** The docs site is expected to adopt the token layer, and may pick up a shared utility where one happens to fit. Its component needs do not drive the library's API, and it is not a reason to delay anything.
* **A rewrite** of either UI. Adoption is incremental and per-component. Alertmanager has its own roadmap for its UI rewrite.
* **A home for components with a single consumer.** Components coupled to one project's API types or data model like `ReadinessWrapper`, `ScrapePoolConfig`, `RuleDefinition`, everything under `pages/query/` stay where they are. This is about consumer count and API coupling, not subject matter: shared ecosystem concepts like label rendering are in scope precisely because both projects implement them.
* **A replacement** for `@prometheus-io/codemirror-promql` or `@prometheus-io/lezer-promql`.
* **A general-purpose design system** for projects outside the Prometheus ecosystem.
* **A Mantine fork.** The library extends Mantine; it does not wrap or replace it.

## How

Create **`prometheus/ui-common`**, Apache-2.0 licensed, publishing **`@prometheus-io/ui-common`** to npm.

### Repository and package

The `@prometheus-io` npm scope [already exists and is controlled by the project](https://www.npmjs.com/org/prometheus-io) — it publishes `codemirror-promql`, `lezer-promql`, and `client`, with `prombot` among its maintainers. This proposal therefore needs **no new npm scope**, only publish access for a new repository.

The repository is created by pull request to [`prometheus/org-infra`](https://github.com/prometheus/org-infra), which manages the org's GitHub configuration as Terraform with one `repo-<org>-<name>.tf` file per repository.

### Versioning

The library uses **independent semantic versioning**, starting at `0.x` while the API is unstable. This is the single most important property of the design, and the main reason for a separate repository rather than a package inside Prometheus's existing UI workspace. See [Alternatives](#alternatives).

### Packaging

Scaffold from [`mantinedev/extension-template`](https://github.com/mantinedev/extension-template), Mantine's official, actively-maintained template for libraries built on Mantine. It establishes the conventions that matter:

* **`react`, `react-dom`, `@mantine/core`, and `@mantine/hooks` are `peerDependencies` and `devDependencies` — never `dependencies`.** This is what prevents consumers from ending up with two copies of React and the "Invalid hook call" failures that follow. Peer ranges stay loose (`^18.x || ^19.x` for React, `>=9.0.0 <10` for Mantine).
* Compiled ESM and CJS output plus generated `.d.ts`, with all dependencies and peer dependencies externalized.
* CSS Modules compiled to a hashed-class stylesheet, exposed at a `./styles.css` subpath export, with `sideEffects: ["*.css"]` so bundlers do not drop it.

### Design tokens

The library exports a token layer alongside its components: CSS custom properties plus a `createPrometheusTheme()` function returning a Mantine theme, so the applications share colors, radii, spacing, and typography by construction rather than by convention. The token layer depends on Mantine but not on the component layer, so a consumer can adopt tokens alone.

Tokens are seeded from the [Prometheus Design System](https://github.com/AndrejKiri/prometheus-design-system) work, which has already produced a token set and component specifications.

Adopting the token layer is how the Prometheus brand palette stops being a local detail of the docs repository.

### Toolchain alignment

Aligning the two UIs' toolchains is a **goal of this proposal, not a precondition for it**. The docs site is not part of that alignment — a Next.js site should follow Next's conventions — and consumes the library as a published package like any other dependency. Because the library ships compiled output and type declarations behind peer dependencies, npm-based Alertmanager and pnpm-based Prometheus can both consume it today without either changing anything.

Convergence is still worth pursuing, for contributor mobility, for a working local development loop, and to make shared lint and TypeScript configuration possible. We propose the library itself use **pnpm** (matching the larger consumer, and because pnpm's `file:` protocol resolves peer dependencies from the consuming project correctly, which `pnpm link` does not) and **Biome** (already proven in Alertmanager, and a single tool in place of ESLint, Prettier, and stylelint). Consumers converge over time.

### TypeScript version skew

Alertmanager is on TypeScript 7 and Prometheus on 5.9, with the docs site also on 5.x. The library emits conservative declaration files and tests against **both** ends of that range in CI, so that supporting the older consumer is a checked property rather than an assumption. The minimum supported TypeScript version is documented and treated as part of the public API.

### Local development loop

Requiring two pull requests to land a change is the main cost of a separate repository, and the main objection to this proposal. It cannot be eliminated — it is the same tradeoff the project already accepts for `prometheus/common` in Go — but it can be kept to iterating on a change, not on the library plumbing. `CONTRIBUTING.md` documents:

* `resolve.dedupe: ['react', 'react-dom', '@mantine/core', '@mantine/hooks']` in both consumers' Vite configs, which is what makes a linked library resolve to a single React copy.
* pnpm's `file:` protocol for Prometheus, and `npm link` plus `npm link ../<app>/node_modules/react` for Alertmanager.
* [`yalc`](https://github.com/wclr/yalc) as a package-manager-agnostic fallback; it copies the publishable file set instead of symlinking, avoiding the resolution problems entirely.

### Releasing

Releases are tag-triggered and publish with `pnpm publish --access public`, using **npm trusted publishing via OIDC** — the same mechanism Prometheus's `publish_ui_release` job already uses, requiring `id-token: write` and no long-lived npm token in repository secrets.

### Testing and verification

* Storybook for component development and visual review, giving the UX WG something concrete to review against.
* Vitest and Testing Library, plus `jest-axe` for accessibility assertions.
* A CI matrix covering both consumers' TypeScript versions.
* A canary job building both Prometheus's and Alertmanager's UIs against the library's `main`, so breakage is caught before a release rather than after. Once the docs site consumes tokens, its build joins the canary: it is the only consumer that exercises the package under server rendering.

### Initial scope plan

Version `0.1.0` ships only components that are **already duplicated or trivially generic**, so the first release carries no design risk: `ErrorBoundary`, `InfoPageCard`, `InfoPageStack`, `CustomInfiniteScroll`, and `ThemeSelector`.

`ThemeSelector` is the one of these with three interested parties: Prometheus has it, the docs site has a drifted copy, and Alertmanager needs it as soon as it has dark mode. It is also the smallest component whose shared version has to survive server rendering, so it is a useful first test of the `"use client"` and hydration handling.

Label rendering follows in `0.2.0`, and is a useful illustration of why this is design work rather than only packaging. The two projects have solved the same problem incompatibly:

* Alertmanager's `LabelPill` renders one label, extends Mantine's `PillProps` so `withRemoveButton` and `onRemove` come for free, and does no escaping or quoting.
* Prometheus's `LabelBadges` takes a `Record<string, string>` and deliberately renders a plain `<span>` per label rather than a Mantine `Badge`, for performance — its stylesheet notes that Prometheus "has pages with thousands of labels". It escapes values and quotes non-identifier label names.

A shared component has to serve both the interactive, removable case and the thousands-of-labels case. Reconciling these in the open, once, is precisely the value this proposal is arguing for.

### Known unknowns

* Whether Alertmanager adopts Prometheus's `.npmrc` supply-chain posture. It has none today.
* Whether the docs site adopts the token layer, and when it upgrades to Mantine 9.
* Whether the repository stays a single package or grows into a small workspace (for example splitting tokens from components) as the token layer matures.

## Alternatives

### 1. Do nothing and keep copying

Cheapest today and requires no coordination. Rejected because the costs above are already being paid, compound with every component added, and the design token problem is never solved by copying — there is nothing to copy from.

### 2. Depend on the library via a git URL

[npm supports git URLs as dependencies](https://docs.npmjs.com/cli/v10/configuring-npm/package-json#git-urls-as-dependencies), which would let consumers track a commit directly and avoid publishing. This was the initial idea behind this proposal, and it does not survive contact with the project's existing policy.

Prometheus's `web/ui/.npmrc` sets `allow-git=none`, with the reasoning stated in the file itself:

> Prevent installing packages sourced directly from git. Such packages bypass registry integrity checks and can ship their own .npmrc that re-enables lifecycle scripts, silently defeating ignore-scripts above.

The same file sets `ignore-scripts=true`, which independently breaks this approach: a source-only git dependency needs its `prepare` script to build on install, and that script will not run. Adopting git dependencies would mean reversing a deliberate, recently-reasoned security decision.

There are further problems even setting policy aside. Renovate classifies branch-reference git dependencies as `unversioned-reference` and never updates them, so the dependency silently stops receiving updates. Installing requires live access to GitHub at build time, which registry mirrors do not proxy, weakening reproducibility of release builds.

### 3. A package inside `prometheus/prometheus/web/ui/module/`

This is the strongest alternative, and has real precedent: `prometheus/codemirror-promql` and `prometheus/lezer-promql` were standalone repositories that were archived and folded into Prometheus's UI workspace, where they continue to publish to npm under `@prometheus-io`. It would require no new repository and no governance approval, and would reuse a publishing pipeline that already works.

It is rejected because that workspace **forces version lockstep with Prometheus itself**:

* `scripts/ui_release.sh` bumps versions with `pnpm -r --include-workspace-root version`, commented in-file as "increase the version on all packages in the pnpm workspace". Every package moves together.
* `scripts/get_module_version.sh` derives that version from the Prometheus release version — Prometheus 3.14.0 becomes npm `0.314.0`.
* CI publishes only on `refs/tags/v2.*` and `v3.*`, so the library can only ship when Prometheus ships.
* `min-release-age=3` then blocks consuming a freshly published version for three days.

A component library under those rules gets versions that encode a Prometheus release number and nothing about its own compatibility. **Semantic versioning stops working**: there is no way to signal a breaking change to a component, and no way for Alertmanager to distinguish a safe upgrade from a risky one. Alertmanager would also be able to receive component changes only on Prometheus's release cadence, which is a poor arrangement for a library whose entire purpose is serving two consumers equally. The docs site makes this stranger still: prometheus.io would be taking the project's brand palette from a package numbered after a Prometheus server release.

The `codemirror-promql` precedent does not transfer. PromQL grammar genuinely *is* a Prometheus-versioned artifact — pinning it to the Prometheus release is correct and informative. A button is not.

### 4. git subtree or submodule

Vendoring the source avoids install-time network access. Rejected because subtrees provide no versioning at all — there is no way to express "Alertmanager is on an older, working version" — and impose a manual sync ritual that is exactly the copy-paste problem with extra steps. Submodules additionally require `--recursive` clones for every downstream builder.

### 5. A shadcn-style source registry

[shadcn/ui](https://ui.shadcn.com/docs/registry) distributes components as source files that consumers copy into their own tree and then own, and the tooling for hosting a custom registry is real and mature. Mantine's own [ui.mantine.dev](https://github.com/mantinedev/ui.mantine.dev) follows this model.

Rejected as the primary mechanism because there is no upgrade path: once a component is copied, fixes do not propagate, which is the problem this proposal exists to solve. It remains a reasonable complement later for *patterns* — larger, composed layouts that each application is expected to adapt.

### 6. A single monorepo containing both UIs

Would remove cross-repository friction entirely. Rejected as disproportionate: both UIs are embedded into Go release artifacts with independent release cadences and separate maintainer groups.

## Action Plan

* [ ] Land this proposal. Socialize with the UX WG for design input, and with the docs maintainers on the token layer.
* [ ] Open an `org-infra` pull request creating `prometheus/ui-common`; grant `@prometheus-io` publish access.
* [ ] Scaffold from `mantinedev/extension-template`; set up CI, Storybook, and OIDC publishing.
* [ ] Release `0.1.0` with `ErrorBoundary`, `InfoPageCard`, `InfoPageStack`, `CustomInfiniteScroll`, `ThemeSelector`; adopt in both UIs.
* [ ] Document the local development loop in `CONTRIBUTING.md`
* [ ] Reconcile `LabelPill` and `LabelBadges`; release `0.2.0`.
* [ ] Add the token layer and `createPrometheusTheme()`; adopt in Alertmanager, implementing dark mode.
* [ ] Offer the tokens-only export to `prometheus/docs`, seeded from its existing brand palette.
* [ ] Align toolchains between the two UIs.
