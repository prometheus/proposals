## Nominate maintainers via pull requests to `org-infra`

* **Owners:**
  * Solomon Jacobs [@SoloJacobs](https://github.com/SoloJacobs)

* **Implementation Status:** `Not implemented`

* **Related Issues and PRs:**
  * https://github.com/prometheus/proposals/pull/95
  * https://github.com/prometheus/org-infra/pull/160

* **Other docs or links:**
  * [prometheus/org-infra](https://github.com/prometheus/org-infra)
  * [PROM-95: Standardize Prometheus GitHub teams and repository access](./0095-teams-and-org-permissions.md)
  * [Prometheus Community Roles](https://github.com/prometheus/governance/blob/main/ROLES.md)

> TLDR: Change `ROLES.md` so that maintainer nominations are pull requests against the team definitions in `prometheus/org-infra` instead of against a repository's `MAINTAINERS.md`.

## Why

[PROM-95](./0095-teams-and-org-permissions.md) makes a `<repository>-maintainers` team the source of truth for who maintains a repository and has automation open pull requests to keep `MAINTAINERS.md` in sync with that team. `ROLES.md` still says:

> Any current Maintainer may nominate a current Member to become a new Maintainer by opening a PR, adding them to the `MAINTAINERS.md` file.

With PROM-95 in place, merging such a PR changes a file that automation derives from the team, not the team itself. The nomination process should target the source of truth directly.

### Pitfalls of the current solution

A nomination merged into `MAINTAINERS.md` does not grant any access. Someone still has to update the team by hand, and until then the next sync from the team reverts the file.

## Goals

* Make the Maintainers team in `org-infra` the only place where maintainership is changed.
* Keep the existing nomination rules in `ROLES.md`.

## Non-Goals

* Change who may nominate, or how objections work.

## How

Replace the nomination step in `ROLES.md`.

`MAINTAINERS.md` files contain more than the maintainer list, for example in `prometheus/client_rust`:

```markdown
# Maintainers

- Krisztian Fekete <prometheus@krisztianfekete.org> @krisztianfekete

## Emeritus

- Max Inden <mail@max-inden.de> @mxinden
```

Such free text is added to `team-members.yaml` and rendered into `MAINTAINERS.md` by the sync, so `MAINTAINERS.md` still serves its documentation purposes.

## Alternatives

1. Keep nominations in each repository's `MAINTAINERS.md` and have automation read these files and sync them into `org-infra`. This makes synchronization more fragile in both directions. For instance, each repo would have to ensure that `MAINTAINERS.md` stays machine readable.

## Action Plan

* [ ] Update the nomination step in `prometheus/governance/ROLES.md`.
* [ ] Add free text to `team-members.yaml` and sync it into `MAINTAINERS.md`.
* [ ] Update the "Source of Authority" section of `org-infra/proposal.md`, which still names `MAINTAINERS.md` as the source of truth for maintainers.
