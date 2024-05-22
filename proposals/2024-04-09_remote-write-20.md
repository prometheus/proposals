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
  * Content Negotiation Proposals
    * [Remote Write 2.0 Content Negotiation Proposal (first attempt)](https://docs.google.com/document/d/1jx1fqpRnM0pAndeo3AgY7g6BLxN3Ah8R0Mm8RvNsHoU/edit)
    * [Remote Write 2.0 Content Negotiation Proposal (second attempt)](https://docs.google.com/document/d/16ivhfAaaezNpB1OVs3p83-_ZZK-8uRgktqtcpYT2Sjc/edit)
    * [Final decision for Remote Write 2.0 Content Negotiation](https://docs.google.com/document/d/1N4MQFmJjNoTuH7VhIiCny3jNkDyXnufBMYeggNZdITc/edit)
  * [Remote Write 2.0 Retries & Backoff Proposal](https://docs.google.com/document/d/1LjR0xm6Fw65vtFh8NjquaXyVRkw6d1vncOJ6he6o2QA/edit)
  * [Sample vs Histogram Sample semantics in one TimeSeries](https://docs.google.com/document/d/1fSu5OhytmZAMo5OwfWmaAFHL_tbUlFsS8S1N9M2Yt2Y/edit)
   

> TL;DR: We [propose a new version of the Prometheus Remote Write (PRW) specificiation with a new format](https://github.com/prometheus/docs/pull/2462) that is more efficient, and includes important features such as always-on metadata, native histograms
> (including a new custom native histogram support), optional created timestamp and exemplars.

## Glossary

* "PRW" stands for Prometheus Remote Write protocol.
* a "Sender" is something that sends PRW data.
* a "Receiver" is something that receives PRW data.

## Why

The existing PRW 1.0 protocol was proven very useful for the reliable and efficient real-time metric streaming using Prometheus data-model. It is adopted by wider metric ecosystem beyond Prometheus e.g. Cortex, Thanos, Grafana Cloud and tools (Mimir, Tempo, Alloy, k6 etc), AWS, Microsoft Azure, Alibaba, Chronosphere, Red Hat, IBM, Vector, Fluentbit, New Relic, Logz.io, Elastic, InfluxDB, Yandex and many more.

However, PRW 1.0 is not as efficient is it could be in terms of its network bandwidth usage. PRW 1.0 also does not officially support the newest Prometheus features like metadata, exemplars, native histograms (exponential and custom bucketing), created timestamp. Adding those features, in a naive way, to existing PRW 1.0 proto message without further changes would further regress network bandwidth and other efficiency characteristics.

Some features like [metadata](https://github.com/prometheus/prometheus/blob/remote-write-2.0/prompb/remote.proto#L27), [exemplars](https://github.com/prometheus/prometheus/blob/remote-write-2.0/prompb/types.proto#L128) and [histograms](https://github.com/prometheus/prometheus/blob/remote-write-2.0/prompb/types.proto#L129) are in-officially added to PRW as an experimental feature.

Notably for metadata, it is currently deduplicated per metric `family` (unique `__name__` value) rather than per series. This leads to incorrect metadata being passed on to the receiving server if the metadata was not consistent across different labels for series with the same `__name__` label value. Furthemore, current protocol for metadata is to send it in a separate message leading to stateful protocol trade-offs.

The other problem is that proto definition is integrated with the Remote Read protocol which is a bit less adopted and follows entirely different semantics and negotiation. We might want to decouple those for different protocol lifecycle between write and read.

Additionally, PRW 1.0 has some adoption limitation for the backends which require metadata (e.g. metric type) and/or created timestamp for counter and histograms.

Finally, PRW 1.0 does not define any content negotiation mechanism for different compressions and proto messages as of now.

As a result, this document proposes a new PRW 2.0 specification solving those issues.

## Goals

* Reduce the network bandwidth used for sending PRW data.
* Reduce, or at least, don't increase resources needed to compress/decompress/encode/decode PRW messages.
* Allow new features that Prometheus adopted, but PRW 1.0 didn't officially specify (e.g. metadata, exemplars, native histograms (exponential and custom bucketing), created timestamp)
* Keep PRW stateless.
* Increase adaptability of PRW protocol.
* It is possible to implement Senders that can support both PRW 1.0 and 2.0.
* It is possible to implement Receivers that will serve PRW 1.0 and 2.0 under a single endpoint.

## Non Goals

* Forcing Receiver implementations to support exotic compression that might impact receiving performance.
* Impact Remote Read protocol.

### Audience

This proposal is for all the existing and potential users of the PRW protocol, so those who needs to reliably propagate samples in real-time from a sender to a receiver, without loss. This means end-users, but also Sender and Receiver developers and operators.

## How (Decision Trail)

The exact proposed PRW 2.0 specification can be found in https://github.com/prometheus/docs/pull/2462. Feel free to give feedback around typos, wording choice and definitions there. This document focuses on rationales and alternatives the team went through when designing PRW 2.0.

For detailed track of our work around the protocol see **Other docs or links** in the beginning of this document as well as:
* [Notes to public sync meeting](https://docs.google.com/document/d/1TYKB_XqVgkEZlxosQ9BM0XR8JFi0pctlNQ-gdu1wuRw/edit)
* Our CNCF slack channel `#prometheus-prw2-dev`

Let's go over major design decisions and changes over 1.0.

### A new protobuf message, identified by fully qualified name

PRW 2.0 defines [a new protobuf message](https://github.com/prometheus/prometheus/blob/remote-write-2.0/prompb/io/prometheus/write/v2/types.proto#L32). As of PRW 2.0, Sender will be able to choose to encode its samples using either the new one or [existing message defined in PRW 1.0](https://github.com/prometheus/prometheus/blob/remote-write-2.0/prompb/remote.proto). For this reason PRW 2.0 defines identify proto messages by its **fully-qualified name** which consist of proto package and message name (as defined by [buf style guide](https://buf.build/docs/reference/protobuf-files-and-packages#packages). As a result, PRW Senders and Receivers can support both (or only one) from the following:

* (new one) [`io.prometheus.write.v2.Request`](https://github.com/prometheus/prometheus/blob/remote-write-2.0/prompb/io/prometheus/write/v2/types.proto#L32)
* [`prometheus.WriteRequest`](https://github.com/prometheus/prometheus/blob/remote-write-2.0/prompb/remote.proto). Note that we could change it's fully qualified name to match the style guide, but we decided to not touch it for the best possible compatibility guarantee with the old senders/receivers. 

The rationales for defining a new message, instead of reusing old one are:

* We decided to use [string interning mechanism](#string-interning) for all labels we transfer via PRW. This requires completely new fields for all labels. Adding this to the existing message would be not only confusing, but also highly inefficient as for backward compatibility senders would need to allocate and encode BOTH old labels (string copies) and new ones (symbol table and references). Note that labels are the most significant size contributors in PRW messages.
* We can remove the old reserved fields, we can reorder fields in proto for clarity.
* We can separate remote read proto messages from remote write. They start to follow completely different versioning, content negotiation and protocol semantics, thus it makes sense to split proto definitions completely.

### Basic Content Negotiation

PRW 2.0 builds on top of the existing PRW 1.0 content negotiation, which defined hardcoded `Content-Type: application/x-protobuf` and `Content-Encoding: snappy` headers. PRW 2.0 specifies that those headers must follow [the RFC 9110 spec](https://www.rfc-editor.org/rfc/rfc9110.html) which means Senders may propose **different proto messages in the [content type](https://www.rfc-editor.org/rfc/rfc9110.html#name-content-type)** and different compressions in the [content-encoding](https://www.rfc-editor.org/rfc/rfc9110.html#name-content-encoding) depending on PRW specification versions that might add more messages and compressions in the future versions. Receivers obviously can respond with 200 if they support both encoding and type or 400 (for the compatibility for 1.x) or [415 "Unsupported Media Type"](https://www.rfc-editor.org/rfc/rfc9110.html#name-415-unsupported-media-type) if they don't.

PRW 2.0 keeps `snappy` compressions as the only one supported by the specification for now. However, since we have a new message there are 3 valid values of `Content-Type`:

* For the message introduced in PRW 1.0, identified by `prometheus.WriteRequest`:
  * `Content-Type: application/x-protobuf`
  * `Content-Type: application/x-protobuf;proto=prometheus.WriteRequest`
* For the message introduced in PRW 2.0, identified by `io.prometheus.write.v2.Request`:
  * `Content-Type: application/x-protobuf;proto=io.prometheus.write.v2.Request`

Rationales:
* This follows closely [RFC 9110 Content-Type](https://www.rfc-editor.org/rfc/rfc9110.html#name-content-type) semantics which allows optional "parameters" to media types (e.g. proto)
* This follows similar pattern we use to negotiate e.g. Prometheus protobuf scrape response format ([`application/vnd.google.protobuf;proto=io.prometheus.client.MetricFamily;encoding=delimited"`](https://github.com/prometheus/prometheus/blob/ea97c7072092789d22c1397e168b74b786eb74ca/config/config.go#L452C26-L452C117))
* It allows flexibility for future compressions and proto messages, e.g. [allowing 2.x to add more types and compression without breaking change](#dissociate-prw-specification-version-from-protobuf-message).

With this, Receiver can reuse a single endpoint for both proto messages. Senders can also implement support for both in a single binary. Switching to different messages can be done manually (e.g. user specifying in configuration) or by probing Receivers automatically. **Note that in PRW 2.0 we decided to explicitly NOT mandate, define or block any "automatic" content negotiation. This might come in 2.x or later.**

In Prometheus, we will start with the simplest approach, a configuration option in `RemoteWriteConfig` e.g. `ProtoMessage: prometheus.WriteRequest | io.prometheus.write.v2.Request` to specify which one to use manually (default `prometheus.WriteRequest`).

#### No Automatic Content Negotiation

Automatic content negotiation can in theory save some manual effort for Sender's users in upgrading or downgrading content type or encoding (compression) whenever Receiver upgrade/downgrade. It also gives *some* power to Receiver to upgrade type or encoding to some server-side preference.

However, after spending a few weeks on proposing various "automatic" content negotiation mechanism (see "*Other docs or links:*" in the beginning of this document) we decided to NOT add any automatic negotiation to PRW 2.0. TL;DR on why:

* The requirement was not strong enough. The priority of "no need for manual configuration" is fuzzy, given you likely touch this option only once or twice within a few years.
* Given gaps in PRW 1.0 specification around forward compatibility (undefined behaviour for changing `X-Prometheus-Remote-Write-Version` beyond 1.x and handling empty requests) no solution would guarantee full backward compatibility with PRW 1.0 receivers, so there would be manual configuration needed anyway.
* While we identified a standard [RFC 9110 "Request Content Negotiation"](https://www.rfc-editor.org/rfc/rfc9110.html#name-request-content-negotiation) semantics we could use, it's very fuzzy on details around:
  * Should sender or receiver make the final decision (both are possible).
  * What to probe (start) with. We considered HEAD request, empty 1.x, full 1.x type or full 2.0 type -- all of those have some trade-offs without clear winner e.g. starting with full 1.x can cause inconsistent data writes if upgraded later to 2.x, plus some overhead to all 2.x users.
  * Avoiding type/compression flipping (e.g. with Receiver using L7 load balancer and rolling changes).
* Unsure if we can split encoding and type into separate negotiation decision (as suggested by RFC 9110). Some potential requirements came from Mimir team to allow Receivers to NOT support certain compressions with certain content types.

At the end, given many unknowns and unclear best solution, we decided to start with the simplest content negotiation possible and listen to user feedback. We can always add automatic negotiation to 2.x or beyond.

See [the Final Decision Proposal](https://docs.google.com/document/d/1N4MQFmJjNoTuH7VhIiCny3jNkDyXnufBMYeggNZdITc/edit#heading=h.qlbskmrxl9km) for details.

### Dissociate PRW specification version from Protobuf message

One important consequence of the referencing compressions and protobuf types in content headers is that **it is possible for the next PRW spec versions to add more compressions and content types in the future, independently to spec version**. This means that in theory e.g. PRW 2.1 might add two more content types and 3 compressions, so the **protobuf message is no longer tied to major version of the protocol**.

Note that we don't plan anymore protobuf types for now, other than perhaps an experimental Apache Arrow based type within the next decade if it would be needed. We do plan adding more compressions if proven to be valuable.

### Backward Compatibility Guarantees and PRW 2.0 vs PRW 1.1

While we add a new content type and some flexibility for future compressions, both Senders and Receivers CAN implement PRW 2.0 in a backward compatible manner as defined [in the PRW 1.0](https://prometheus.io/docs/concepts/remote_write_spec/#backward-and-forward-compatibility):

```
The protocol follows semantic versioning 2.0: any 1.x compatible receivers MUST be able to read any 1.x compatible sender and so on. Breaking/backwards incompatible changes will result in a 2.x version of the spec.
```

This is because 1.x Receivers will be able to consume the messages from 2.0 Senders, as long as Sender supports 1.x proto message and choose to use it.

However, there are many features we cannot (or don't want to) port to 1.0 proto message (e.g. because it does not have string interning), so we DO want to allow Sender or Receiver implementations to intentionally block 1.x consumption or producing. For example, Google Cloud and other backends cannot work with 1.x protobuf messages due to various backend limitations.

For this reason we propose to call this spec change 2.0. Other reasons are clean cut off, discovery & marketing (many new features added, better performance, good practices).

### String Interning

String interning was the impetus for creating the new version of the protocol in first place. We always knew the 1.0 protobuf format was inefficient in terms of string duplication. If we imagine a Prometheus instance in a Kubernetes cluster scraping all the pods in every namespace, there are going to be a lot of duplicated label names and strings on the series that end up in Write Requests. For example; container, namespace, HTTP method or status codes, repeated metric names, etc. In the 1.0 format we would include the full string labelset for each series.

With the intial PoC version of the 2.0 format the goal was to reduce CPU compression time and reduce the overall amount of bytes that need to be sent over the wire by interning all strings for label names and values in a single symbol table per remote Write Request. The series in the Write Request then have integer references into the symbol table intead of duplicating the string data. While the snappy compression was we use was already fast, by interning the strings data prior to compression we significantly reduce the amount of time we need to spend on compression. And as an end result, we saw as much as 60% reduction in the network wire bytes. For a deeper dive see Callum's talk from Tokyo DevOpsDays [here](https://youtu.be/xJlZpCbT3To?list=PL-bvtmk0kdw5JSayDScD7Y6XMdyANyQmB&t=6388).

### Always-on Metadata

In the 1.0 format metadata was added at a later date than the original remote write implementation. In addition, Prometheus itself didn't have nice handling of metadata for persistence or series differentiation. Metadata was actually cached in memory on a per-metric name basis. That meant that if two targets exported the same metric name with different metadata, whichever was scraped most recently would have it's metadata cached. We also couldn't nicely gather metadata from the WAL until very recently like we do for all other data types, so metadata could only be sent *separately* from samples data on a periodic basis by checking the scrape subsystems cached metadata.

With the 2.0 format we're suggesting that metadata SHOULD always be included for every series in a remote write request, some reciever systems require metadata information like metric type for their storage to work optimally. This means that within the spec recievers would be allowed to reject data if metadata is not present. A TBD question is whether we should require metadata to be present on the senders side as well and just remove the chance of recievers not getting Metadata in the 2.0 format when they need it. One argument against doing so is that some metrics generating systems/libraries do not currently generate the same metadata that Prometheus client libraries do. We could just say this is part of being RW 2.0 compliant.

### Native Histograms

TBD

#### Custom Native Histograms

TBD)

#### Samples vs Native Histogram Samples

In the new 2.0 format we are saying that a write request MUST only contain float 64 samples or native histogram samples within a single time series. While the proto format currently allows for both to be present, mostly because the code to handle a proto `oneof` field is a bit unwieldly, part of being compliant would be that a sender never builds write requests that have both samples and histogram samples within the same time series.

The reason for this is as follows; while it technically possible for Prometheus to scrape both samples and histogram samples for the same metric name, these should result in separate time series in both TSDB and Remote Write. Whether via client library misuse or two separate versions of the same application (one of which has been updated to use native histograms while the other is still using classic histograms), a native histogram series will have different labels than a classic histogram which would have labels like `le`. TSDB would see these as different series, and generated different series reference IDs, which in turn would be picked up by remote write via separate WAL series records.

### Exemplars

Exemplars were already present in the 1.0 proto format, but in 2.0 we can take advantage of the symbols table and string interning to further reduce the amount of network bytes when exemplars are being generated. An exemplar consists of yet another label set that would contain more duplicated strings data. That's exacerbated by the fact that multiple series for classic histograms or counter vectors could all have exemplars on every scrape.

### Created Timestamp

TBD(bwplotka)

### Partial Writes

TBD(bwplotka)

## Other Alternatives

The section stating potential alternatives we considered, not mentioned in "How" section.

1. Deprecate remote write, double down on the OTLP protocol support in Prometheus

Not explored much, OTLP is designed to support multiple telemetry signal types while remote write is optimized to handle metrics data only.

1. Use gRPC for 2.0

TBD

1. Use Arrow format

TBD

1. Adding more compressions to PRW 2.0

TBD

* Investigate possible changes to compression/encoding used for Remote Write data to see if further network bandwidth improvements can be made without compromising CPU usage for either the sending or receiving server

1. Stateful protocol

## Action Plan

The follow-up implementation tasks we are working on already:

* [ ] Merge / change status to published in https://github.com/prometheus/docs/pull/2462
* [ ] [Remote Write 2.0 meta issue](https://github.com/prometheus/prometheus/issues/13105)
