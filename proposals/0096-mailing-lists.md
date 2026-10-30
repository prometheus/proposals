# Prometheus Mailing Lists

## Prometheus Mailing Lists

* **Owners:**
  * `@SuperQ`

* **Implementation Status:** `Not implemented`

* **Related Issues and PRs:**

* **Other docs or links:**
  * `prometheus-team@googlegroups.com`

## Why

Historically the Prometheus Team used a private google groups list to discuss various internal matters.

With the current governance the OG Prometheus Team is effectively disolved. The new replacement is the
[Maintainer Role](https://github.com/prometheus/governance/blob/main/ROLES.md#maintainer).

A replacement email list sevice is needed.

### Pitfalls of the current solution

The current google group is outside of `prometheus.io` and is also a closed list.

## Goals

In order to provide a contact and communication forum for maintainers a new email list should be established.

* Single email address to contact maintainers.
* Provide an internal communication method for maintainers.
* Provide a distribution list for internal announcements.
* Provide a distribution list for calendar events.

### Audience

All of the Prometheus Community.

## Non-Goals

* Provide a private communication method for maintainers.
* Provide a replacement for our security contact list.

## How

Create a new email list on prometheus.io and populate it with the list of maintainers. This should probably
be added to the automated infra-as-code repo.

## Alternatives

We could esablish a new mailing list host. But this would make it more difficult to integrate with
the calendar system.
