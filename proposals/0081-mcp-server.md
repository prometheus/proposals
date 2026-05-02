## Prometheus MCP Server

* **Owners:**
  * @tjhop

* **Implementation Status:** `Implemented`

* **Related Issues and PRs:**
  * https://github.com/prometheus/proposals/issues/57

* **Other docs or links:**
  * https://github.com/tjhop/prometheus-mcp-server/
  * https://modelcontextprotocol.io/
  * https://github.com/prometheus/governance/pull/1

> TL;DR: Adopt [`tjhop/prometheus-mcp-server`](https://github.com/tjhop/prometheus-mcp-server/) into the `prometheus/` GitHub org as the official Prometheus MCP server, so that developers and AI agents have a canonical, Prometheus-API-complete, ecosystem-native way to interact with Prometheus.

## Why

[Model Context Protocol (MCP)](https://modelcontextprotocol.io/) has rapidly become the de-facto way for LLMs/agents to interact with external systems. Prometheus is a natural fit: it has a stable, well-documented HTTP API with strong semantics around metrics, labels, and queries that provide the kind of surface agents do well with.

In practice, users wanting to use AI agents against Prometheus today are already doing this — they just don't have a clear, project-blessed path. Several MCP servers for Prometheus exist (see [Alternatives](#alternatives)), each with different scope, implementation language, and quality. Without an official option, the community is fragmenting effort across competing implementations, none of which are owned by the Prometheus project itself.

Adopting an official server lets us:

* Give users a single, recommended choice that uses first-party Prometheus libraries and matches Prometheus' release/quality conventions.
* Concentrate ecosystem contributions (features, bug fixes, security review) onto one project rather than splitting them across implementations.

### Pitfalls of the current solution

The "current solution" is users search on Google or an MCP catalogue site and pick something.

Concrete problems:

* **Fragmented quality:** Existing third-party MCP servers vary widely in API coverage, transport support, HTTP client configuration, MCP support, and feature set. Most cover only `query` / `range_query` / `labels`, providing basic query interactions but that's it.
* **Drift from Prometheus conventions:** Implementations that don't use `client_golang`, `prometheus/common`, `exporter-toolkit`, etc. tend to re-invent HTTP config, validation, and observability — and re-invent them differently each time.
* **No upstream signal:** When a maintainer or user is asked "which Prometheus MCP server should I use?", there is no project-level answer. This pushes the evaluation burden onto every user individually.
* **Vendor bias:** Some are tied to specific offerings (e.g. AWS Managed Prometheus, Grafana). They're useful in those contexts but are not appropriate as an "official" recommendation from the Prometheus project.

## Goals

Goals and use cases for the solution as proposed in [How](#how):

* Provide Prometheus users with a canonical MCP server implementation to enable integrating agents with Prometheus.
* Provide Prometheus developers with a single implementation to consolidate and focus efforts into one solution.
* Provide a reference MCP implementation for vendors and managed service offerings who want to build their own.

### Audience

* **Prometheus users** who want to use LLM-based agents (Claude, Gemini, ChatGPT, local models, IDE assistants, on-call copilots, etc.) to investigate and analyze metrics, summarize alerts, investigate system health, etc.
* **Tooling authors** building higher-level AI-driven observability tooling who want a stable Prometheus integration to build on.
* **Prometheus maintainers and the Prometheus team** who currently get asked "which MCP server should I use?" with no canonical answer.

## Non-Goals

* **Bundling the MCP server into `prometheus/prometheus` itself.** This may be desirable in the future (this has already been brought up by both @metalmatze and @roidelapluie) — it is intentionally out of scope for this proposal. This proposal only covers adopting the standalone server. Similar to promlens, we can consider folding it into Prometheus itself down the road.
* **Forcing a single implementation onto the ecosystem.** Other MCP servers (vendor-specific, language-specific, agent-framework-specific) can and should continue to exist. This proposal is about which one the Prometheus project itself maintains and recommends.
* **Designing a new MCP server from scratch.** This project was created from day one as "if there were an official Prometheus MCP server, what would it look like?". It already uses existing code patterns and first party libraries where appropriate.
* **Defining the long-term policy for AI/LLM tooling in the Prometheus org.** That's a broader conversation. This proposal is one concrete step.
* **Migrating users from other MCP servers.** Users on `pab1it0/prometheus-mcp-server`, `mcp-grafana`, or AWS' implementation can stay where they are; the official server is additive.

## How

### What we're adopting

Adopt [`tjhop/prometheus-mcp-server`](https://github.com/tjhop/prometheus-mcp-server/) into the `prometheus/` GitHub org and make it the official Prometheus MCP server. @tjhop volunteers to continue leading development and maintenance, help is welcome.

The relevant details of the existing implementation:

* **Language:** Go.
* **Prometheus API coverage:** all stable Prometheus HTTP API endpoints are exposed as MCP tools, including query, range query, series/labels/metadata, targets, rules, alerts, alertmanagers, runtime/build/flags/config, TSDB stats, WAL replay, and management endpoints (`/-/healthy`, `/-/ready`, `/-/reload`, `/-/quit`).
* **TSDB admin endpoints** (`delete_series`, `clean_tombstones`, `snapshot`) are gated behind an explicit `--dangerous.enable-tsdb-admin-tools` flag and are off by default.
* **Configurable tool registration:** a small "core" toolset is always loaded; everything else can be allow-listed via `--mcp.tools`, so operators can tune what gets exposed to smaller-context LLMs.
* **Transports:** stdio, SSE, and streamable HTTP.
* **HTTP client configuration:** standard Prometheus HTTP config file, including bearer tokens, basic auth, mTLS, custom headers, etc. — i.e. it works with multi-tenant setups (Mimir/Cortex/GrafanaCloud) and TLS-protected Prometheus servers without bespoke flags.
* **Backend awareness:** `--prometheus.backend` selects per-backend behavior. Today that means a `thanos` backend that hides endpoints Thanos doesn't implement and adds a `list_stores` tool. The same mechanism is the path forward for Mimir/Cortex support.
* **First-party libraries:** For Prometheus, we use `client_golang` for the API client and self-instrumentation, `prometheus/common` for config and structured logging, `exporter-toolkit` for flags / web. For MCP support, we use the official `modelcontextprotocol/go-sdk`.
* **Observability:** native Prometheus metrics endpoint plus structured logs, so operators can monitor the MCP server itself.
* **Token-efficiency knobs:** optional [TOON](https://github.com/toon-format/toon) output, optional response truncation (with per-tool overrides) — both off by default.
* **Docs tools:** tools `docs_list` / `docs_read` / `docs_search` provide access to docs. The server embeds Prometheus' documentation repo to ground knowledge/queries in best practices and proper docs, and can optionally auto-update documentation in-memory.
* **Distribution:** release artifacts, container images, system packages, Helm chart, and example k8s manifests. Tooling will need to be converted from current docker/goreleaser builds to use Prometheus build/CI tooling and conventions like `promu`, etc.
* **Tests:** Go tests are present and growing; this was called out as a "con" in the original issue but has since been improved (to the point where it's thorough enough to [catch changes in behavior of the upstream go sdk](https://github.com/tjhop/prometheus-mcp-server/pull/121)).

### Why this implementation specifically

The technical case for picking this server:

* **Prometheus-API-complete.** Every stable Prometheus HTTP API endpoint is exposed as a tool.
* **Ecosystem-native.** Written in Go and built on first-party Prometheus libraries (`client_golang`, `common`, `exporter-toolkit`), so it inherits Prometheus' HTTP client config, config-file loading, flag handling, structured logging, and self-instrumentation rather than re-implementing.
* **Safe defaults.** Destructive TSDB admin endpoints are gated behind an explicit `--dangerous.enable-tsdb-admin-tools` flag; tool exposure can be narrowed via `--mcp.tools` for smaller-context LLMs.
* **Comprehensive.** Beyond API coverage, there's broad coverage for MCP options like client notification logging, tunables for loading different toolsets for backends/context usage, JSON/TOON output formats, result truncation, etc.
* **Backend-aware extension point.** The `--prometheus.backend` mechanism already accommodates Prometheus-compatible systems that diverge from upstream (e.g. the existing `thanos` backend), giving us a clean extension point for future Mimir/Cortex tools without polluting the default behavior.
* **Built in documentation.** The MCP server embeds a checkout of the official Prometheus documentation and can automatically update docs in-memory to ground agents in first party knowledge and best practices.
* **Highly tuned embedded system prompt.** The MCP server has embedded instructions that teach the agent/client about the tools available and how to use them, query patterns, workflow examples, and provide general best practices for working with Prometheus.

### Where it should live

As noted in the comments on #57, several maintainers have already suggested it live under `prometheus/`.

### Testing and verification

* CI works, test suites continue to run, artifacts continue to publish, etc.

### Known unknowns

* **Recording/alerting rule management.** Prometheus manages rules via files, not through the HTTP API. This is a common request, but we lack official support to manage rules. I have fielded proposals that involved shelling out and doing other shenanigans to try and provide support, but that also assumes the MCP server is running on the same instance as Prometheus and using the same disk/filesystem. Without official API support, I'm hesitant to provide support for this.

## Alternatives

1. **Adopt [`pab1it0/prometheus-mcp-server`](https://github.com/pab1it0/prometheus-mcp-server/) instead.** It's the most popular Prometheus MCP server today and is straightforward Python. Why we don't: it's not Prometheus-API-complete, has limited HTTP client configuration, and isn't built on Prometheus' first-party libraries (which are Go). Adopting it would either mean significant rewrites or accepting weaker integration with the rest of the ecosystem.

2. **Defer to [`grafana/mcp-grafana`](https://github.com/grafana/mcp-grafana).** Already maintained, has corporate backing, supports Prometheus querying via Grafana datasources. Why we don't: it requires Grafana, scopes Prometheus access through Grafana datasources rather than directly, is not Prometheus-API-complete, and is appropriately not aligned with the Prometheus project's governance.

3. **Adopt [`awslabs/mcp/src/prometheus-mcp-server`](https://github.com/awslabs/mcp/tree/main/src/prometheus-mcp-server).** Why we don't: it's specific to Amazon Managed Prometheus (workspace construct, AWS auth), and its toolset is currently limited to query and label name listing. The AMP-specific behavior is better handled as a composable layer on top of an upstream-neutral server, not as the upstream-neutral server.

4. **Adopt one of the myriad of other Prometheus MCP servers.** Lots exist with varying levels of quality/support. Many in typescript, python, etc. None that align with the Prometheus community's existing tooling/ecosystem support.

5. **Build a new MCP server from scratch in the `prometheus/` org.** Why we don't: there's no functional gap between what's needed and what `tjhop/prometheus-mcp-server` already does. A rewrite would burn maintainer time and lose a year+ of accumulated knowledge/effort for no concrete win.

6. **Don't adopt anything; just publish a docs page about MCP / AI integrations.** Suggested as a starting point by [@bwplotka in #57](https://github.com/prometheus/proposals/issues/57) and worth doing regardless of this proposal's outcome. Why it isn't enough on its own: it doesn't solve the "which one is the official one?" question, and it leaves the canonical implementation outside the project's own governance, security review, and release process. Documentation and adoption should be complementary, not alternatives.

## Action Plan

* [ ] Get consensus on this proposal.
* [ ] Transfer `tjhop/prometheus-mcp-server` repository to `prometheus` org.
* [ ] Wire up Prometheus org CI/release/security/CODEOWNERS conventions.
* [ ] Add reference to the project in `prometheus/docs` (integrations / AI section).
* [ ] Announcement blog post on the Prometheus website?
