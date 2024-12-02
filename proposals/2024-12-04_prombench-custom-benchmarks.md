# Prombench Custom Benchmarks

* **Owners:**
  * [@bwplotka](https://github.com/bwplotka)

* **Implementation Status:** `Not implemented`

* **Related Issues and PRs:**
  * https://github.com/prometheus/test-infra/issues/659


> TL;DR: We propose a way for maintainers to deploy custom Prombench benchmarks via `/prombench <...> -bench.version <branch or commit SHA>` PR command. Benchmarks can be then customized via custom branches on https://github.com/prometheus/test-infra repo that modify [any benchmark-specific manifests](https://github.com/prometheus/test-infra/tree/master/prombench/manifests/prombench).

## Why

[Prombench](https://github.com/prometheus/test-infra/tree/master/prombench) served us well with [around ~110 Prometheus macro-benchmarks performed](https://github.com/prometheus/prometheus/actions/workflows/prombench.yml?query=is%3Asuccess+event%3Arepository_dispatch) since the last year.

We invest and maintain a healthy **standard benchmarking scenario** that starts two nodepools with one Prometheus each, one built from the PR, second from the referenced release. For each Prometheus we deploy a separate `fake-webserver` to scrape and load-generator that performs stable load of the PromQL queries. Recently thanks to [the LFX mentee](https://github.com/cncf/mentoring/tree/main/programs/lfx-mentorship/2024/03-Sep-Nov#enhance-prometheus-benchmark-suitem) [Kushal](https://github.com/kushalShukla-web) a standard scenario also remote writes to a sink to benchmark the writing overhead.

Standard benchmark is a great way to have a uniform understanding of the efficiency for the generic Prometheus setup, especially useful before Prometheus releases. However, with more contributors and Prometheus features, there is an increasing amount of reasons to perform special, perhaps one-off benchmarking scenarios that target specific feature flags, Prometheus modes, custom setups or to elevate certain issues.

In other words, ideally Prombench would support a way to perform a custom benchmark when triggered it via Pull Request in Prometheus repo e.g. `/prombench v3.0.0 <please run agent mode with only native histograms load, OTLP receiving and remote write 2.0 with experimental arrow format`.
 
Non-exhausting list of custom benchmarks that would be epic to do, discussed among community (`A` and `B` are two Prometheus process benchmark always run):

* Different configurations, e.g.:
  * Custom flag changes (especially [feature flags](https://prometheus.io/docs/prometheus/latest/feature_flags/))
    * *Is my improvement to CT meaningful, for `created-timestamp-zero-ingestion` feature flag enabled?*
  * Custom configuration file / different recording rule
    * *Did I fix an overhead of "alwaysScrapeHistograms" scrape option?* 
    * *Do we have a less overhead if all recording rules have this special label?*
  
* Different environment, e.g. to elevate certain issue:
    * only native histograms metrics
    * only PromQL histogram_quantile queries
    * bigger load
    * smaller load
    * long term blocks
    * remote write failures

* Compare two, same version Prometheus-es, across features or environments, e.g.:
  * *How better or worse it is when we enable feature X?*
  * agent mode vs tsdb mode for scrape and write
  * is a new WAL format better than the old one?

* Testing potential improvements to standard scenario, e.g.:
  * [switching fake-webserver to avalanche (tuning the load)](https://github.com/prometheus/test-infra/issues/559)
  * adding initial blocks

### Pitfalls of the current solution

Currently, there is no easy way to run macro-benchmark for new, non-standard configurations and setups (technically there is some limited and hacky way - through manual GKE cluster operations on prombench after it starts).

This causes:

* Too little understanding of efficiency numbers for non-standard configurations and loads (scraped metrics, PromQL).
* Significantly slower developer velocity due to fear of impacting Prometheus performance.
* No data-driven decisions.
* Wasted time for people recreating custom macro benchmarks on their own, which are harder to repro or trust.
* Overloading standard scenario with too many or too custom features.

## Goals

* Keep the standard scenario healthy and useful for release gating.
* Ability to run custom benchmarks from the PR.
* Custom benchmarks should be easy and fast to prepare.
* Custom benchmarks should be deterministically reproducible and reviewable (e.g. pinned to a git commit).
* Minimize security risk of bad actor running arbitrary workloads on our prombench cluster (wasting credits).

## Non-Goals

We don't discuss here the following changes:

* Ability to run benchmarks from the GitHub Issues.
* Ability to run multiple benchmarks per one PR.

## How

We propose changing Prombench in two phases:

### Ability to specify verion of the benchmark `/prombench <...> -bench.version <branch or commit SHA>`

First, we add the ability to deploy from a https://github.com/prometheus/test-infra branch or commit SHA.

We implement that by:

* Changing comment-monitor to support new flag `-bench.version` parsing (default is `main) (@bwplotka: I have a local WIP branch with a refactor of it and changes).
* Pass new flag via [Prometheus GH action env flags](https://github.com/prometheus/prometheus/blob/main/.github/workflows/prombench.yml)
* Extend [`make deploy`](https://github.com/prometheus/test-infra/blob/master/prombench/Makefile#L6) script (or infra CLI):
  * The ability to git pull a concrete https://github.com/prometheus/test-infra branch or commit.
  * This branch will be used when [applying (non infra) resources](https://github.com/prometheus/test-infra/tree/master/prombench/manifests/prombench).

Pros:

* Does not change std scenario.
* No need to rebuild any docker image.
* Allows Prometheus team to customize almost all the aspects of the benchmark like:
  * metric load
  * query load
  * number of replicas
  * prometheus config, flags and recording rules
  * remote write sink options (e.g introduce failures)
* Prombench core framework is intact - no cluster resources can be modified this way.
* Prometheus team can maintain a few official branches for common scenarios e.g. `agent`
* Anybody can inspect what will be deployed by checking https://github.com/prometheus/test-infra repo.
* Only team can change manifests (contributors will need to create PRs).

Cons:

* Some knowledge how benchmark is deployed (e.g. what pods are running and from where) is required.
  * **Mitigation**: Document what's possible.
* It's easy to change things on custom branch that will have no effect (e.g. cluster resources), there's little guardrail here.
* There is a slight risk we accidentally merge a manifests change that mine bitcoins (review mistake). However, the same can occur on `main` branch.

### Split Prometheus manifests into two deployments

We propose to add a way for benchmark scenario editors to specify custom A and B configuration (not only version!).

We implement that by changing manifests and infra CLI, so infra deploy will either:
* Apply just [one test manifests](https://github.com/prometheus/test-infra/blob/master/prombench/manifests/prombench/benchmark/3b_prometheus-test_deployment.yaml) twice for different versions.
* Apply two different manifests for A and B, with the same version.

Pros:
* Allows feature comparison explained in [Why section](#why).

Cons:
* One can "malform" benchmark to run different versions which is likely not useful, but it will be visible in a commit.

## Alternatives

### Alternative: Carefully design and template a set of customization to standard scenarion in `main`

One could add a big configuration file/flag surface to `/prombench` allowing to carefully change various aspects.

Pros:
* More control and guardrail for what scenarios is possible.

Cons:
* Too much work to maintain, test and validate a custom templating and configuration surface. Changing manifests directly is good enough.
* Too much work to customize scenarios.

### Alternative: Change docker image (e.g. tag) in GH action

Initially I thought we could simply change a [docker image GH action is using](https://github.com/prometheus/prometheus/blob/main/.github/workflows/prombench.yml#L34) to deploy the prombench benchmark manifests.

Cons:
* Not really possible -- `uses` field [cannot be parameterized](https://stackoverflow.com/a/75377583)
* It would require not only a git branch on https://github.com/prometheus/test-infra but also rebuilding image. Doable with some CI, but unnecessarily heavy.

## Action Plan

Action plan is explained in [How section](#how), plus docs changes in test-infra repo.
