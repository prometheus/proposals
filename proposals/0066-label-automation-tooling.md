# Label Automation Tooling

* **Owners:**
  * `@jan--f`

* **Implementation Status:** `Not implemented`

* **Related Issues and PRs:**
  * [PROM-65](https://github.com/prometheus/proposals/pull/65)

* **Other docs or links:**
  * [Prom-Prow Bot Implementation](https://github.com/jan--f/prom-prow) (to be
    moved to `prometheus` org)
  * [GitHub Actions: Add Labels to Issues](https://docs.github.com/en/actions/tutorials/manage-your-work/add-labels-to-issues)
  * [CNCF Hosted Tools](https://contribute.cncf.io/resources/services/hosted-tools/)
  * [Kubernetes Prow](https://docs.prow.k8s.io/)
  * [GitHub CODEOWNERS Documentation](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/customizing-your-repository/about-code-owners)

> TL;DR: This proposal recommends using a custom lightweight chat-ops bot
> (prom-prow) for Prometheus repositories. The bot provides Prow-style commands
> (`/lgtm`, `/cc`, `/label`, `/hold`) without the complexity of OWNERS files or
> running a full Prow instance. It uses GitHub's native collaborator permissions
> for command authorization and CODEOWNERS for automatic review assignment,
> providing bidirectional sync between `/lgtm` commands and GitHub UI approvals.

## Why

The label system proposed in PROM-65 introduces structured labels for issue and
PR workflow management. However, manually applying and managing these labels
would create significant overhead for maintainers and contributors. Automation
is essential to make the label system practical and effective.

The Kubernetes ecosystem has demonstrated that chat-ops style label management
(using `/label`, `/approve`, `/lgtm` commands in PR comments) can provide an
efficient and intuitive workflow for maintainers. This approach should be
adopted for Prometheus projects.

### Pitfalls of the current solution

Currently, Prometheus projects rely entirely on manual label application:

- Maintainers must navigate GitHub's UI to apply labels
- Difficult to enforce consistent labeling practices
- No automatic labeling based on PR content or actions

## Goals

Goals and use cases for the solution as proposed in [How](#how):

* Enable chat-ops style label management through PR comments
* Provide a lightweight, maintainable automation solution
* Support the label taxonomy defined in PROM-65
* Align with CNCF's preference for GitHub Actions where possible

### Audience

This proposal targets:

- Prometheus maintainers and contributors who need efficient label management
  tools

## Non-Goals

* Running a full Kubernetes-based Prow instance
* Implementing all Prow plugins and features
* Automatic merge functionality (at least initially)
* Replacing manual label operations

## How

### Proposed Architecture

This proposal recommends using the **prom-prow** bot, a custom lightweight chat-ops bot designed specifically for Prometheus repositories. The bot is implemented as a GitHub Action and provides Prow-style commands without requiring OWNERS files or running a full Prow instance.

### Prom-Prow Bot

The **prom-prow bot** is a custom GitHub Action that provides Prow-style chat-ops commands optimized for Prometheus workflows. Unlike existing Prow GitHub Actions, prom-prow is designed to work seamlessly with GitHub's native permission system and CODEOWNERS without requiring OWNERS files.

#### Supported Commands

The following commands are available in PR comments:

- **`/lgtm`**: Approve the PR
  - Anyone: Submits an approving GitHub review (if repository is configured to
    allow reviews by Actions)
  - Collaborators: Also adds `review/lgtm` label
  - PR authors cannot approve their own changes
- **`/lgtm cancel`**: Cancel approval
  - Anyone: Dismisses the user's review
  - Collaborators: Also removes `review/lgtm` label (only if no other collaborators have approved)
- **`/cc @user1 @user2`**: Request reviews from specified users (requires write access)
- **`/label <label>`**: Add label(s) to the PR (requires write access)
- **`/hold`**: Add `blocked/hold` label to prevent merging (requires write access)
- **`/unhold`**: Remove `blocked/hold` label (requires write access)

#### Key Features

- **No OWNERS Files Required**: Uses GitHub's native collaborator permissions
- **Bidirectional /lgtm Sync**: Both `/lgtm` command and GitHub UI approvals add the `review/lgtm` label
- **Automatic LGTM Removal**: Removes `review/lgtm` when new commits are pushed
- **Self-Approval Prevention**: PR authors cannot approve their own changes
- **Welcome Comments**: Posts helpful command documentation on new PRs
- **Two-Tier Permissions**:
  - Anyone can submit reviews via `/lgtm`
  - Only collaborators can manage labels
- **Works alongside CODEOWNERS**: Codeowners can be used for automatic review
  assignment

#### Example Configuration

GitHub Actions workflow (`.github/workflows/prometheus-bot.yml`):

```yaml
name: Prometheus Bot

on:
  issue_comment:
    types: [created]
  pull_request_review:
    types: [submitted]
  pull_request:
    types: [opened, synchronize]

jobs:
  bot:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      issues: write
      pull-requests: write
    steps:
      - uses: actions/checkout@v4
      - uses: prometheus/prom-prow@main
        with:
          github-token: ${{ secrets.GITHUB_TOKEN }}
```

Note that this currently uses the Dockerfile integration, i.e. builds the image
on every run. For a production setup we wouls push the action image to a
registry and pull from there.

#### Why Custom Bot Instead of Prow GitHub Actions or Prow?

- Works with existing CODEOWNERS (no migration needed)
- Uses GitHub's native collaborator permissions (no new files)
- Bidirectional sync: `/lgtm` command ↔ GitHub UI approval both add label
- Simpler permission model aligned with GitHub's access levels
- Lightweight and maintainable (single Go binary, ~300 lines of core logic)

See [below for alternatives](#alternatives) considered.

### Component 2: Initial Label Workflows

Simple GitHub Actions workflows automatically apply initial labels to new issues
and pull requests using the GitHub CLI (`gh`).

#### Issue Labeling

Automatically add `triage/needs-triage` to new issues.

`.github/workflows/label-issues.yml`:

```yaml
name: Label new issues
on:
  issues:
    types:
      - opened

jobs:
  label_issues:
    runs-on: ubuntu-latest
    permissions:
      issues: write
    steps:
      - run: gh issue edit "$NUMBER" --add-label "$LABELS"
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          GH_REPO: ${{ github.repository }}
          NUMBER: ${{ github.event.issue.number }}
          LABELS: triage/needs-triage
```

#### Pull Request Labeling

Automatically add `review/needs-review` to new pull requests.

`.github/workflows/label-prs.yml`:

```yaml
name: Label new pull requests
on:
  pull_request:
    types:
      - opened

jobs:
  label_prs:
    runs-on: ubuntu-latest
    permissions:
      pull-requests: write
    steps:
      - run: gh pr edit "$NUMBER" --add-label "$LABELS"
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
          GH_REPO: ${{ github.repository }}
          NUMBER: ${{ github.event.pull_request.number }}
          LABELS: review/needs-review
```

#### Benefits of This Approach

- **Simple**: Uses only GitHub CLI commands, no external actions needed
- **Maintainable**: Clear, straightforward YAML that's easy to understand
- **Flexible**: Easy to add multiple labels or conditional logic
- **Native**: Uses GitHub's built-in CLI tool
- **Lightweight**: No dependencies on third-party actions

#### Optional: Component Label Automation

If desired, component labels could be added based on file patterns using a simple
script, but this is optional since maintainers can easily apply component labels
using `/label component/X` commands during review.

### Integration with CODEOWNERS

The prom-prow bot is designed to work seamlessly with GitHub's native CODEOWNERS:

- **CODEOWNERS handles automatic review assignment**: When a PR is opened, GitHub automatically requests reviews from code owners based on the files changed
- **Prom-prow handles chat-ops commands**: Maintainers use `/lgtm`, `/cc`, `/label`, etc. for workflow management
- **Full compatibility**: CODEOWNERS can use teams, complex patterns, and all GitHub features

### Stale Issue Management (Optional)

If lifecycle labels are adopted, GitHub's `actions/stale` can automate stale
marking:

```yaml
name: Mark Stale Issues
on:
  schedule:
    - cron: '0 0 * * *'

jobs:
  stale:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/stale@v9
        with:
          stale-issue-label: 'lifecycle/stale'
          exempt-issue-labels: 'lifecycle/frozen'
          days-before-stale: 90
          days-before-close: 30
          stale-issue-message: 'This issue has been automatically marked as stale...'
```

### Implementation Plan

1. **Pilot in prometheus/prometheus**:
   - Deploy `.github/workflows/prometheus-bot.yml` workflow
   - Deploy simple initial labeling workflows for new issues and PRs
   - Document commands in CONTRIBUTING.md and link to that in welcome message

2. **Evaluate and Iterate**:
   - Gather feedback from maintainers after 1-2 months
   - Adjust bot configuration based on usage patterns
   - Consider additional commands if needed

3. **Roll Out to Other Repositories**:
   - Apply to other prometheus/* repositories
   - Customize per repository as needed (e.g., additional labels)

### Validation

Success will be measured by:

- Increased consistency in label application
- Positive feedback from maintainers on workflow efficiency

## Alternatives

### Alternative 1: Full Prow Instance

Run a complete Kubernetes-based Prow instance, as offered by CNCF.

**Advantages:**
- Full feature set including tide (automatic merging), automatic label management
- Battle-tested in Kubernetes ecosystem
- Most powerful automation capabilities
- Full plugin ecosystem

**Disadvantages:**
- Significant operational overhead (Kubernetes cluster required)
- CNCF steers projects toward GitHub Actions
- More complex to maintain and configure

**Rationale for rejection**: Too expensive to run and maintain relative to
benefits. CNCF recommends GitHub Actions, and prom-prow provides sufficient
functionality without operational overhead.

### Alternative 2: Prow GitHub Actions

Use the existing [Prow GitHub Actions](https://github.com/jpmcb/prow-github-actions) project.

**Advantages:**
- Community-maintained tool
- Provides Prow-style commands
- No Kubernetes infrastructure needed

**Disadvantages:**
- Requires OWNERS files (only supports single root OWNERS, no per-directory)
- No GitHub team support in OWNERS (individual usernames only)
- Does not interact with CODEOWNERS for review assignment
- No bidirectional sync (GitHub UI approvals don't trigger label automation)
- Would require maintaining both OWNERS and CODEOWNERS

**Rationale for rejection**: Requires migrating to OWNERS files or maintaining
dual configuration. Prom-prow provides better integration with GitHub's native
features (CODEOWNERS, collaborator permissions, UI approvals) while being
simpler to maintain.

## Action Plan

* [ ] Review and accept this proposal
* [ ] Deploy prom-prow bot
  * [ ] Create `.github/workflows/prometheus-bot.yml`
* [ ] Deploy initial label workflows
  * [ ] Create `.github/workflows/label-issues.yml` (adds `triage/needs-triage`)
  * [ ] Create `.github/workflows/label-prs.yml` (adds `review/needs-review`)
* [ ] Documentation
  * [ ] Update CONTRIBUTING.md with chat-ops commands
  * [ ] Announce to prometheus-developers mailing list
* [ ] Pilot period (1-2 months)
  * [ ] Gather maintainer feedback
  * [ ] Monitor for any issues
  * [ ] Adjust if needed
* [ ] Roll out to other repositories
  * [ ] Apply to alertmanager, client_golang, etc. on maintainers request
* [ ] Optional: Add stale issue automation (if lifecycle labels adopted)
