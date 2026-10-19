## Rule test references in promtool

* **Owners:**
  * Hsiu-Chi Tsai [@thc1006](https://github.com/thc1006)

* **Implementation Status:** Not implemented

* **Related Issues and PRs:**
  * [prometheus/prometheus#11848](https://github.com/prometheus/prometheus/issues/11848): promtool support for coverage of rules
  * [prometheus/prometheus#8131](https://github.com/prometheus/prometheus/issues/8131): promtool: Calculate coverage data for tests
  * [prometheus/prometheus#18432](https://github.com/prometheus/prometheus/pull/18432): earlier implementation with a coverage percentage

* **Other docs or links:**
  * [Unit testing for rules](https://prometheus.io/docs/prometheus/latest/configuration/unit_testing_rules/)
  * [prometheus/prometheus#10815](https://github.com/prometheus/prometheus/pull/10815): `--lint-fatal` for `promtool check rules`

> TL;DR: Add an opt-in lint to `promtool test rules` that lists the alerting and recording rules no test refers to by exact name. With `--lint-fatal`, findings exit with code 3, as lint findings do in `promtool check rules`. There is no coverage percentage.

## Why

Many rule repositories run `promtool test rules` in CI. The command reports whether the tests pass, but not which rules have no test. A rule added without a test is only noticed if a reviewer catches it. [#11848](https://github.com/prometheus/prometheus/issues/11848) asks for this in a GitOps setup:

> I would settle for a flag generating errors [if] a rule hasn't been tested in a run (could be an informational entry in output).

[#8131](https://github.com/prometheus/prometheus/issues/8131) asks for "an idea of how well unit tests cover the rules they are supposed to be testing". Listing the rules that no test refers to answers the simplest part of that.

For example, the tests in Thanos's [`examples/alerts`](https://github.com/thanos-io/thanos/tree/f1e0bbc906c5/examples/alerts) refer to 2 of its 48 alerting rules and none of its 16 recording rules, and `promtool test rules` prints `SUCCESS`.

### Pitfalls of the current solution

promtool has no way to show this today.

[#18432](https://github.com/prometheus/prometheus/pull/18432) tried a coverage percentage. A rule counted as covered when a test selector could match its output, and a bounded regex search decided unclear cases. In review, @krajorama pointed out these problems:

* Catch-all expressions count every rule. With `count({__name__=~".+"}) > 0` and `count(ALERTS{alertname=~".+"}) or vector(0)` as the only tests, every rule shows as covered and `--coverage-threshold=100` passes.
* The complexity does not help. Neither expression reaches the regex search, which is about a third of `rule_coverage.go`, and the PR adds 132 lines to the unit testing documentation.
* A high percentage only shows that each rule is named by some test. It does not show how well the rule is tested. `(count(r) or vector(0)) >= bool 0` names `r` and returns 1 whatever `r` produces.

## Goals

* Show the rules that no selected test refers to.
* Let CI fail on them, as an opt-in.
* Keep the current behavior when the lint is not enabled.
* Reuse the PromQL parser and rule loader that promtool already uses.

### Audience

People who write and review rule files, and the CI pipelines that run `promtool test rules`.

## Non-Goals

* Measuring how good a test is, or which parts of a rule were evaluated.
* Deciding whether a regex matcher could match a rule.
* Following rules back to their input series, as sketched in [#8131](https://github.com/prometheus/prometheus/issues/8131).
* Changing the test file format.

## How

### What counts as a reference

A test assertion refers to a rule in one of three ways:

* An `alert_rule_test` has `alertname: X`, and the rule is an alerting rule named `X`.
* A selector in a `promql_expr_test` has `__name__="X"`, and the rule is a recording rule named `X`.
* A selector has `__name__="ALERTS"` or `__name__="ALERTS_FOR_STATE"` and `alertname="X"`, and the rule is an alerting rule named `X`.

Selectors come from `parser.ExtractSelectors`, as the [review of #16887](https://github.com/prometheus/prometheus/pull/16887#discussion_r2219026949) asked, so `sum by (job) (job:up:sum)` refers to `job:up:sum`. A bare metric name is an equality matcher on `__name__`, so `r` and `{__name__="r"}` are the same.

The following rules apply as well:

* Only `=` matchers name a rule, as @krajorama suggested in review. `{__name__=~".+"}`, `{__name__=~"r"}` and `ALERTS{alertname=~".+"}` refer to nothing, and they are still valid tests. #8131 already expected regexps on `__name__` to make the result lower than the truth.
* All other matchers on `__name__`, and on `alertname` for alerts, must accept the name.
* If the rule sets a label to a fixed value, every matcher on that label must accept the value. The labels come from the rule loader, so group labels are included. Alert label values with template syntax count as unknown.
* Matchers on other labels are not checked. `r{job="a",job="b"}` still refers to `r` when the rule does not set `job`.
* For alerts, `alertname` and the `alertstate` of `ALERTS` are set by the rule engine, so they are not compared with the rule's own labels.
* The rule must come from a file that the assertion's own test file loads.
* Only test groups selected by `--run` count.

An `alert_rule_test` with empty `exp_alerts` is a reference, since negative tests are tests too. When several alerting rules share a name, promtool compares their alerts together, so one `alert_rule_test` refers to all of them.

### CLI

`promtool test rules` gets the `--lint` and `--lint-fatal` flags that `promtool check rules` has:

```sh
promtool test rules --lint=unreferenced-rules tests.yml
promtool test rules --lint=unreferenced-rules --lint-fatal tests.yml
```

* `--lint` defaults to `none`, so existing invocations do not change.
* Findings go to stderr after the test results, and the exit code does not change.
* With `--lint-fatal`, findings exit with code 3. Failing tests still exit with code 1, which takes precedence, as in `check rules`.
* References only come from test groups that run. With `--run`, rules that only other groups test are reported.
* The help text marks the lint as experimental, like `--diff`.

Example output:

```text
  SUCCESS

Rules with no test reference:
  rules.yml, group "recording", rule 2: job:up:avg
  rules.yml, group "alerts", rule 3: NeverTested
```

### Which rules are checked

The lint checks the rules in the rule files that the given test files load. A rule file is identified by its resolved path, so a file loaded by several test files is checked once. Rule files that fail to load, and `rule_files` patterns that match nothing, are reported as findings.

A rule file that no test file loads is not checked. A test file without tests is valid, so a repository can add one that lists all of its rule files, and the lint loads them like any other:

```yaml
rule_files:
  - rules/*.yml
```

### Implementation

[#18432](https://github.com/prometheus/prometheus/pull/18432) already loads rules with `rules.Manager.LoadGroups`, tells same-name rules apart by file, group and position, and attributes assertions per test file. If this proposal is accepted, it will be reduced to the design above: the regex search, the percentage and `--coverage-threshold` go away, and the lint flags are added. Rules are indexed by kind and name, so each selector is compared only with rules of the same name.

### How to test and verify

End-to-end tests will cover each case under "What counts as a reference", plus `--run`, rule files shared between test files, unmatched patterns and load errors. Without the flag, the output must stay the same.

To check what a reference does and does not say, I ran these tests with promtool built from #18432 (`c039f22`) and from main (`6e69e84`), with the same results. Each test has the input series `up{job="prod"}` with the value 2 and a recording rule `r` with `expr: up`. The rule is then changed.

| Test expression                                  | `r` is `up * 2` | `r` is `up > 10` |
|--------------------------------------------------|-----------------|------------------|
| `r`, expecting `r{job="prod"} 2`                 | fails           | fails            |
| `count({__name__=~".+"}) > 0`, expecting 2       | passes          | fails            |
| `(count(r) or vector(0)) >= bool 0`, expecting 1 | passes          | passes           |

Under this proposal, the first and third tests refer to `r`, and the second does not. The third test cannot fail because of `r`, which is why the lint makes no claim about test quality.

On two public repositories, exact references give the same result as the regex search in #18432, because every test that refers to a rule does so through `alert_rule_test`:

* Thanos [`examples/alerts`](https://github.com/thanos-io/thanos/tree/f1e0bbc906c5/examples/alerts): 2 of 64 rules.
* Ceph [`monitoring/ceph-mixin`](https://github.com/ceph/ceph/tree/48ace71eaf1b/monitoring/ceph-mixin): all 101 alerting rules.

Neither repository tests recording rules, so they do not show the effect on recording rules.

### Open questions

* Should this use `--lint`, or a dedicated flag? `--lint` defaults to `duplicate-rules` in `check rules`, and would default to `none` here.
* The lint name: `unreferenced-rules` says what is checked, `untested-rules` says what users look for.
* Should recording rules be in scope, or only alerting rules?
* Is a test file without tests a good way to list all rule files, or should the lint take rule files directly?
* Should the output list references that are shared by several rules with the same name?
* Should a fatal finding also add a failed test case to the `--junit` report?
* Is there a use case in #8131 that this proposal should also cover?

## Alternatives

1. Keep the coverage percentage from #18432. It accepts more selector shapes at the cost of the regex search and its undecided state, and the cases above show that the number still says little about the tests.
2. Alerting rules only. This is smaller and fits a [comment in #8131](https://github.com/prometheus/prometheus/issues/8131#issuecomment-718699848) that alerts are usually what is worth testing. It leaves recording rules out, while the review of #16887 asked for them and their labels to be handled.
3. Declare the tested rules in the test file. This is explicit and covers indirect tests, but it changes the test format, and the lists can go stale.
4. Track what a test reads at runtime. This is closer to real coverage, but reading data does not mean the assertion checks it, and it needs changes in the engine.
5. Mutation testing: change a rule and check that a test fails. This measures what the table above shows, but it costs a test run per change and needs its own design.
6. An external tool, such as a script or pint. It would have to parse test files and load rules the same way promtool does, and #8131 puts this in promtool because it needs knowledge of how PromQL executes. Checks such as pint's [impossible selector check](https://cloudflare.github.io/pint/checks/promql/impossible.html), suggested in the review of #16887, complement this lint.

## Action Plan

* [ ] Agree on the definition and the CLI in this proposal.
* [ ] Reduce [#18432](https://github.com/prometheus/prometheus/pull/18432) to this design, with end-to-end tests for the cases above.
* [ ] Document the definition and its limits in the rule unit testing docs.
