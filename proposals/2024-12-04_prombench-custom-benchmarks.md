# Prombench Custom Benchmarks

* **Owners:**
  * [@bwplotka](https://github.com/bwplotka)
 
* **Contributors:**
  * [@krajorama](https://github.com/krajorama)
  * [@ArthurSens](https://github.com/ArthurSens)
  
* **Implementation Status:** `Partially implemented`

* **Related Issues and PRs:**
  * https://github.com/prometheus/test-infra/issues/659
  * https://github.com/prometheus/prometheus/pull/15682
  * https://github.com/prometheus/test-infra/pull/812


> TL;DR: We propose a way for maintainers to deploy custom Prombench benchmarks. We propose adding two flags to `/prombench`: `--bench.version=<branch or @commit SHA>` and `--bench.directory=<name of the benchmark scenario directory>` to customize benchmark scenarios.

## Why

[Prombench](https://github.com/prometheus/test-infra/tree/master/prombench) served us well with [around ~110 Prometheus macro-benchmarks performed](https://github.com/prometheus/prometheus/actions/workflows/prombench.yml?query=is%3Asuccess+event%3Arepository_dispatch) since the last year.

We invest and maintain a healthy **standard benchmarking scenario** that starts two nodepools with one Prometheus each, one built from the PR, second from the referenced release. For each Prometheus we deploy a separate `fake-webserver` to scrape and load-generator that performs stable load of the PromQL queries. Recently thanks to [the LFX mentee](https://github.com/cncf/mentoring/tree/main/programs/lfx-mentorship/2024/03-Sep-Nov#enhance-prometheus-benchmark-suitem) [Kushal](https://github.com/kushalShukla-web) a standard scenario also remote writes to a sink to benchmark the writing overhead.

Standard benchmark is a great way to have a uniform understanding of the efficiency for the generic Prometheus setup, especially useful before Prometheus releases. However, with more contributors and Prometheus features, there is an increasing amount of reasons to perform special, perhaps one-off benchmarking scenarios that target specific feature flags, Prometheus modes, custom setups or to elevate certain issues.

In other words, ideally Prombench would support a way to perform a custom benchmark when triggered it via Pull Request in Prometheus repo e.g. `/prombench v3.0.0 <please run agent mode with only native histograms load, OTLP receiving and remote write 2.0 with experimental arrow format`.
 
Non-exhausting list of custom benchmarks that would be epic to do, discussed among community:

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

Currently, there is no easy way to run macro-benchmark for both non-standard and standard configurations and setups.

This causes:

* Too little understanding of efficiency numbers for non-standard configurations and loads (scraped metrics, PromQL).
* Significantly slower developer velocity due to fear of impacting Prometheus performance.
* No data-driven decisions.
* Wasted time for people recreating custom macro benchmarks on their own, which are harder to repro or trust.
* Overloading standard scenario with too many or too custom features.

NOTE: Technically there are some limited and hacky ways for custom scenarios e.g. through manual GKE cluster operations on prombench after it starts or by hardcoding new defaults or logic on the benchmarked PR. While possible, they are neither easy or clean ways.

## Goals

* Keep the standard scenario healthy and useful for release gating.
* Ability to run custom benchmarks from the PR.
* Custom benchmarks should be easy and fast to prepare.
* Custom benchmarks should be deterministically reproducible and reviewable (e.g. pinned to a git commit).
* Minimize security risk of bad actor running arbitrary workloads on our prombench cluster (wasting credits).
* Keep Prombench project simple to maintain.

## Non-Goals

* Ability to run benchmarks from the GitHub Issues.
* Ability to run multiple benchmarks per one PR.

## How

> NOTE: The following proposal is implemented [in this PR](https://github.com/prometheus/test-infra/pull/812).

First, we propose to maintain the current standard benchmark flow: on the https://github.com/prometheus/test-infra `master` branch, in `/prombench/manifests/prombench` directory, we maintain the standard, single benchmarking scenario used as an acceptance validation for Prometheus. It's important to ensure it represents common Prometheus configuration. The only user related parameter for the standard scenario is `RELEASE` version.

On top of that, we propose to add two flags that will allow customizing and testing benchmark scenarios: 

### Version flag

Currently, the [Prometheus prombench GH job](https://github.com/prometheus/prometheus/blob/main/.github/workflows/prombench.yml) uses configuration from the `/prombench/manifests/prombench` directory stored in the `docker://prominfra/prombench:master` image.

We propose to add the `--bench.version=<branch|@commit>` flag to `/prombench` GH PR command, with the default value `master`. This flag will cause [the prombench GH action](https://github.com/prometheus/prometheus/blob/main/.github/workflows/prombench.yml) to pull specific commit SHA (if `--bench.version` value is prefixed with `@`) or branch from the https://github.com/prometheus/test-infra before deploying (or cleaning) test benchmark run. For the default `master` value, it will use the existing flow with the `docker://prominfra/prombench:master` image files.
 
Here are an example steps to customize and run a customized benchmark with `--bench.version` flag.

1. Create a new branch on https://github.com/prometheus/test-infra e.g. `benchmark/scenario1`.
2. Modify the contents of `/prombench/manifests/prombench` directory to your liking e.g. changing query load, metric load of advanced Prometheus configuration. It's also possible to make Prometheus deployments and versions exactly the same, but vary in a single configuration flag, for feature benchmarking.

   > WARN: When customizing this directory, don't change `1a_namespace.yaml` or `1c_cluster-role-binding.yaml` filenames as they are used for cleanup routine. Or, if you change it, know what you're doing in relation to [`make clean` job](../../Makefile).

3. Push changes to the new branch.
4. From the Prometheus PR comment, call prombench as `/prombench <release> --bench.version=benchmark/scenario1` or `/prombench <release> --bench.version=@<relevant commit SHA from the benchmark/scenario1>` to use configuration files from this custom branch.

Other details:

* Other custom branch modifications other than to this directory do not affect prombench (e.g. to infra CLI or makefiles).
* `--bench.version` is designed for a short-term or even one-off benchmark scenario configurations. It's not designed for long-term, well maintained scenarios. For the latter reason we can later e.g. maintain multiple `manifests/prombench` directories and introduce a new `--bench.directory` flag.
* Non-maintainers can follow similar process, but they will need to ask maintainer for a new branch and PR review. We can consider extending `--bench.version` to support remote repositories if this becomes a problem.
* Custom benchmarking logic is implemented in the [`maybe_pull_custom_version` make job](https://github.com/prometheus/test-infra/blob/cm-branch/prombench/Makefile#L48) and invoked by the prombench GH job on Prometheus repo on `deploy` and `clean`.

Pros:

* Does not change std scenario.
* Prombench core framework is intact - no cluster resources can be modified this way.
* No need to rebuild any docker image.
* Allows Prometheus team to customize almost all the aspects of the benchmark like:
  * metric load
  * query load
  * number of replicas
  * prometheus config, flags and recording rules
  * remote write sink options (e.g introduce failures)
* Anybody can inspect what will be deployed by checking https://github.com/prometheus/test-infra repo.
* Only team can change manifests (contributors will need to create PRs).

Cons:

* Some knowledge how benchmark is deployed (e.g. what pods are running and from where) is required.
  * **Mitigation**: Document what's possible.
* When reviewing a PR with prombench results, you have to also review the custom benchmark version to trust the efficiency results.
  * **Mitigation**: Give a ready link to the directory used in the benchmark.
* It's easy to change things on custom branch that will have no effect (e.g. cluster resources), there's little guardrail here.
* There is a slight risk we accidentally merge a manifests change that mine bitcoins (review mistake). However, the same can occur on the `master` branch.

### Directory flag

Currently, the [Prometheus prombench GH job](https://github.com/prometheus/prometheus/blob/main/.github/workflows/prombench.yml) uses configuration from the `/prombench/manifests/prombench` directory. To allow different "standard" modes (e.g. agent mode) on `master` https://github.com/prometheus/test-infra, we propose to add `--bench.directory=<name of the benchmark scenario directory>`, which defaults to `manifests/prombench`.

Different directories should have all manifests, which may result in some duplication compared with `manifests/prombench`. Symlink could be used to make it obvious what file changes, what didn't.

Pros:

* Prometheus team can maintain a few official directories for common scenarios e.g. `agent`.

## Alternatives and Extensions

### Extension: Carefully design and template a set of customization to standard scenarion in `main`

One could add a big configuration file/flag surface to `/prombench` allowing to carefully change various aspects.

e.g. 
```
/prombench main
/extra-args --enable-features=native-histograms,wal-records --web.enable-otlp-receiver
/with avalanche
/with agent-mode
``` 

This is similar to how [Prow](https://docs.prow.k8s.io/docs/overview/) parses comments to add extra functionality to plugins.

Pros:
* More control and guardrail for what scenarios is possible.

Cons:
* Huge amount of work to customize, maintain, test and validate a custom templating and configuration surface. Changing manifests directly is good enough.
* Users might waste time trying to discover a totally new configuration API.

This is out of scope of this proposal, but it's possible to add in the future.

### Alternative: Change docker image (e.g. tag) in GH action

Initially I thought we could simply change a [docker image GH action is using](https://github.com/prometheus/prometheus/blob/main/.github/workflows/prombench.yml#L34) to deploy the prombench benchmark manifests.

Cons:
* Not really possible -- `uses` field [cannot be parameterized](https://stackoverflow.com/a/75377583)
* It would require not only a git branch on https://github.com/prometheus/test-infra but also rebuilding image. Doable with some CI, but unnecessarily heavy.

## Action Plan

* [X] Refactor comment-monitor CLI to be able to extend with flag parsing easily.
* [X] Extend comment-monitor CLI to support flags (https://github.com/prometheus/test-infra/pull/812)
* [X] Extend `make deploy` and `make clean` to support git pulling on demand and dynamic directory choice. (https://github.com/prometheus/test-infra/pull/812)
* [X] Add docs (https://github.com/prometheus/test-infra/pull/812)
* [X] Extend Prometheus prombench GH job (https://github.com/prometheus/prometheus/pull/15682)
* [ ] Announce on -dev list.
