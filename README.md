# proposals

This repository holds all the past and current proposals for the Prometheus Ecosystem. It's the single place for
reviewing, discovering and working on the design documents. It also a record of the past decisions and approvals.

* [The PRs with proposal label](https://github.com/prometheus/proposals/pulls?q=is%3Aopen+is%3Apr+label%3Aproposal) shows all the pending proposals.
* The [proposals directory](./proposals) shows all the accepted proposals. See the "Implementation Status" for details on the implementation.
* [The unmerged PRs with proposal label](https://github.com/prometheus/proposals/pulls?q=is%3Apr+label%3Aproposal+is%3Aclosed+is%3Aunmerged) shows all the rejected proposals.

## What's the Design Document?

It's essential to clearly explain the reasons behind certain design decisions to have a community consensus. This is especially
important in Prometheus, where every decision might have a significant impact given the high adoption and stability of the software and standards we work on.

In our world, no decision is perfect, so having a design document that explains the trade-offs we made is essential.
Such a document can also be used later on as a reference and for knowledge-sharing purposes.

Note that design documents do not always reflect exactly what has been (or will be) implemented. Implementation details
might have changed since a feature was merged. Design docs are not considered documentation and can not define a standard.
Instead, it should explain the motivation, scope, the decision made and alternatives considered.

## Proposing a New Idea

Don't get scared to propose ideas! It's amazing to innovate in the open and get feedback on the ideas.

The process of proposing change with the design document would look as follows:

1. Fork `github.com/prometheus/proposals`.
2. Create a GitHub Pull Request with a design document in the markdown format to the [proposals directory](./proposals). Make sure to use [template](0000-00-00_template.md) as the guide for what sections should be present in the document. Put the creation date (the day you started preparing this design document) as the prefix and some unique name as the suffix in the file name. Once the PR is proposed, maintainer will assign "proposal" label.
   1. If you prefer Google Docs to any other collaboration tool, feel free to use it in the initial state. We recommend [Open Source Design document Template](https://docs.google.com/document/d/1zeElxolajNyGUB8J6aDXwxngHynh4iOuEzy3ylLc72U/edit#). However, the approval process will only happen officially in the Pull Request.
3. Automatic formatter is enabled in the repository. Use `make` locally to format it. Use `make check` to check all links (will be done on the CI too).
4. The design is accepted if the PR is merged into this repository. It's ok to eventually decide to reject the proposal and close the PR with meaningful reasons for why it was rejected.
   1. If more eyes are needed, or no consensus was made: Propose and announce your idea on
      [Prometheus DevSummit](https://docs.google.com/document/d/11LC3wJcVk00l8w5P3oLQ-m3Y37iom6INAMEu2ZAGIIE/edit) or mailing list to gather more information. You are welcome to start working on the design document before a bigger discussion--it is often easier to have a discussion with prior information provided. Be prepared that the idea might be rejected later--still, the record of the document in the Pull Request is useful even in rejected state to inform about past decisions and opportunities considered.
   2. To merge the PR, we need approval (consensus) from the maintainers of the related component(s).
   3. Optionally: Find a sponsor among Prometheus maintainers to get momentum on a change.

Once PR get merged, the design document can change, but it requires (less strict, but still) a PR with review and merge by a maintainer.
