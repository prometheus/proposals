## Remote Write 2.0

* **Owners:**
  * Alex Greenbank [@alexgreenbank](https://github.com/alexgreenbank/) [alex.greenbank@grafana.com](mailto:alex.greenbank@grafana.com)
  * Bartłomiej (Bartek) Płotka [@bwplotka](https://github.com/bwplotka) [bwplotka@gmail.com](mailto:bwplotka@gmail.com)
  * Callum Styan [@cstyan](https://github.com/cstyan) [callumstyan@gmail.com](callumstyan@gmail.com)

* **Implementation Status:** `Partially implemented`

* **Related Issues and PRs:**
  * [Remote Write 2.0](https://github.com/prometheus/prometheus/issues/13105)

* **Other docs or links:**
  * [Existing Remote Write 1.0 Specification](https://prometheus.io/docs/concepts/remote_write_spec/)
  * [Remote Write 2.0 Draft Specification](https://docs.google.com/document/d/1PljkX3YLLT-4f7MqrLt7XCVPG3IsjRREzYrUzBxCPV0/edit#heading=h.3p42p5s8n0ui)

> TL;DR: A new Remote Write format that is more efficient in terms of network bandwidth, and including new features such as Metadata for all series and other small improvements that have been waiting for a major protocol version bump.

## Why

Some proposed changes to the Remote Write protocol are not possible without breaking backwards compatibility. A new major protocol version provides the ability to make non-backwards compatible changes that should make the senders and receivers of Remote Write more efficient in terms of network bandwidth and possibly CPU utilisation (if changes to the compression are found to be beneficial).

The new protocol should also allow content negotiation to ensure that servers that send and/or receive via the Remote Write protocol can indicate their ability to handle the newer version and fall back to the existing 1.0 format if desired.

### Pitfalls of the current solution

The existing Remote Write 1.0 protocol is not as efficient is it could be in terms of its network bandwidth usage. The current protocol also cannot be changed without breaking many existing sending or receiving clients. In order to add new features/functionality a new version of the protocol specification is required.

The metadata gathered and sent in the existing Remote Write 1.0 protocol was deduplicated per metric `family` (unique `__name__` value) rather than per series. This could lead to incorrect metadata being passed on to the receiving server if the metadata was not consistent across different labels for series with the same `__name__` label value.

## Goals

* Reduce the network bandwidth used for sending Remote Write data
* Investigate possible changes to compression/encoding used for Remote Write data to see if further network bandwidth improvements can be made without compromising CPU usage for either the sending or receiving server
* Collect and annotate each individual time series with metadata via metadata collection from the WAL
* Implement other small items (see the meta issue) that cannot be implemented without changes to the existing Remote Write 1.0 protocol specification.

### Audience

* Operators and administrators of Prometheus servers that forward data on to other servers using the Remote Write protocol.
* Developers of other systems that accept or send using the Prometheus Remote Write protocol.

## Non-Goals

* Not mandating support for lots of alternative compression systems
* Not breaking backwards compatibility by forcing the use of Remote Write 2.0 only

## How

Details can be found in the [Remote Write 2.0 Draft Specification](https://docs.google.com/document/d/1PljkX3YLLT-4f7MqrLt7XCVPG3IsjRREzYrUzBxCPV0/edit#heading=h.3p42p5s8n0ui).

## Alternatives

The section stating potential alternatives. Highlight the objections reader should have towards your proposal as they read it. Tell them why you still think you should take this path [[ref](https://twitter.com/whereistanya/status/1353853753439490049)]

1. (See some comments in the [Remote Write 2.0 Draft Specification](https://docs.google.com/document/d/1PljkX3YLLT-4f7MqrLt7XCVPG3IsjRREzYrUzBxCPV0/edit#heading=h.3p42p5s8n0ui).)
2. The use of `HEAD` to probe the remote receiver for protocol support was certainly a point that caused some discussion. The alternative is to follow [the existing 1.0 spec](https://prometheus.io/docs/concepts/remote_write_spec/) and `Senders who wish to send in a format >1.x MUST start by sending an empty 1.x, and see if the response says the receiver supports something else.`. This is still possible under this 2.0 proposal but (IMHO) the availibility of the `HEAD` makes for a "cleaner" interface as `HEAD` implies an idempotent operation that, barring separate metric updates, should have no other side effects.

## Action Plan

The tasks to do in order to migrate to the new idea.

* [ ] [Remote Write 2.0 meta issue](https://github.com/prometheus/prometheus/issues/13105)
