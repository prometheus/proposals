## Unquoted Unicode letters and dots in metric and label names

* **Owners:**
  * [@roidelapluie](https://github.com/roidelapluie)

* **Implementation Status:** `Not implemented`

* **Other docs or links:**
  * [PROM-0028: UTF-8 support for metric and label names](0028-utf8.md)
  * [Prometheus data model](https://prometheus.io/docs/concepts/data_model/)
  * [Go's unicode.IsLetter](https://pkg.go.dev/unicode#IsLetter)

> TL;DR: Extend unquoted PromQL metric and label names to accept every rune for which Go's `unicode.IsLetter` returns true, plus dots after the first character. A dot is an ordinary character in a name, with no metadata lookup, namespace, or histogram field access semantics. Prioritize existing naming needs over reserving syntax for possible future features.

## Why

Prometheus already supports UTF-8 metric and label names. In PromQL, names outside the traditional ASCII character set require quoting, and a quoted metric name must appear inside the selector's curly braces.

For example, querying a metric and label whose names contain dots currently requires:

```promql
{"http.server.request.duration", "service.name"="api"}
```

This proposal allows the same query to be written as:

```promql
http.server.request.duration{service.name="api"}
```

The [August 27–29 Slack discussion](https://cloud-native.slack.com/archives/C01AUBA4PFE/p1787819306884969) motivating this proposal highlighted how untranslated OpenTelemetry names make this quoting requirement increasingly visible. It also revisited allowing Unicode letters, so names such as `Björn` and names in non-Latin scripts can use the familiar selector syntax.

[PROM-0028](0028-utf8.md#non-quoted-metric-names) considered unquoted names but chose to establish full UTF-8 support through quoting first. Quoting remains necessary for arbitrary names. Having that general mechanism in place lets us make common names easier to use without solving every character through unquoted syntax.

Dots have been reserved for potential future syntax, including histogram field access and metadata lookup. Existing metric and label naming needs should take precedence. This proposal makes dots available as ordinary name characters; features needing special access semantics must use distinct syntax.

### Pitfalls of the current solution

* A name containing a dot requires a visibly different selector form, even though it selects a metric in exactly the same way.
* Users writing names with non-ASCII letters must quote them, even when those letters have no conflicting role in PromQL.
* Editors and query builders must switch selector forms when inserting such metric names, complicating completion and editing.

## Goals

* Allow dots and all runes accepted by `unicode.IsLetter` in unquoted metric and label names.
* Give quoted and unquoted spellings of the same name identical query semantics.
* Treat dots as opaque name characters everywhere these names are accepted.
* Preserve existing queries and the quoting mechanism for arbitrary UTF-8 names.

### Audience

PromQL users, particularly those querying names from OpenTelemetry or using non-ASCII letters, and maintainers of PromQL parsers, editors, and query generators.

## Non-Goals

* Introduce metadata lookup, label enrichment, namespace traversal, or histogram field access through dots.
* Change the storage model, ingestion validation, or name translation settings.
* Extend unquoted names in the text exposition format (OpenMetrics). This is left out of this proposal for now.
* Allow every UTF-8 character without quoting.
* Change label value syntax, introduce new function names, or rename existing metrics and labels.

## How

### Unquoted names

Use Go's `unicode.IsLetter(r)` to recognize letters in unquoted metric and label names, replacing the ASCII-only letter check. Retain the existing non-letter characters and additionally allow dots after the first character. Unquoted metric and label names must not start with a dot or digit. The resulting rules for each rune `r` are:

| Name        | First character                    | Subsequent characters                                        |
|-------------|------------------------------------|--------------------------------------------------------------|
| Metric name | `unicode.IsLetter(r)`, `_`, or `:` | `unicode.IsLetter(r)`, ASCII digit `0`–`9`, `_`, `:`, or `.` |
| Label name  | `unicode.IsLetter(r)` or `_`       | `unicode.IsLetter(r)`, ASCII digit `0`–`9`, `_`, or `.`      |

A Unicode letter is a rune for which Go's `unicode.IsLetter` returns true (Unicode category L). ASCII letters are included. This does not extend digits beyond `0`–`9`, or add combining marks, emoji, whitespace, or other punctuation. Names containing those characters continue to require quoting. Names beginning with a dot or digit also continue to require quoting, preserving numeric literal syntax such as `.5`.

Dots need not separate meaningful components. Consecutive or trailing dots are permitted after a valid first character. For example, `foo..bar` and `foo.` are ordinary names.

Apply these rules wherever PromQL accepts metric or label names, including selectors, aggregation grouping, vector matching, and labels listed in group modifiers. Existing keyword restrictions remain in effect; recognizing a Unicode letter does not introduce a new keyword or function.

Examples of proposed syntax:

```promql
Björn{région="eu"}
温度{場所="東京"}
sum by (service.name) (rate(http.server.requests[5m]))
requests_total + on (service.name) group_left (équipe) service_info
```

### Dots have no special semantics

`http.server.requests` is one metric name. `resource.k8s.namespace` is one label name. Their components are not interpreted independently.

For example:

```promql
http.server.requests{resource.k8s.namespace="system"}
```

This selects the metric named `http.server.requests` and filters on its ordinary label named `resource.k8s.namespace`. It does not read metadata or promote attributes into labels. No prefix, including `resource.` or `target.`, changes that behavior.

Likewise, `histogram.count` selects a metric with that literal name. It does not access a field on a histogram. Accepting this proposal means giving up the reservation of dots in names for such operators. Any future metadata or composite-type access feature must use separate, unambiguous syntax.

### Unicode identity and lookalike letters

Names retain their exact identity. Parsing does not normalize Unicode, fold case, transliterate letters, or equate visually similar characters.

For example, Latin `a` (U+0061) and Cyrillic `а` (U+0430) remain distinct. Both become usable without quoting. Similarly, precomposed `ö` is a letter, while an `o` followed by a combining diaeresis contains a combining mark and still requires quoting. These spellings remain distinct names.

Lookalike names are already possible with quoted UTF-8 syntax. Removing quotes can make the distinction less apparent, so documentation should explain it. Optional editor or linting diagnostics that expose code points or warn about lookalike characters are left for future work.

### Compatibility and implementation

Existing quoted queries remain valid. Quoted and unquoted references to the same name must produce the same selector and results. No stored data migration is needed.

Update the Go lexer and parser, the web editor grammar and completion logic, and the expression printer consistently. Keep an ASCII fast path and use Go's `unicode.IsLetter` for non-ASCII runes. Unicode classification follows the `unicode` package bundled with the Go version used to build Prometheus.

Query generators can emit the new syntax when their target supports it. Older parsers will reject the new unquoted names, so quoted syntax remains the compatible representation for those targets. String arguments that contain label names remain string arguments.

### Testing and verification

* Verify parsing and evaluation equivalence between quoted and unquoted metric names, label matchers, grouping labels, and vector matching labels.
* Cover multiple scripts, mixed ASCII and Unicode, consecutive and trailing dots, and rejection of unsupported unquoted characters and leading dots.
* Verify that lookalike letters and differently encoded names remain distinct, and that dotted names never trigger metadata or histogram operations.
* Check numeric literals, durations, keywords, operators, and subqueries for lexer regressions, including names such as `rate.total` and `Inf.total`.
* Check parse/print/parse round trips and agreement between the Go parser and web editor grammar; benchmark ASCII and Unicode parsing.

## Alternatives

1. **Keep requiring quotes.** This supports arbitrary UTF-8 names today, but retains the usability problems for common dotted names and non-ASCII letters.
2. **Allow only dots, or only Unicode letters.** Either is a smaller extension, but addresses only part of the naming needs raised in the discussion. Both can coexist with the existing quoting mechanism.
3. **Reserve dots for metadata or histogram access.** This preserves possible future syntax at the expense of names users already query. We propose prioritizing current usage and requiring distinct syntax for those features.
4. **Give certain dotted prefixes special meaning.** Treating `resource.` or `target.` differently would make ordinary-looking matchers depend on hidden naming rules and create collisions with real labels. Dots should have one consistent meaning as part of a name.
5. **Allow arbitrary unquoted UTF-8 through escapes.** This would require another escaping mechanism for characters with existing syntactic roles. Quoting already handles those names.

## Action Plan

* [ ] Implement behind a feature flag.
* [ ] Promote to stable.
