## SPIFFE Support

* **Owners:**
  * `kfox1111`

* **Implementation Status:** `Partially implemented`

* **Related Issues and PRs:**
  * https://github.com/prometheus/exporter-toolkit/issues/259
  * https://github.com/prometheus/exporter-toolkit/pull/387

> TL;DR: Flip a switch and exporters can mTLS with SPIFFE based identities

## Why

TLS is hard and manual. mTLS is even harder.

SPIFFE and its corresponding reference implementation SPIRE makets it very easy to get fresh certificates in a fully automatic way.
Connections between prometheus and exporters can be two way validated and encrypted.

### Pitfalls of the current solution

The main issue right now is the go-spiffe library pulls in otel and that pulls in a lot of dependencies. They compile out, but it looks bad.

## Goals

Support easy configuration of prometheus and exporters

### Audience

If not clear, the target audience that this change relates to.

## Non-Goals

* Move old designs to the new format.
* Not doing X,Y,Z.

## How

We add SPIFFE support to the exporter-toolkit and prometheus scrape configuration

## Alternatives

Today you can wrap every exporter in a SPIFFE supporting proxy and put a proxy inbetween prometheus and the exporter too. It's painful. The idea is security should be easy.

## Action Plan

The tasks to do in order to migrate to the new idea.

* [ ] Implement support in the exporter-toolkit
* [ ] Implement support in prometheus
