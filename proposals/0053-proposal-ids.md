## Proposal IDs

* **Owners:**
  * `@bwplotka`

* **Implementation Status:** `Implemented`

* **Related Issues and PRs:**
  * https://github.com/prometheus/proposals/issues/51

> TL;DR: We propose every Prometheus proposal has a stable reference/ID in the form of the PROM-<number>. The number is the PR ID from the original PR that was used to discuss and approve the proposal.

## Why

It's important to reference decisions made in the proposal in the following development (code, docs, discussions). Currently, we either have some tribal naming for a proposal, link to a proposal repo PR when proposal is not yet approved or GH link to the proposal file with that original `<date>-template.md`.

We want to ensure that "link" is even more consistent, stable and short than the current approach.

### Pitfalls of the current solution

* We use inconsistent references (name, PR link, file link).
* The references e.g. links are hard to use (e.g. mentioning in the code commentary) and hard to memorize.
* The date in the file is usually misleading. It's a creation date vs approval date (the latter might be what we usually expect).
* While we try to ensure links in the `proposal/` directory never change, there's a risk we break those one day.

## Goals

Goals and use cases for the solution as proposed in [How](#how):

* Each proposal has a short, memorable and unique ID.

## How

We propose every Prometheus proposal has a stable reference/ID in the form of the `PROM-<number>`. This number is captured in the file name and it originates from the ID of the Pull Request that was used to approve and merge the proposal.

We propose to NOT add a stable number of digits in the official referencing. However, we propose we DO add a stable number of digits in the file name, so the file browsing has a convenient ordering. We propose 4 digits for now, prefixed by zeros, which can be increased to 5 once we have PR numbers in ten-thousands (likely in a decade).
 
For example, this proposal is referenced as `PROM-53`, because we proposed this in the [PR `#53`](https://github.com/prometheus/proposals/pulls/53). This proposal file name is then `0053-proposal-ids.md`.

For the existing proposals, we propose to rename existing proposal's file to have its PROM-<number> (based on their initial PRs), but leave the old files with a link to a new file, so the old links work.

## Alternatives

### Different Prefixes

There are a few alternatives to the `PROM-` prefix e.g.

* PEP- ("Prometheus Enhancement Proposal")
  * Consistent with K8s and Otel, but Prometheus community never used "EP" naming.
* P- or PP- ("Prometheus Proposal")
  * Short but NOT clearly unique for Prometheus (e.g. Python [PEPs](https://peps.python.org/)) and not suggesting proposals
* PROMETHEUS-
  * A bit too long?

## Action Plan

The tasks to do in order to migrate to the new idea.

* [X] Adjust template and proposal docs.
* [x] Rename each existing proposal's file to have its PROM-<number>; Leave the old files with a link to a new file, so the old links work.
