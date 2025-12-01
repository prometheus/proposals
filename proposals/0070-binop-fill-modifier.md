## Allow providing default values for missing series in binary operations

* **Owners:**
  * [@juliusv](https://github.com/juliusv)

* **Implementation Status:** `Not implemented`

* **Related Issues and PRs:**
  * https://github.com/prometheus/prometheus/issues/13625

> TL;DR: This proposal suggests adding `fill` / `fill_left` / `fill_right` modifiers to vector-to-vector binary operations. These modifiers would allow users to fill in missing series on either side of the operation and provide default values for them.

## Why

The current behavior of Prometheus' vector-to-vector binary operations is to drop series that do not have a matching counterpart on the other side of the operation. While this is often the desired behavior, there are cases (as outlined in https://github.com/prometheus/prometheus/issues/13625 and discussed in other places) where users want to treat missing series as having a specific default value (e.g., `0` in the face of addition) and still create outputs for their label sets.

Examples:

```
# Adding two rate vectors where each may be missing some series, but where
# you still want to return values if a series is present on either side:
rate(successful_requests[5m]) + fill(0) rate(failed_requests[5m])
```

```
# Filtering error rates by a set of label-based thresholds, or a default threshold
# value of 42 where no custom threshold is defined for a given label set:
rate(errors_total[5m]) > fill_right(42) rate_threshold
```

### Pitfalls of the current solution

I still believe that the current behavior of dropping series without a match is the right default for the majority of use cases, since it avoids silently producing potentially misleading data. However, there are use cases where users want to have more control over how missing series are handled.

A current workaround for filling in missing series is to use the `or` operator, which can become cumbersome to write and read.

For example, to add two vectors while treating missing series as `0`, you could currently write:

```
vector1 + vector2 or vector1 or vector2
```

For default values other than `0` (`23` for the right side, `42` for the left side), you could write:

```
(vector1 + vector2) or (vector1 + 23) or (42 + vector2)
```

Note that this may inadvertently reintroduce the metric name on the resulting series, since arithmetic and trigonometric binary operations drop the metric name, but `or` retains it.

To also drop the metric name like the binary operator would, and to handle `on` / `ignoring` clauses, you could say:

```
  vector1
+ on(label1, label2)
  vector2
or
  sum by(label1, label2) (vector1) + 23
or
  42 + sum by(label1, label2) (vector2)
```

The `sum()` aggregator removes both the metric name and any labels not in the `by(...)` clause. This works fine for 1:1 matches (since no actual series reduction takes place), but many-to-one or one-to-many situations become even more complex to handle correctly.

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

The modifiers may be used in the following combinations:

* `fill(<default>)`
* `fill_left(<default>)`
* `fill_right(<default>)`
* `fill_left(<default>) fill_right(<default>)`
* `fill_right(<default>) fill_left(<default>)`

The following diagrams illustrate some examples of the fill-in process.

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

When using fill modifiers in combination with `group_left` or `group_right`, there are some things to note:

* If a fill modifier is used on the "many" side of a match, we will not know which extra differentiating labels would have existed on the (potentially multiple) missing series if they had been present. Therefore, we can only fill in a single series for the missing "many" side of that match group, using the group's matching labels as the series identity.
* If a fill modifier is used on the side that is not being grouped (i.e., the "one" side), filling in missing series is allowed as normal. However, if the grouping modifier specifies label names to include from the "one" side, those labels cannot be filled in for missing series, as there is no source for their values. A possible future extension could allow specifying default values for those joined-in labels as well, but that is out of scope for this proposal.

Example for filling in missing series on the "many" side (only a single series with the match group's labels is filled in):

```
/                                   \                                                                   /                                                   \
| method="GET",  status="200"  3455 |                                        /                    \     | method="GET",  status="200"  (3455 + 1234) = 4689 |
| method="POST", status="200"   567 |                                        | status="200"  1234 |     | method="POST", status="200"   (567 + 1234) = 1801 |
|                                   |                                        |                    |     |                                                   |
|              <missing>            |  + on(status) group_left fill_left(0)  | status="404"   341 |  =  |                status="404"      (0 + 341) =  341 |
|              <missing>            |                                        |                    |     |                                                   |
|                                   |                                        | status="500"   771 |     |                                                   |
| method="GET",  status="500"   23  |                                        \                    /     | method="GET",  status="500"     (23 + 771) =  794 |
| method="POST", status="500"   42  |                                                                   | method="POST", status="500"     (42 + 771) =  813 |
\                                   /                                                                   \                                                   /
```

Example for filling in missing series on the "one" side (joined labels will not be filled in):

```
/                                   \                                                                                            /                                                                  \
| method="GET",  status="200"  3455 |                                                  /                                   \     | method="GET",  status="200", cluster="eu1"  (3455 + 1234) = 4689 |
| method="POST", status="200"   567 |                                                  | status="200", cluster="eu1"  1234 |     | method="POST", status="200", cluster="eu1"   (567 + 1234) = 1801 |
|                                   |                                                  |                                   |     |                                                                  |
| method="GET",  status="404"     0 |  + on(status) group_left(cluster) fill_right(0)  |            <missing>              |  =  | method="GET",  status="404"                       (0 + 0) =    0 |
| method="POST", status="404"     3 |                                                  |                                   |     | method="POST", status="404"                       (3 + 0) =    3 |
|                                   |                                                  | status="500", cluster="eu1"   771 |     |                                                                  |
| method="GET",  status="500"    23 |                                                  \                                   /     | method="GET",  status="500", cluster="eu1"     (23 + 771) =  794 |
| method="POST", status="500"    42 |                                                                                            | method="POST", status="500", cluster="eu1"     (42 + 771) =  813 |
\                                   /                                                                                            \                                                                  /
```

### Possible parameter-less variants of the modifiers

To reduce verbosity, parameter-less variants of the modifiers could be introduced that use common default values, e.g.:

```
vector1 + fill vector2      # equivalent to vector1 + fill(0) vector2
```

For addition and subtraction, sensible default values could be `0`, while for multiplication and division, `1` could be used (less clear, often doesn't make sense). For other operations, there is likely no sensible default value.

### Supported operators

The new modifiers would be supported for:

* Arithmetic binary operators: `+`, `-`, `*`, `/`, `%`, `^`
* Comparison binary operators: `==`, `!=`, `>`, `<`, `>=`, `<=`
* Trigonometric binary operators: `atan2`

Not supported are:

* Set operators: `and`, `or`, `unless` (these already have their own semantics for handling missing series)

## Alternatives

* Do nothing and keep relying on the `or` operator to create default-valued series where needed. This is more cumbersome and less efficient, but avoids adding complexity to the binary operation syntax.
* Introduce a separate function (e.g., `fill_missing(series, default_value)`) that can be applied to either side of a binary operation. This would avoid modifying the binary operation syntax, but it would make no sense in isolation, since it would always need to be paired with a binary operation and then do a special cross-AST-node computation.
* Call the modifier `outer` (similar to OUTER joins in SQL) and have it always fill in missing series on both sides with automatic default values (like `0` for addition). This would be less flexible than allowing users to specify the default value and individual sides to fill in. The naming would also be very SQL-like and not very in line with existing PromQL terminology.
* Modify the operator syntax itself to indicate that missing series should be filled in. This would be more compact and more discoverable by autocompletion, but it's questionable whether this particular modifier should be treated as special as opposoed to all the other existing modifiers (`on`, `ignoring`, `group_left`, `group_right`). E.g.:
  * `vector1 +? vector2`: Fill in missing series with an automatic default value (e.g., `0` for addition).
  * `vector1 +?=23 vector2` to indicate filling in missing series with `23`. But: How would this work for the left side only or right side only?

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
