# Relabel action to drop a target or sample when any label value matches a pattern

* **Owners:**
  * Rajesh Rajendiran [@RajeshRajendiran](https://github.com/RajeshRajendiran)

* **Implementation Status:** `Not implemented`

* **Related Issues and PRs:**
  * [prometheus/prometheus#14057](https://github.com/prometheus/prometheus/issues/14057) — the feature request this proposal addresses
  * [prometheus/prometheus#13664](https://github.com/prometheus/prometheus/issues/13664), [prometheus/prometheus#12483](https://github.com/prometheus/prometheus/issues/12483) — related, both closed

* **Other docs or links:**
  * [Relabeling configuration documentation](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#relabel_config)

> TL;DR: Add a new relabel action, tentatively `dropifany`, that drops a target or sample if the regex matches the value of *any* of its labels — no `source_labels` needed. This lets operators block well-known high-cardinality value patterns (IDs, email addresses, generated hostnames) regardless of which label carries them. Touches `model/relabel` and the relabeling docs.

## Why

Cardinality incidents are often caused by values appearing on labels the operator did not anticipate: request IDs, UUIDs, email addresses, or generated hostnames attached to a new label after an application change. The existing `drop` action requires naming the labels to inspect via `source_labels`, so a rule can only be written *after* the bad label is discovered — by which time the series churn and memory growth have already happened.

### Pitfalls of the current solution

* `drop`/`keep` only inspect labels named in `source_labels`; the full label set of scraped metrics is not knowable in advance.
* `labeldrop`/`labelkeep` match label *names* and remove single labels, silently merging distinct series instead of rejecting the sample.
* `sample_limit`/`label_limit` cap damage after the fact and drop good data along with bad.

## Goals

* One rule that drops a target/sample when the anchored regex matches any of its label values.
* Config shape consistent with existing actions (`labeldrop`/`labelkeep` already take only `regex`).
* RE2 only; no new regex features. Bounded, benchmarked cost in the relabeling hot path.

### Audience

Prometheus operators (especially platform teams scraping applications they don't control), and downstream users of `model/relabel` (Alertmanager, Grafana Alloy, etc.).

## Non-Goals

* Substring/cross-label matching (#13664) or regex backreferences (#12483) — both previously closed.
* Matching on label *names* — `labeldrop`/`labelkeep` cover that.
* Rewriting labels; this action only decides keep-or-drop for the whole target/sample.

## How

```yaml
metric_relabel_configs:
  - action: dropifany
    regex: '[0-9]{10,}|[^@]+@[^@]+\.[^@]+'
```

* Takes only `regex`; any other field is a validation error (same rule as `labeldrop`).
* The fully anchored regex is tested against each label value; any match drops the target/sample.
* All labels are inspected, including `__name__` and other `__`-prefixed labels (open question 1).

**Foot-gun mitigation:** full anchoring means `regex: 'foo'` only matches the exact value `foo`; the docs will lead with a warning that a greedy pattern like `.+` drops everything, plus the recommended testing workflow (relabel simulation in the UI / promtool).

**Testing:** unit tests in `model/relabel` (match on unexpected label, match on `__name__`, no match, interaction with earlier rules), validation tests, and a `benchstat` benchmark over realistic label sets in the implementation PR.

**Compatibility:** purely additive. Existing configs are unaffected; older Prometheus versions reject the unknown action at config load, as with any new action.

**Open questions:**

1. Inspect `__`-prefixed labels or only user-visible ones? Proposal: inspect all, document clearly.
2. Final action name: `dropifany` vs. something more explicit.
3. `keepifany` counterpart? Proposal: not initially — no use case presented, and it doubles the foot-gun surface.

## Alternatives

1. **Overload `drop` with empty `source_labels`.** That config is valid today (regex matched against the empty string), so changing its meaning silently alters existing setups. A distinct action keeps intent unambiguous.
2. **Treat `source_labels` as an exclusion list.** Inverts an existing field's meaning per action; harder to teach and easy to misread.
3. **Rely on `sample_limit`/`label_limit`.** Protects the server but rejects good data indiscriminately and doesn't target recognisable poison patterns.

## Action Plan

* [ ] Reach consensus on this proposal (naming, `__`-label scope) — [#14057](https://github.com/prometheus/prometheus/issues/14057)
* [ ] Implement in `model/relabel` with tests, validation, and benchmarks
* [ ] Document in `docs/configuration/configuration.md` with a foot-gun warning
