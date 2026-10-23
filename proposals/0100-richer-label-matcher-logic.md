## Richer label matcher logic

* **Owners:**
  * `@vpranckaitis`

* **Implementation Status:** `Not implemented`

* **Related Issues and PRs:**
  * [PromQL: Need richer label matcher logic (or apply matchers to expressions?)](https://github.com/prometheus/prometheus/issues/14824)
  * [Proposal: Add OR operator with parenthesis support for label matchers in PromQL](https://github.com/prometheus/prometheus/issues/17040) (closed as duplicate of the above)
  * [Mechanism Search based on new label created through label_join function](https://github.com/prometheus/prometheus/issues/5097) (rejected in 2020)

* **Other docs or links:**
  * [VictoriaMetrics MetricsQL: filtering by multiple `or` filters](https://docs.victoriametrics.com/victoriametrics/keyconcepts/#filtering-by-multiple-or-filters)
  * [Datadog: boolean filtered queries](https://docs.datadoghq.com/metrics/advanced-filtering/#boolean-filtered-query-examples)

> TL;DR: Label matchers inside `{}` can only be combined with a logical AND, so conditions of the shape `NOT (A AND B)` cannot be expressed in a selector and have to be emulated with chains of `unless`, with recording rules, or with extra exported series. This proposal adds a boolean matcher expression language inside `{}` — `and`, `or`, `not` and parentheses, with `,` keeping its current meaning — and the storage-side plumbing to evaluate it. It touches the PromQL lexer/parser/AST, `storage.Querier`, the TSDB postings code, the `match[]`-based HTTP APIs, and PromQL tooling (editor grammar, formatter, linters).

## Why

A selector such as `http_requests_total{method="GET", path="/api/foo"}` is a conjunction: every matcher must hold. There is no way to express a disjunction, and therefore — by De Morgan — no way to express the negation of a conjunction either. Users regularly need exactly that.

Concrete use cases collected in [#14824](https://github.com/prometheus/prometheus/issues/14824) and [#17040](https://github.com/prometheus/prometheus/issues/17040):

1. **Excluding a set of label combinations.** Show request rates for all endpoints except a handful of preview endpoints, where an endpoint is the pair `(method, path)`:

   ```
   NOT (method="GET" AND path="/api/bar") AND NOT (method="POST" AND path="/api/foo")
   ```

2. **Joining against the complement of a selection.** `foo * on (x, y) bar{ !(A AND B) }` — reported independently by two users. A worked example: find pending Kubernetes pods that do *not* tolerate a given taint. Because a pod has many `kube_pod_tolerations` series, the naive negation

   ```
   kube_pod_tolerations{effect!="NoSchedule", key!="k", value!="v", operator!="Equal"}
   ```

   does not do what it looks like it does: it matches a *different* toleration series of the same pod and the join succeeds anyway. What is needed is the negation of the whole conjunction, evaluated per series.

3. **Metrics with inconsistent label schemas.** During a migration, or across teams, the same logical thing is identified by different labels, and the user wants one selector over all of them:

   ```
   transaction_count{
     (component="billing-legacy", env="prod")
     or (service="billing-v2", environment="production")
   }
   ```

### Pitfalls of the current solution

**Cascading `unless`.** Use case 1 is expressible today, at the cost of repeating the whole inner expression once per excluded combination:

```
rate(demo_api_request_duration_seconds_count[5m])
  unless rate(demo_api_request_duration_seconds_count{method="GET", path="/api/bar"}[5m])
  unless rate(demo_api_request_duration_seconds_count{method="POST", path="/api/foo"}[5m])
```

The problems:

* It scales badly. Every excluded combination adds a copy of the base expression; when the base expression is itself large, the query becomes unreadable and unmaintainable.
* It reads nothing like the user's intent. The intent is a property of the *selection*; the query expresses it as set arithmetic over *results*.
* It is expensive. Each `unless` operand is a separate selector that pulls series and samples out of storage and evaluates them at every step, only for the result to be thrown away. A selector-level exclusion never reads those series at all.
* It is fragile in distributed, Prometheus-compatible TSDBs. Query sharding and aggregation pushdown in Thanos, Mimir and Cortex key off the shape of the query; rewriting a single selector into a tree of binary set operations defeats those optimisations or forces the engine to fetch the unsharded superset.

**`or` between selectors** has the same problems for use case 3, plus it cannot be used inside a range selector: `(a or b)[5m]` is not valid PromQL, so `rate()` over a union of two schemas needs the union to be duplicated inside each operand.

**Recording rules or relabelling** (give the series the composite label up front, or export a separate "exclusion list" metric) work well for stable, long-lived cases and are the right answer there. They are a poor fit for ad-hoc analysis and for exploratory queries: they require write-path changes, they add series, they need deploying before the question can be asked, and they are often not available to the person asking the question — e.g. when the metric comes from a third-party exporter.

**Regex matchers** only help when the whole condition lives on a single label. They cannot correlate two labels, which is precisely what all three use cases need.

The 2024 dev-summit [concluded](https://github.com/prometheus/prometheus/issues/14824#issuecomment-2349118127) that *something* should be done here, with two candidate directions — acting at the selector level, or a subquery/expression-filter approach — and asked for a design document. This document picks the selector level and makes the case for it.

## Goals

Goals and use cases for the solution as proposed in [How](#how):

* Allow any propositional condition over label matchers — including `NOT (A AND B)` and disjunctions over different label names — to be expressed inside a single selector.
* Keep the expression readable and close to the user's intent, without forcing a rewrite into a normal form.
* Keep the result a *single* vector selector, so that it stays one storage request and remains amenable to sharding and pushdown in distributed implementations.
* Evaluate the condition in the index (postings) rather than by fetching and discarding series.
* Keep every query that is valid today valid, with unchanged semantics.
* Agree with MetricsQL wherever the two syntaxes overlap, so that a selector accepted by both means the same thing in both.
* Fail where a storage cannot evaluate the expression, and leave room for an optional compatibility path that lets such storages support it without native index work.

### Audience

* PromQL users writing dashboards, alerts and ad-hoc queries.
* Prometheus maintainers of the PromQL and TSDB components.
* Maintainers of Prometheus-compatible query engines and storages (Thanos, Mimir, Cortex, VictoriaMetrics, …) and of alternative PromQL parsers.
* Authors of PromQL tooling: editors and autocompletion (`codemirror-promql`, Grafana), formatters, linters, query builders.

## Non-Goals

* **Filtering on labels produced by the query itself.** The original report in [#14824](https://github.com/prometheus/prometheus/issues/14824) asks for `label_join(...){endpoint!~"..."}`. Matchers are resolved against the index before any samples are read, so they cannot see labels created by `label_join`/`label_replace`. That request — and the long tail of [#5097](https://github.com/prometheus/prometheus/issues/5097) — needs expression-level filtering and is deliberately out of scope here. See [Alternatives](#alternatives).
* **Changing the `and` / `or` / `unless` set operators** between instant vectors in any way.
* **Changing the remote read protocol.** Remote read is handled without a protobuf change (see [Remote read](#remote-read)).
* **Richer matchers in relabelling, scrape configs or Alertmanager routing.** This proposal is limited to PromQL selectors and the `match[]` HTTP APIs.
* **`unless` inside `{}`.** It would be pure sugar for `and not`; it can be added later if there is demand.

## How

### Syntax

Inside `{}`, the comma-separated matcher list is replaced by a boolean *matcher expression* over matchers, with these operators:

| Construct | Meaning               |
|-----------|-----------------------|
| `a="1"`   | matcher, as today     |
| `,`       | conjunction, as today |
| `and`     | conjunction           |
| `or`      | disjunction           |
| `not`     | negation              |
| `( … )`   | grouping              |

Operator keywords are case-insensitive, like every other PromQL keyword. Precedence, from tightest to loosest, is `not`, then `and` / `,`, then `or` — the conventional precedence, and the same as for the existing PromQL set operators.

The three motivating use cases become:

```
rate(demo_api_request_duration_seconds_count{
  not (method="GET" and path="/api/bar") and
  not (method="POST" and path="/api/foo")
}[5m])
```

```
kube_pod_status_phase{phase="Pending"}
* on (pod, namespace)
kube_pod_tolerations{not (effect="NoSchedule" and key="k" and value="v" and operator="Equal")}
```

```
transaction_count{
  (component="billing-legacy", env="prod")
  or (service="billing-v2", environment="production")
}
```

A metric name written before the brace binds to the *whole* expression, as one would expect: `foo{a="1" or b="2"}` is `__name__="foo" and (a="1" or b="2")`, not `(__name__="foo" and a="1") or b="2"`.

#### Mixing `,` and `or`

`,` and `and` are the same operator at the same precedence, so `or` binds loosest and splits the brace contents into groups of comma-separated conjuncts:

```
{a="1", b="2" or c="3"}       # (a and b) or c
{a="1" or b="2", c="3"}       # a or (b and c)
{a="1", (b="2" or c="3")}     # a and (b or c)
{a="1" and b="2" or c="3"}    # (a and b) or c
```

**This matches MetricsQL**, where `or` likewise separates groups of comma-separated filters, so a selector that is valid in both languages means the same thing in both. That compatibility is the deciding argument: users and tooling move between Prometheus and VictoriaMetrics, and a silent semantic disagreement on a query that parses in both would be considerably worse than any syntax-level difference. It is also the conventional precedence, matching `and`/`or` outside braces and boolean operators in essentially every other language.

The cost is a readability trap: `{job="x", code="500" or code="502"}` looks like it filters on `job` in both branches, and it does not — it means `(job="x" and code="500") or code="502"`. The mitigations are tooling rather than syntax: the PromQL formatter should print the implied grouping explicitly (`{(job="x", code="500") or code="502"}`), and the linter should warn when a `,` and an unparenthesised `or` appear at the same brace level. Users who want the other reading write `{job="x", (code="500" or code="502")}`.

Queries that use no `or` are entirely unaffected, which is every query that exists today.

#### Grammar sketch

```
label_matchers  : LEFT_BRACE matcher_expr RIGHT_BRACE
                | LEFT_BRACE matcher_expr COMMA RIGHT_BRACE   /* trailing comma, as today */
                | LEFT_BRACE RIGHT_BRACE

matcher_expr    : or_expr
or_expr         : and_expr | or_expr OR and_expr
and_expr        : unary_expr | and_expr AND unary_expr | and_expr COMMA unary_expr
unary_expr      : matcher | NOT unary_expr | LEFT_PAREN matcher_expr RIGHT_PAREN
matcher         : IDENTIFIER match_op STRING
                | string_identifier match_op STRING
                | string_identifier                            /* UTF-8 metric name */
```

`COMMA` and `AND` are deliberately the same production, so the precedence relationship with `OR` falls out of the grammar rather than being a special case.

#### Lexer ambiguity with label names

`lexInsideBraces` currently emits every identifier as `IDENTIFIER` without keyword lookup, so `{and="1"}`, `{or="1"}`, `{not="1"}` are valid selectors today for labels literally named `and`, `or` or `not`. Turning those words into keywords inside braces would be a breaking change.

To avoid this, the parser can use one token look-ahead to distinguish between the two: an identifier followed by a match operator (`=`, `!=`, `=~`, `!~`) is a label name; an identifier in operator position is an operator. The lexer keeps emitting `IDENTIFIER` and the grammar treats the keywords contextually. `{or="1" or or="2"}` stays valid and means what it says.

Should this turn out to create unresolvable LALR(1) conflicts in the goyacc grammar, the fallback is to make the words keywords inside braces and require quoting for such label names — `{"or"="1"}`, which the UTF-8 label name support ([PROM-28](0028-utf8.md)) already provides — accompanied by a release note. This is noted as a known unknown; it must be settled in the implementation PR, not left to discover later.

### Validity: every disjunct must be anchored

PromQL rejects selectors that match everything: *"vector selector must contain at least one non-empty matcher"* (`promql/parser/parse.go`). With disjunction, the check has to hold for every branch — `{a="1" or b!="2"}` would otherwise be an everything-selector wearing a disguise.

The check generalises structurally, without materialising a normal form, as `anchored(expr)`:

* `anchored(m)` = `!m.Matches("")`
* `anchored(x and y)` = `anchored(x) || anchored(y)`
* `anchored(x or y)` = `anchored(x) && anchored(y)`
* `anchored(not x)` = `false`

This is linear in the size of the expression and conservative for `not` (a negation can be an everything-matcher, so it never anchors on its own). Examples:

```
{a="1" or b="2"}              # valid
{a="1" or b!="2"}             # rejected: second branch matches everything
{not (a="1" and b="2")}       # rejected: nothing anchors it
foo{not (a="1" and b="2")}    # valid: __name__="foo" anchors every branch
```

`VectorSelector.BypassEmptyMatcherCheck` (used for `info()`'s second argument) keeps skipping the check as it does today.

### AST representation

A new type in `model/labels` represents the tree:

```go
// MatcherExpr is a boolean expression over label matchers.
type MatcherExpr struct {
	Op       MatcherExprOp  // MatcherExprMatcher | MatcherExprAnd | MatcherExprOr | MatcherExprNot
	Matcher  *Matcher       // set iff Op == MatcherExprMatcher
	Operands []*MatcherExpr // set otherwise
}
```

`parser.VectorSelector` gains `Matchers *labels.MatcherExpr`, which is always populated. The existing `LabelMatchers []*labels.Matcher` field is kept and populated whenever the expression is a plain conjunction — i.e. for every query that is expressible today — and left `nil` otherwise.

Leaving it `nil` rather than lossily flattening is deliberate: a downstream consumer that has not been updated will then produce an obvious error or an empty result, instead of silently widening the selection. Combined with the feature flag (below), an un-updated consumer never sees `nil` unless an operator has explicitly opted in. The same split applies to `parser.ParseMetricSelector` / `ParseMetricSelectors`, which gain `…Expr` variants; the existing functions return an error for non-conjunctive input.

Roughly 20 non-test files in `prometheus/prometheus` pass `[]*labels.Matcher` around, and the Go API is not covered by compatibility guarantees, so a hard compile-time break is the other option. It is listed as an open question — the trade-off is "downstream must notice" versus "downstream must act now".

### Storage interface

`storage.Querier.Select` keeps its signature. Native support is an optional interface, discovered with a type assertion:

```go
// ExprQuerier is implemented by queriers that can evaluate a boolean
// matcher expression natively.
type ExprQuerier interface {
	SelectExpr(ctx context.Context, sortSeries bool, hints *SelectHints, expr *labels.MatcherExpr) SeriesSet
}
```

with the equivalent for `LabelNames` / `LabelValues`, which take matchers too.

**When the querier does not implement it**, and the selector is not a plain conjunction, the engine returns a clear error naming the unsupported feature. It must never silently drop part of the expression and widen the selection. Prometheus' own TSDB implements the interface, so this only affects embedders and remote backends; [Optional: expansion to a normal form](#optional-expansion-to-a-normal-form) describes a way to serve them too.

### TSDB

`PostingsForMatchers` generalises to `PostingsForMatcherExpr` with no change in approach:

1. **Normalise.** Push `not` down with De Morgan's laws until it reaches leaves, then eliminate it with the existing `labels.Matcher.Inverse()` (`=` ↔ `!=`, `=~` ↔ `!~`). The tree is then AND/OR over plain matchers only.
2. **AND nodes** reuse today's logic verbatim: partition children into intersecting and subtracting terms, fall back to `index.AllPostings` as the subtraction base when there is nothing to intersect, sort so the base is as small as possible, then `index.Intersect` and `index.Without`. A child that is itself an OR node always yields concrete postings, so it counts as an intersecting term.
3. **OR nodes** are `index.Merge(ctx, children...)`, which deduplicates by series ref — so no series-level dedup is needed.

Every existing optimisation (`.*` and `.+` special cases, `PostingsForAllLabelValues`, the postings cache) applies unchanged to the leaves. The expensive case is an OR whose branches all subtract, which needs `AllPostings` as a base; the normalisation step should factor out shared conjuncts from OR branches where it can, to keep that rare.

### HTTP APIs

The `match[]` parameter of `/api/v1/series`, `/api/v1/labels`, `/api/v1/label/<name>/values`, `/api/v1/query_exemplars` and `/federate`, and `promtool`'s `--match` flags, all accept the richer syntax through the same parser, and resolve it through the same querier interface — so they work against the TSDB and report the same error as above against a querier without native support.

### Remote read

No protobuf change. Adding an optional `matcher_expr` field to `prompb.Query` would be actively dangerous: an older receiver ignores the unknown field, sees an empty `matchers` list, and returns *everything*. So a remote read querier simply does not implement `ExprQuerier`, and a non-conjunctive selector against it errors out. A protocol extension can follow once there is a capability negotiation mechanism to hang it on, e.g. [PROM-63](0063-feature-flag.md).

### Optional: expansion to a normal form

A query engine can serve a storage that has no native support by rewriting the expression into *disjunctive* normal form — a disjunction of plain matcher lists — and then issuing one ordinary request per disjunct:

* `storage.Querier.Select` once per disjunct, merged with `storage.NewMergeSeriesSet` (`ChainedSeriesMerge`), which deduplicates series that satisfy more than one disjunct.
* `LabelNames` / `LabelValues` once per disjunct, with the results unioned, which is correct by construction.
* One `prompb.Query` per disjunct for remote read, merged locally — correct against every remote read endpoint that exists today, without any protocol change.

DNF is the form that matters here, rather than CNF: a disjunct is exactly a `[]*labels.Matcher`, so each one maps onto the existing `Select` / `match[]` / `prompb.Query` shape unchanged, and the union of the per-disjunct results is the answer. There is no equally direct way to evaluate a conjunction of disjunctions against those APIs.

**This is explicitly optional, and not part of the core implementation.** Getting it right is more work than it first appears:

* Negation has to be pushed to the leaves by De Morgan and then eliminated with `labels.Matcher.Inverse()` before distribution is meaningful.
* Distributing `and` over `or` is exponential in the worst case, so the implementation needs a hard cap on the number of disjuncts it will produce (suggested: 64) and must return an error naming the limit rather than quietly melting the storage.
* To stay under that cap for real queries it also wants the usual simplifications — absorption, dropping disjuncts subsumed by others, deduplicating identical matchers — each of which is easy to get subtly wrong.
* Every produced disjunct must independently satisfy the anchoring rule; the structural check guarantees this, but the expansion must not introduce an everything-disjunct through a sloppy simplification.
* The merged result needs series-level deduplication, which the TSDB postings path gets for free from `index.Merge`.

None of that is needed for Prometheus itself to ship the feature, and none of it blocks any other part of this proposal. It is worth doing as a follow-up because of what it buys: remote read gains support with no protobuf change and no cooperation from the remote end, embedders of the PromQL engine get the feature before touching their storage layer, and any Prometheus-compatible backend can adopt the syntax incrementally — native postings evaluation where it pays off, expansion everywhere else. If it is never implemented, the feature still works end-to-end on the TSDB; backends without native support report an honest error instead.

### Rollout

The feature will be gated behind `--enable-feature=promql-matcher-expressions`. With the flag off, the new syntax fails to parse exactly as it does today, and no component can ever observe a `nil` `LabelMatchers`. Once the flag is on and a rule or dashboard uses the syntax, downgrading Prometheus breaks those queries — the usual experimental-feature caveat, to be stated in the docs. The flag should also be advertised under `promql` in the features API from [PROM-63](0063-feature-flag.md) when that lands, so Grafana and friends can enable the syntax in their query builders only where it works.

### Testing and verification

* Parser: table tests for precedence — in particular every mix of `,`, `and` and `or`, asserted against the MetricsQL grouping — the keyword-vs-label-name cases (`{or="1" or or="2"}`), UTF-8 quoted names, and the anchoring rule. Fuzz the parser, and property-test printer round-tripping (`parse(print(ast)) == ast`).
* Engine: `promqltest` `.test` files covering every operator combination and the interaction with `@`, `offset`, range selectors, `info()` and subqueries.
* Benchmarks for `PostingsForMatcherExpr` against `PostingsForMatchers` on conjunction-only input, to show the generalisation costs nothing for existing queries, plus new benchmarks for the OR and negated-conjunction shapes.

### Known unknowns

* Whether the contextual-keyword approach is expressible in the goyacc LALR(1) grammar without conflicts, or whether `and`/`or`/`not` must become reserved inside braces.
* Whether `nil`-on-non-conjunctive or a hard compile break is the better migration for `VectorSelector.LabelMatchers`.
* Whether the optional normal-form expansion is worth building at all, how much simplification it needs to be useful in practice, and the right value for its disjunct limit.
* Whether the readability trap of mixing `,` and `or` is better handled by a formatter that always prints the implied grouping, by a linter warning, or by both.
* How much normalisation (factoring out common conjuncts, matcher deduplication) is worth doing before hitting the index.

## Alternatives

1. **`or` only, in disjunctive normal form (MetricsQL style).** Add just `or` between comma-separated groups: `{method="GET", path!="/bar" or method="POST", path!="/foo" or method!="GET", method!="POST"}`. It is strictly simpler to implement and parse, it needs no `not`, and it is already familiar to VictoriaMetrics users. It is rejected as the primary design because the user has to do the DNF conversion by hand: the transformed query above is the motivating example 1, and it neither looks like nor reads like `NOT (method="GET" AND path="/bar") AND NOT (method="POST" AND path="/foo")`. The conversion is error-prone, the result can be much longer than the original, and reviewing such a query for correctness is hard. The feedback on the issue was explicit that the fuller form conveys intent better. Note that `or`-only is a strict subset of what is proposed here, so nothing in this design forecloses shipping `or` first and `not`/`and`/parens later if the implementation needs to be staged.

2. **Apply matchers to arbitrary expressions: `expr{…}`.** This is what [#14824](https://github.com/prometheus/prometheus/issues/14824) originally asked for and the direction [#5097](https://github.com/prometheus/prometheus/issues/5097) was rejected on. It solves a problem this proposal does not — filtering on labels produced by `label_join`/`label_replace` — but it does not solve this one well. It is a post-filter: the series are fetched and evaluated first and then discarded, so it gives up exactly the pushdown and sharding benefits that motivate acting at the selector level, and it does nothing for `rate(…[5m])` over a union of label schemas. The two features are complementary rather than competing, and the expression-filter one deserves its own proposal.

3. **Subqueries / `filter(expr, cond)`-style function.** The other direction floated at the dev-summit. Same objection as (2) — it operates on results, not on the index — plus it introduces a second place where label conditions are written, with its own syntax to learn.

4. **Make an unparenthesised `or` next to a `,` a parse error**, forcing the user to write `{a="1", (b="2" or c="3")}` or `{(a="1", b="2") or c="3"}`. This is the only option that cannot silently produce a wrong answer for the `{job="x", code="500" or code="502"}` trap, and it is forward-compatible: the error can be relaxed later in either direction without invalidating any query that parsed before. It is rejected because it makes Prometheus reject selectors that VictoriaMetrics accepts, which pushes the incompatibility onto every dashboard, query builder and copy-pasted snippet that moves between the two — a constant tax to avoid a trap that a formatter and a linter can flag just as effectively. If the trap turns out to bite users in practice during the experimental period, this remains the obvious fallback.

5. **`,` lower precedence than `or`**, so that `{job="x", code="500" or code="502"}` means `job and (code="500" or code="502")`. This is arguably the most intuitive reading of that particular query and keeps the "braces hold a list of conditions, all of which hold" mental model. Rejected because it silently disagrees with MetricsQL on a query that is valid in both languages — the worst possible outcome for anyone running both — and because it would also disagree with PromQL's own `and`/`or` precedence outside braces.

6. **Do nothing; tell users to add the composite label.** The right answer when the write path is under the user's control, and it should stay the recommendation for stable, high-traffic queries. It does not cover ad-hoc analysis, third-party exporters, or any case where the person asking the question cannot change the ingestion pipeline — and all three motivating use cases are of that kind.

7. **Publish an "exclusion list" metric and keep using a single `unless`.** Suggested on the issue, and genuinely nice for long-lived, externally-managed exclusions. It needs an extra exporter or recording rule, it creates series, and it does not help the join-against-the-complement or multi-schema cases.

8. **Richer regex instead.** Collapse the condition into one label's regex. Only works when the whole condition lives on one label; none of the motivating cases do.

## Action Plan

* [ ] Add `labels.MatcherExpr`, its constructors, `String()` and De Morgan normalisation `<GH issue>`
* [ ] Extend the PromQL lexer/grammar/AST with matcher expressions behind `--enable-feature=promql-matcher-expressions`, including the generalised anchoring check `<GH issue>`
* [ ] Add `storage.ExprQuerier` plus the `LabelNames`/`LabelValues` equivalents, and the unsupported-feature error for queriers without it `<GH issue>`
* [ ] Implement `PostingsForMatcherExpr` in the TSDB `<GH issue>`
* [ ] Support the syntax in `match[]` on `/api/v1/series`, `/api/v1/labels`, `/api/v1/label/<name>/values`, `/api/v1/query_exemplars`, `/federate` and `promtool` `<GH issue>`
* [ ] Update the PromQL printer/formatter and `promtool promql format` for round-trip fidelity, printing the implied grouping when `,` and `or` are mixed `<GH issue>`
* [ ] Update the PromQL documentation and the feature-flag documentation `<GH issue>`
* [ ] Update the `lezer-promql` grammar, `codemirror-promql` autocompletion and linting, and the PromLens-style tree view `<GH issue>`
* [ ] Advertise the feature in the features API once [PROM-63](0063-feature-flag.md) is implemented `<GH issue>`

Optional follow-ups, each independent of the above and of each other:

* [ ] Implement DNF expansion with a disjunct limit and the simplifications it needs `<GH issue>`
* [ ] Use it in the engine to serve queriers that do not implement `storage.ExprQuerier` `<GH issue>`
* [ ] Use it in the remote read client to send one `prompb.Query` per disjunct `<GH issue>`
