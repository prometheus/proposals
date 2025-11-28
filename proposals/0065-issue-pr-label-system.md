# Issue and Pull Request Label System

* **Owners:**
  * `@jan--f`

* **Implementation Status:** `Not implemented`

* **Related Issues and PRs:**
  * [PROM-66](https://github.com/prometheus/proposals/pull/66)

* **Other docs or links:**
  * [Kubernetes Label Documentation](https://github.com/kubernetes/test-infra/blob/master/label_sync/labels.md)

> TL;DR: This proposal establishes a label system for issues and pull requests
> in Prometheus projects, providing clear signals about what needs attention
> from reviewers or authors, what is actionable, and what is blocked. The
> system is inspired by Kubernetes labels and designed to work with automated
> tooling (see PROM-66).

## Why

As Prometheus projects grow, the volume of issues and pull requests increases.

Without a clear labeling system, it becomes difficult to:

- Identify which issues and PRs need immediate attention
- Understand whether action is required from maintainers, reviewers or author
- Clearly mark items that can be worked on by (new) contributors versus ones that need to be evaluated for validity, e.g. bugs that are considered invalid
- Maintain an efficient review and triage workflow

A systematic approach to labels helps contributors and maintainers quickly
understand the state of any issue or PR and take appropriate action.

### Pitfalls of the current solution

Currently, there is no standardized label system across Prometheus projects. This leads to:

- Inconsistent labeling practices across repositories
- Difficulty in identifying what requires attention
- PRs and issues that languish without clear ownership or next steps
- No clear signal for when an item is blocked versus ready for action
- Maintainer time wasted re-evaluating items that haven't changed state
- Contributors time wasted by working on untriaged issues which might be invalid

## Goals

Goals and use cases for the solution as proposed in [How](#how):

* Provide clear signals about issue and PR lifecycle states
* Make it obvious which items need attention from reviewers versus authors
* Distinguish between actionable items and those waiting on external dependencies
* Enable automated tooling to assist with workflow management
* Create consistency across Prometheus ecosystem repositories
* Reduce maintainer cognitive load when evaluating what needs attention
* Help new contributors to identify suitable issues to work on

### Audience

This proposal targets:

- Prometheus maintainers who need to triage and review issues/PRs
- Contributors who need to understand the state of their submissions
- Automated tooling that helps manage workflow

## Non-Goals

* Defining how labels are automatically applied (this will be covered in a separate proposal)
* Creating labels for every possible state or condition
* Retroactively labeling all existing issues and PRs

## How

### Label Categories

This proposal defines three core label categories (plus an optional fourth for future use) that work together to manage issue and PR workflow:

#### 1. Triage Labels

These labels indicate whether an issue has been evaluated and is ready for work:

- **`triage/needs-triage`**: Initial state for all new issues. Indicates the issue needs initial evaluation by a maintainer to determine validity, priority, and next steps.
- **`triage/accepted`**: Issue has been triaged and accepted as valid work. It is ready for someone to work on.
- **`triage/needs-information`**: Issue needs more details from the author before it can be properly evaluated or worked on.

**Workflow**: All issues start with `triage/needs-triage`. During triage, maintainers either replace this with another triage label or remove it entirely. The absence of any triage label (along with issue comments) indicates that triage action has been taken and the issue is currently being worked on. Declined or duplicate issues should also have no `triage/` label.

#### 2. Review Labels

These labels manage the pull request review lifecycle:

- **`review/needs-review`**: Initial state for all new PRs. Indicates the PR needs review from maintainers.
- **`review/changes-requested`**: Reviewers have requested changes. Author action is needed.
- **`review/lgtm`**: "Looks Good To Me" - PR has received approval from reviewers. If an approving reviewer is code owner the PR is ready to be merged.

**Workflow**: All PRs start with `review/needs-review`. After review, this transitions to either `review/changes-requested` or `review/lgtm`. After requested changes have been addressed, a PR transitions back to `review/needs-review`. Once approved by appropriate maintainers, it becomes `review/lgtm`.

#### 3. Blocking Labels

These labels indicate that an issue or PR cannot proceed:

- **`blocked/needs-decision`**: Waiting for architectural or design decision
  from maintainers or community.
- **`blocked/hold`**: Explicitly placed on hold by a maintainer. Should not be merged or closed even if otherwise ready.

**Workflow**: These labels can be applied at any time when the item becomes blocked. They should be removed when the blocking condition is resolved.

#### 4. Lifecycle Labels

These labels track the activity status of issues and PRs. Prometheus has an [automation in place](https://github.com/prometheus/prometheus/blob/96d3d641e329c049f649edbd4c2695345c027c56/.github/workflows/stale.yml) that would only require adjusting the label values.

- **`lifecycle/stale`**: No activity for an extended period (currently 30 days). Candidate for closure if no activity resumes.
- **`lifecycle/keepalive`**: Should not be marked stale due to inactivity. Reserved for important long-running items.

### Label Interactions

Labels from different categories work together:

- **Active PR ready for review**: `review/needs-review` (no blocking labels)
- **PR waiting on author**: `review/changes-requested`
- **PR approved but held**: `review/lgtm` + `blocked/hold`
- **Issue accepted and ready**: `triage/accepted` (no blocking labels)
- **Issue needing more info**: `triage/needs-information`
- **Issue declined or duplicate**: No triage label (removed after triage with explanatory comment)

### Existing Label Taxonomies

This section documents the existing label taxonomies currently in use across
Prometheus repositories, particularly in prometheus/prometheus. These labels are
included here for documentation purposes and reflect current practice. The
proposal above aims to replace some of the currently in use labels.

#### Component and area Labels

Component labels indicate which part of the codebase an issue or PR affect.
Area labels provide additional categorization for cross-cutting concerns.
A few examples of currently used labels:

- **`component/api`**: HTTP API
- **`component/promql`**: PromQL query engine
- **`component/promtool`**: promtool CLI utility
- **`component/rules`**: Recording and alerting rules
- **`component/scraping`**: Metric scraping and service discovery
- **`component/service discovery`**: Service discovery mechanisms
- **`component/tsdb`**: Time series database (storage engine)
- **`component/ui`**: Web UI
- **`area/build`**: Build system and build process
- **`area/ci-cd`**: Continuous integration and deployment
- **`area/opentelemetry`**: OpenTelemetry integration and compatibility
- **`area/utf8`**: UTF-8 support and related issues

**Usage**: Issues and PRs typically have one or more component labels to
indicate the affected areas. Multiple component labels may be applied if changes
span multiple components. Area labels are less commonly used than component
labels and typically indicate cross-cutting concerns or specific initiatives.

#### Kind Labels

Kind labels categorize the type of change or issue:

- **`kind/bug`**: Something is broken or not working as intended
- **`kind/enhancement`**: Improvement to existing functionality
- **`kind/feature`**: Entirely new functionality
- **`kind/cleanup`**: Code cleanup, refactoring or technical debt reduction
- **`kind/optimization`**: Performance improvements
- **`kind/change`**: General change that doesn't fit other categories
- **`kind/breaking`**: Breaking change that affects backward compatibility

**Usage**: Issues and PRs typically have exactly one kind label to indicate the primary nature of the change. The kind label helps communicate the impact and urgency of the change.

#### Priority Labels

Priority labels indicate the urgency and importance of an issue or PR:

- **`priority/P0`**: Critical priority - requires immediate attention (e.g., production outages, security issues)
- **`priority/P1`**: High priority - should be addressed in the current release cycle
- **`priority/P2`**: Medium priority - should be addressed soon but not urgent
- **`priority/P3`**: Low priority - nice to have but can wait
- **`priority/Pmaybe`**: Lowest priority - may or may not be addressed; needs further discussion

**Usage**: Priority labels are typically assigned during triage and help maintainers and contributors understand what to work on first. Not all issues have priority labels assigned.

#### Other Common Labels

Many other labels are currently in use. this proposal does not seek to prescribe
any changes to how all labels are used. For example to following are well
established and usefule:

- **`help wanted`**: Good issues for external contributors
- **`good first issue`**: Good for newcomers to the project
- **`low hanging fruit`**: Easy to implement
- **`not-as-easy-as-it-looks`**: Appears simple but has hidden complexity

Other labels should probably be unified into the label taxonomy proposed above.

For example:

- **`duplicate`**: Duplicate of another issue
- **`invalid`**: Issue is not valid or is spam
- **`won't fix`**: Issue will not be addressed
- **`stale`**: No recent activity
- **`keepalive`**: Should not be marked stale or auto-closed

**Usage**: These labels serve various workflow and community needs. Some are
applied manually, while others (like `dependencies`) are often applied
automatically. Some labels should be abandoned in favor of the structured labels
proposed above.

### Implementation Considerations

This proposal focuses on defining the label taxonomy. A separate proposal will address:

- Automation for applying initial labels (e.g., `triage/needs-triage` on new issues)
- Automation for lifecycle labels based on activity (optional)
- Integration with tooling to make it easier to apply labels consistently

### Validation

Success will be measured by:

- Reduced time to first triage for new issues
- Clearer visibility into PR review pipeline
- Fewer "lost" or forgotten issues and PRs
- Positive feedback from maintainers about workflow clarity
- Successful integration with automated tooling

## Alternatives

### Alternative 1: Minimal Label Set

Use only `needs-triage`, `needs-review`, and `hold` labels.

**Rationale for rejection**: Too minimal. Doesn't provide enough granularity to distinguish between "waiting on author" vs "waiting on maintainer" vs "blocked externally", which are common and important states.

### Alternative 2: Use Existing GitHub Features Only

Rely on GitHub's built-in review states, assignees, and milestones without custom labels.

**Rationale for rejection**: GitHub's native features don't provide sufficient granularity for triage states or blocking conditions. Custom labels allow for automation and clearer communication of project-specific workflow.

### Alternative 3: Adopt Kubernetes Labels Exactly

Use the exact label names and taxonomy from Kubernetes.

**Rationale for rejection**: While Kubernetes provides excellent inspiration, Prometheus has different workflow needs. For example, the proposed `review/*` namespace is more explicit than Kubernetes's use of `lgtm` and `approved` at the root level. The proposal aims for clarity over brevity.

## Action Plan

* [ ] Review and accept this proposal (establishes label taxonomy)
* [ ] Create labels
* [ ] Pilot the label system in one repository (e.g., prometheus/prometheus)
* [ ] Document label meanings in contributor guides
* [ ] Set up automation for lifecycle labels (stale/rotten) (optional)
