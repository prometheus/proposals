# proposals

This repository holds all the past and current proposals for the Prometheus Ecosystem. It’s the single place for
reviewing, discovering, and working on the design documents. It is also a record of past decisions and approvals.

## Current Proposals

* The [PRs with the `proposal` label](https://github.com/prometheus/proposals/pulls?q=is%3Aopen+is%3Apr+label%3Aproposal) show all the pending proposals.
* The [proposals directory](./proposals) shows all the accepted proposals. See the “Implementation Status” for details on the implementation.
* The [PRs with the `proposal` label that are closed without merging](https://github.com/prometheus/proposals/pulls?q=is%3Apr+label%3Aproposal+is%3Aclosed+is%3Aunmerged) show all the rejected proposals.

## What’s a Design Document?

It’s essential to clearly explain the reasons behind certain design decisions to have a community consensus. This is especially
important in Prometheus, where every decision might have a significant impact given the high adoption and stability of the software and standards we work on.

In our world, no decision is perfect, so having a design document explaining our trade-offs is essential.
Such a document can also be used later as a reference and for knowledge-sharing purposes.

Design documents do not always reflect what has been (or will be) implemented. Implementation details
might have changed since a feature was merged. Design docs are not considered documentation and can not define a standard.
Instead, it should explain the motivation, scope, decisions, and alternatives considered.

## Proposal Process

Don’t get scared to propose ideas! It’s amazing to innovate in the open and get feedback on ideas.

The process of proposing a change via a design document is the following:

1. Fork `github.com/prometheus/proposals`.
2. Create a GitHub Pull Request with a design document in markdown format to the [proposals directory](./proposals). Make sure to use the [template](0000-00-00_template.md) as the guide for what sections should be present in the document. Put the creation date (the day you started preparing this design document) as the prefix and some unique name as the suffix in the file name. Once the PR is proposed, a maintainer will assign a `proposal` label.
   1. If you prefer Google Docs to any other collaboration tool, feel free to use it in the initial state. We recommend the [Open Source Design document Template](https://docs.google.com/document/d/1zeElxolajNyGUB8J6aDXwxngHynh4iOuEzy3ylLc72U/edit#). However, the approval process will only happen officially in the Pull Request.
3. An automatic formatter is enabled in the repository. Use `make` locally to trigger the formatting of all markdown documents (requires a working Go environment). Use `make check` to check all links (will be done by the CI pipeline, too).
4. After a sufficient amount of discussion, the Prometheus team will try to reach a consensus of accepting or rejecting the proposal. In the former case, the PR gets merged. In the latter case, the PR get closed with meaningful reasons why the proposal was rejected.
   1. If more eyes are needed or no consensus was made: Propose your idea as an agenda item for the [Prometheus DevSummit](https://docs.google.com/document/d/11LC3wJcVk00l8w5P3oLQ-m3Y37iom6INAMEu2ZAGIIE/edit) or announce it to the [developer mailing list](https://groups.google.com/forum/#!forum/prometheus-developers) to gather more information. You are welcome to start working on the design document before a bigger discussion—it is often easier to discuss with prior details provided. Be prepared that the idea might be rejected later. Still, the record of the document in the Pull Request is valuable even in a rejected state to inform about past decisions and opportunities considered.
   2. To merge the PR, we need approval (consensus) from the maintainers of the related component(s).
   3. Optionally: Find a sponsor among the Prometheus maintainers to get momentum on a change.

Once the PR gets merged, the design document can change, but it requires (less strict, but still) a PR with review and merge by a maintainer.
