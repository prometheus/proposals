## Allow providing default values for missing series in binary operations

* **Owners:**
  * [@juliusv](https://github.com/juliusv)

* **Implementation Status:** `Not implemented`

* **Related Issues and PRs:**
  * https://github.com/prometheus/prometheus/issues/13625

> TL;DR: This proposal suggests adding `fill` / `fill_left` / `fill_right` modifiers to vector-to-vector binary operations. These modifiers would allow users to fill in missing series on either side of the operation and provide default values for them.

## Why

The current behavior of Prometheus' vector-to-vector binary operations is to drop series that do not have a matching counterpart on the other side of the operation. While this is often the desired behavior, there are cases (as outlined in https://github.com/prometheus/prometheus/issues/13625 and discussed in other places) where users want to treat missing series as having a specific default value (e.g., `0` in the face of addition), allowing for outputs in cases where operands are known to have incomplete series sets.

Examples:

```
# Adding two rate vectors where each may be missing some series, but where you still wanti to return values if a series is present on either side:
rate(successful_requests[5m]) + fill(0) rate(failed_requests[5m])
```

```
# Filtering error rates by a set of label-based thresholds, or a default threshold value of 42 where no custom threshold is defined for a given label set:
rate(errors_total[5m]) > fill_right(42) rate_threshold
```

### Pitfalls of the current solution

I still believe that the current behavior is the right default for the majority of use cases, since it avoids silently producing potentially misleading data. However, there are use cases where users want to have more control over how missing series are handled. The current workaround for this is to use the `or` operator to explicitly create series with default values, which can become cumbersome and less efficient.

## Goals

Goals and use cases for the solution as proposed in [How](#how):

* Allow filling in missing series on either side of a binary operation with a specified default value.

## Non-Goals

* Allowing many-to-many matching.
* Allowing non-float default values, e.g. native histograms. This could come later if there is demand.
* Allowing to specify additional (non-match-group) labels for filled-in series, e.g. when joining in labels via `group_left(info_label)` where the right side is missing. This could potentially be added later if there is enough demand.
* Creating series out of thin air when they do not exist on either side of the operation.

## How

Three new modifiers would be added to the binary operation syntax: `fill(<default>)`, `fill_left(<default>)`, and `fill_right(<default>)`. The semantics would be as follows:

* When a binary operation with a `fill`, `fill_left`, or `fill_right` modifier is evaluated, the engine first identifies all series present on both sides of the operation.
* For each series on the left side, if there is no matching series on the right side and the modifier is `fill` or `fill_right`, a new series is filled in with the specified default value.
* For each series on the right side, if there is no matching series on the left side and the modifier is `fill` or `fill_left`, a new series is filled in with the specified default value.
* The binary operation is then performed as usual, using the original and filled-in series.

The following diagrams illustrates some examples of the fill-in process.

Adding two vectors and using `0` as a default value for missing series on either side:

```
/                                   \             /                                   \     /                                                   \
| method="POST", status="200"  3455 |             | method="POST", status="200"  1234 |     | method="POST", status="200"  (3455 + 1234) = 4689 |
| method="POST", status="500"    21 |  + fill(0)  |             <missing>             |  =  | method="POST", status="500"       (21 + 0) =   21 |
|              <missing>            |             | method="GET", status="200"    567 |     | method="GET",  status="200"      (0 + 567) =  567 |
\                                   /             \                                   /     \                                                   /
```

The same addition, but only filling in missing series on the right side:

```
/                                   \                  /                                   \     /                                                   \
| method="POST", status="200"  3455 |                  | method="POST", status="200"  1234 |     | method="POST", status="200"  (3455 + 1234) = 4689 |
| method="POST", status="500"    21 |  + fill_right(0) |             <missing>             |  =  | method="POST", status="500"       (21 + 0) =   21 |
|              <missing>            |                  | method="GET", status="200"    567 |     |                    <omitted>                      |
\                                   /                  \                                   /     \                                                   /
```

### Limitations for many-to-one and one-to-many matches (`group_left` / `group_right`)

When using fill modifiers in combination with `group_left` or `group_right`, there are some limitations:

* If a fill modifier is used on the side that is being grouped (i.e., the "many" side), filling in missing series is not allowed, as it would be ambiguous which of the grouped series to fill in (the extra cardinality on the "many" side that would otherwise have made it into the result is not known). So `metric1 + on(...) group_left(...) fill_left(0) metric2` should yield a PromQL error.
* If a fill modifier is used on the side that is not being grouped (i.e., the "one" side), filling in missing series is allowed as normal. However, if the grouping modifier specifies label names to join in from the "one" side, those labels cannot be filled in for missing series, as there is no source for their values.

Example for trying to fill in missing series on the "many" side (not allowed):

```
# This is NOT allowed and should produce an error.

/                                   \
| method="GET",  status="200"  3455 |                                        /                    \
| method="POST", status="200"   567 |                                        | status="200"  1234 |
|              <missing>            |  + on(status) group_left fill_left(0)  | status="404"   341 |
|              <missing>            |                                        | status="500"   771 |
| method="GET",  status="500"       |                                        \                    /
| method="POST", status="500"       |
\                                   /
```

Example for filling in missing series on the "one" side (allowed, but joined labels will not be filled in):

```
/                                   \                                                                                            /                                                                  \
| method="GET",  status="200"  3455 |                                                                                            | method="GET",  status="200", cluster="eu1"  (3455 + 1234) = 4689 |
| method="POST", status="200"   567 |                                                  /                                   \     | method="POST", status="200", cluster="eu1"   (567 + 1234) = 1801 |
|                                   |                                                  | status="200", cluster="eu1"  1234 |     |                                                                  |
| method="GET",  status="404"     0 |  + on(status) group_left(cluster) fill_right(0)  |                <missing>          |  =  | method="GET",  status="404"                       (0 + 0) =    0 |
| method="POST", status="404"     3 |                                                  | status="500", cluster="eu1"   771 |     | method="POST", status="404"                       (3 + 0) =    3 |
|                                   |                                                  \                                   /     |                                                                  |
| method="GET",  status="500"    23 |                                                                                            | method="GET",  status="500", cluster="eu1"     (23 + 771) =  794 |
| method="POST", status="500"    42 |                                                                                            | method="POST", status="500", cluster="eu1"     (42 + 771) =  813 |
\                                   /                                                                                            \                                                                  /
```

## Alternatives

* Do nothing and keep relying on the `or` operator to create default-valued series where needed. This is more cumbersome and less efficient, but avoids adding complexity to the binary operation syntax.
* Introduce a separate function (e.g., `fill_missing(series, default_value)`) that can be applied to either side of a binary operation. This would avoid modifying the binary operation syntax, but it would make no sense in isolation, since it would always need to be paired with a binary operation.
* Call the modifier `outer` (similar to OUTER joins in SQL) and have it always fill in missing series on both sides with automatic default values (like `0` for addition). This would be less flexible than allowing users to specify the default value and individual sides to fill in.

## Action Plan

* [ ] Add the `fill`, `fill_left`, and `fill_right` modifiers to the PromQL lexer + parser.
* [ ] Implement the evaluation logic for the new modifiers in the PromQL engine.
* [ ] Update the Go-based PromQL printer / formatter to correctly render the new modifiers.
* [ ] Update the PromQL grammar for the CodeMirror code editor to recognize the new modifiers.
* [ ] Add autocompletion support for the new modifiers in the PromQL editor.
* [ ] Add linting support for the new modifiers in the PromQL editor.
* [ ] Support the new modifier in the PromLens-style tree view.
* [ ] Support visualizing the new modifier behavior in the "Explain" tab for binary operator nodes.
* [ ] Add unit tests and integration tests to cover the new functionality.
* [ ] Update the Prometheus documentation to include the new modifiers and their usage.
* [ ] Announce the new feature to the Prometheus community through relevant channels.
