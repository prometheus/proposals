## Remote-Write 2.0

* **Owners:**
  * Alex Greenbank [@alexgreenbank](https://github.com/alexgreenbank/) [alex.greenbank@grafana.com](mailto:alex.greenbank@grafana.com)
  * Bartłomiej (Bartek) Płotka [@bwplotka](https://github.com/bwplotka) [bwplotka@gmail.com](mailto:bwplotka@gmail.com)
  * Callum Styan [@cstyan](https://github.com/cstyan) [callumstyan@gmail.com](callumstyan@gmail.com)

* **Implementation Status:** `Partially implemented`

* **Related Issues and PRs:**
  * [Remote-Wrtie 2.0](https://github.com/prometheus/prometheus/issues/13105)

* **Other docs or links:**
  * [Existing Remote-Write 1.0 Specification](https://prometheus.io/docs/concepts/remote_write_spec/)
  * [Remote-Write 2.0 Draft Specification](https://docs.google.com/document/d/1PljkX3YLLT-4f7MqrLt7XCVPG3IsjRREzYrUzBxCPV0/edit#heading=h.3p42p5s8n0ui)
  * Content Negotiation Proposals
    * [Remote-Write 2.0 Content Negotiation Proposal (first attempt)](https://docs.google.com/document/d/1jx1fqpRnM0pAndeo3AgY7g6BLxN3Ah8R0Mm8RvNsHoU/edit)
    * [Remote-Write 2.0 Content Negotiation Proposal (second attempt)](https://docs.google.com/document/d/16ivhfAaaezNpB1OVs3p83-_ZZK-8uRgktqtcpYT2Sjc/edit)
    * [Final decision for Remote-Write 2.0 Content Negotiation](https://docs.google.com/document/d/1N4MQFmJjNoTuH7VhIiCny3jNkDyXnufBMYeggNZdITc/edit)
  * [Remote-Wrtie 2.0 Retries & Backoff Proposal](https://docs.google.com/document/d/1LjR0xm6Fw65vtFh8NjquaXyVRkw6d1vncOJ6he6o2QA/edit)
  * [Sample vs Histogram Sample semantics in one TimeSeries](https://docs.google.com/document/d/1fSu5OhytmZAMo5OwfWmaAFHL_tbUlFsS8S1N9M2Yt2Y/edit)
   

> TL;DR: We [propose a new version of the Prometheus Remote-Write (PRW) specification with a new wire format](https://github.com/prometheus/docs/pull/2462) that is more efficient, and includes important features such as always-on metadata, native histograms
> (including a new custom native histogram support), optional created timestamp and exemplars. This document explains rationales and Prometheus support of it.

## Glossary

* "PRW" stands here for Prometheus Remote-Write protocol (in spec we use full name).
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

The exact proposed PRW 2.0 specification can be found in https://github.com/prometheus/docs/pull/2462. Please see it there first. Feel free to give feedback around typos, wording choice and definitions there. 

This proposal, however, focuses on rationales and alternatives the team went through when designing PRW 2.0.

For detailed track of our work around the protocol see **Other docs or links** in the beginning of this document as well as:
* [Notes to public sync meeting](https://docs.google.com/document/d/1TYKB_XqVgkEZlxosQ9BM0XR8JFi0pctlNQ-gdu1wuRw/edit)
* Our CNCF slack channel `#prometheus-prw2-dev`

Below we go over major design decisions and changes over 1.0, with the rationales and context.

### A new protobuf message, identified by fully qualified name, old one deprecated

PRW 2.0 defines [a new protobuf message](https://github.com/prometheus/prometheus/blob/remote-write-2.0/prompb/io/prometheus/write/v2/types.proto#L32). As of PRW 2.0, Senders and Receivers will have to implement it to be compatible with the 2.0 spec. Following the new message, PRW 2.0 deprecates the [existing message defined in PRW 1.0](https://github.com/prometheus/prometheus/blob/remote-write-2.0/prompb/remote.proto). There is no value in keeping both around as the newer one is a direct replacement with more functionality. We want everybody to move to a new format and reduce maintenance effort, so we deprecate it.

Obviously, for compatibility reasons we want to give *option* for Senders to support 1.0 Receivers and Receivers to support 1.0 Sender. This is not mandatory, but recommended (SHOULD), because otherwise it would limit adaptability of PRW 2.0 (one reason for new message is to allow certain Receivers to finally support it e.g. Google Cloud). Prometheus will support both, for both receiving and sending.

Since PRW in general have two wire formats, PRW 2.0 defines a new way of identifying those by its **fully-qualified name** which consist of proto package and message name (as defined by [buf style guide](https://buf.build/docs/reference/protobuf-files-and-packages#packages). As a result, PRW Senders and Receivers:

* MUST support (new one) [`io.prometheus.write.v2.Request`](https://github.com/prometheus/prometheus/blob/remote-write-2.0/prompb/io/prometheus/write/v2/types.proto#L32). Note that we could use verbose `io.prometheus.remote.write.v2.WriteRequest`, but decided we will not have non-remote writes and there is no need for "Write" prefix for message, given then namespace.
* SHOULD, for compatibility, support [`prometheus.WriteRequest`](https://github.com/prometheus/prometheus/blob/remote-write-2.0/prompb/remote.proto). Note that we could change its fully qualified name to match the style guide, but we decided to not touch it for the best possible compatibility guarantee with the old senders/receivers.

The rationales for defining a new message, instead of reusing old one are:

* We decided to use [string interning mechanism](#string-interning) for all labels we transfer via PRW. This requires completely new fields for all labels. Adding this to the existing message would be not only confusing, but also highly inefficient as for backward compatibility senders would need to allocate and encode BOTH old labels (string copies) and new ones (symbol table and references). Note that labels are the most significant size contributors in PRW messages.
* We can remove the old reserved fields, we can reorder fields in proto for clarity.
* We can separate remote read proto messages from Remote-Write. They start to follow completely different versioning, content negotiation and protocol semantics, thus it makes sense to split proto definitions completely.

### No new compression added (yet)

The compression stays the same as in PRW 1.0. Snappy with block format.

Grafana team (Callum, Alex, Nico) performed extensive benchmarks (some links: [here](https://github.com/prometheus/prometheus/issues/13105#issuecomment-1802233936), [here](https://github.com/prometheus/prometheus/issues/13105#issuecomment-1833164085), [here](https://github.com/prometheus/prometheus/issues/13105#issuecomment-1851317914)) combining different compressions with different interning methods when we were designing [interning](#string-interning). Three lessons were clear:

* Interning makes sense -- simply compressing only give worse compression ratio (and is slower). 
* Interning does not replace compressing, but instead using both gives best the best compression ratio for generally minimal CPU/mem penalty.
* Other compressions yield better compression ratios ([up to 40% sometimes, notably `zstd` and `s2`](https://github.com/prometheus/prometheus/issues/13105#issuecomment-1833164085)), but the CPU and memory penalty (2-7% in some tests, but we have to repeat them) on receiving end could be considered harmful.

Especially the last item triggered some discussions in the community (some links: [here](https://docs.google.com/document/d/1PljkX3YLLT-4f7MqrLt7XCVPG3IsjRREzYrUzBxCPV0/edit?disco=AAAA3wKcml0), [here](https://twitter.com/pstbrn/status/1783220231114051969), [here](https://github.com/prometheus/prometheus/pull/13330)). The scepticism was shared e.g. by the Grafana Mimir Team, that adding receiving-side expensive compression as a must, will move the SaaS cost from one part (e.g. egress cost) to server side (SaaS compute), making it necessary to potentially change pricing etc. To challenge or evaluate this argument, more benchmarks has to be performed on final wire format which is planned for future.

The other argument for keeping Snappy as mandatory, is that it allows easy adaptability, since all implementations already have it for PRW 1.0.

Now, it's clear the compression ratio improvements are huge, so we will continue discussion to add s2 or zstd as *optional* compressions in PRW 2.1 or so. Read below section on how this will be negotiated.

### Basic content negotiation, built on what we have

PRW 2.0 builds on top of the existing PRW 1.0 content negotiation. The latter defined hardcoded `Content-Type: application/x-protobuf` and `Content-Encoding: snappy` headers. PRW 2.0 specifies that those headers must follow [the RFC 9110 spec](https://www.rfc-editor.org/rfc/rfc9110.html) which means Senders may propose **different proto messages in the [content type](https://www.rfc-editor.org/rfc/rfc9110.html#name-content-type)** and different compressions in the [content-encoding](https://www.rfc-editor.org/rfc/rfc9110.html#name-content-encoding). Receivers obviously can respond with 200 if they support both encoding and type. Otherwise, they have to respond with [415 "Unsupported Media Type"](https://www.rfc-editor.org/rfc/rfc9110.html#name-415-unsupported-media-type) (or 400 for the compatibility with 1.x), if they don't.

PRW 2.0 keeps `snappy` compressions as the only one supported by the specification for now. However, since we have a new message there are 3 valid values of `Content-Type`:

* For the message introduced in PRW 1.0, identified by `prometheus.WriteRequest`:
  * `Content-Type: application/x-protobuf`
  * `Content-Type: application/x-protobuf;proto=prometheus.WriteRequest`
* For the message introduced in PRW 2.0, identified by `io.prometheus.write.v2.Request`:
  * `Content-Type: application/x-protobuf;proto=io.prometheus.write.v2.Request`

Rationales:

* This follows closely [RFC 9110 Content-Type](https://www.rfc-editor.org/rfc/rfc9110.html#name-content-type) semantics which allows optional "parameters" to media types (e.g. proto)
* This follows similar pattern we use to negotiate e.g. Prometheus protobuf scrape response format ([`application/vnd.google.protobuf;proto=io.prometheus.client.MetricFamily;encoding=delimited"`](https://github.com/prometheus/prometheus/blob/ea97c7072092789d22c1397e168b74b786eb74ca/config/config.go#L452C26-L452C117))
* It allows flexibility for future compressions and proto messages, e.g. allowing 2.x to add more types and compression, optionally, without breaking change. Mandatory changes will need major version spec.

With this, Receiver can reuse a single endpoint for both proto messages. Senders can also implement support for both in a single binary. Switching to different messages can be done manually (e.g. user specifying in configuration) or by [probing Receivers automatically](#no-automatic-content-negotiation).

In Prometheus, we will start with the simplest approach, a configuration option in `RemoteWriteConfig` e.g. `ProtoMessage: prometheus.WriteRequest | io.prometheus.write.v2.Request` to specify which one to use manually (default `prometheus.WriteRequest`).

#### No Automatic Content Negotiation

Automatic content negotiation can in theory save some manual effort for Sender's users in upgrading or downgrading content type or encoding (compression) whenever Receiver upgrade/downgrade. It also gives *some* power to Receiver to upgrade type or encoding to some server-side preference.

However, after spending a few weeks on researching various "automatic" content negotiation mechanism (see [(first attempt)](https://docs.google.com/document/d/1jx1fqpRnM0pAndeo3AgY7g6BLxN3Ah8R0Mm8RvNsHoU/edit), [(second attempt)](https://docs.google.com/document/d/16ivhfAaaezNpB1OVs3p83-_ZZK-8uRgktqtcpYT2Sjc/edit) and [final decision](https://docs.google.com/document/d/1N4MQFmJjNoTuH7VhIiCny3jNkDyXnufBMYeggNZdITc/edit)) we decided to NOT add any automatic negotiation to PRW 2.0.

Rationales:

* The requirement was not strong enough. The priority of "no need for manual configuration" is fuzzy, given user likely touch this option only once or twice within a few years.
* Given gaps in PRW 1.0 specification around forward compatibility (undefined behaviour for changing `X-Prometheus-Remote-Write-Version` beyond 1.x and handling empty requests) no solution would guarantee full backward compatibility with PRW 1.0 receivers, so there would be manual configuration needed anyway.
* While we identified a standard [RFC 9110 "Request Content Negotiation"](https://www.rfc-editor.org/rfc/rfc9110.html#name-request-content-negotiation) semantics we could use, it's very fuzzy on details around:
  * Should sender or receiver make the final decision (both are possible).
  * What to probe (start) with. We considered HEAD request, empty 1.x, full 1.x type or full 2.0 type -- all of those have some trade-offs without clear winner e.g. starting with full 1.x can cause inconsistent data writes if upgraded later to 2.x, plus some overhead to all 2.x users.
  * Avoiding type/compression flipping (e.g. with Receiver using L7 load balancer and rolling changes).
* Unsure if we can split encoding and type into separate negotiation decision (as suggested by RFC 9110). Some potential requirements came from Mimir team to allow Receivers to NOT support certain compressions with certain content types.

At the end, given many unknowns and unclear best solution, we decided to start with the simplest content negotiation possible and listen to user feedback. PRW 2.0 explicitly NOT mandate, define or block any "automatic" content negotiation. We can always add automatic negotiation to 2.x or beyond.

See [the Final Decision Proposal](https://docs.google.com/document/d/1N4MQFmJjNoTuH7VhIiCny3jNkDyXnufBMYeggNZdITc/edit#heading=h.qlbskmrxl9km) for details.

### Why PRW 2.0 vs PRW 1.1

While we add a new content type and some flexibility for future compressions, both Senders and Receivers CAN implement PRW 2.0 in a backward compatible manner as defined [in the PRW 1.0](https://prometheus.io/docs/concepts/remote_write_spec/#backward-and-forward-compatibility):

```
The protocol follows semantic versioning 2.0: any 1.x compatible receivers MUST be able to read any 1.x compatible sender and so on. Breaking/backwards incompatible changes will result in a 2.x version of the spec.
```

This is because 1.x Receivers will be able to consume the messages from 2.0 Senders, as long as Sender supports 1.x proto message and choose to use it.

However, there are many features we cannot (or don't want to) port to 1.0 proto message (e.g. because it does not have string interning), so we DO want to allow Sender or Receiver implementations to intentionally block 1.x consumption or producing.

For this reason we propose to call this spec change 2.0. Other reasons are clean cut off, discovery & marketing (many new features added, better performance, good practices).

### Partial Writes

PRW 2.0 generally reuses the PRW 1.0 Receiver response semantics like [the retry](https://prometheus.io/docs/concepts/remote_write_spec/#retries-backoff) and [invalid sample](https://prometheus.io/docs/concepts/remote_write_spec/#retries-backoff:~:text=Receivers%20MUST%20return%20a%20HTTP%20400%20status%20code%20(%22Bad%20Request%22)%20for%20write%20requests%20that%20contain%20any%20invalid%20samples). This time we put in the separate explicit section.

PRW 2.0 also is explicit on partial writes and partial retry-able writes. Especially the former was bit fuzzy, so we made this clear that partial writes CAN happen, but should result with error status code (and message). This is opposite to [what OTLP is specifying](https://opentelemetry.io/docs/specs/otlp/#partial-success-1), and we didn't dive on why. The PRW 1.0 was specifying returning error, which allows Sender to print error from non-restricted response message structure, so we kept that.

One idea came from the Grafana Agent/Alloy maintainer, Robert, [to standardize and structure response like OTLP has e.g. response proto message with exact numbers per category of errors for each sample write error](https://github.com/prometheus/docs/pull/2462#discussion_r1598807798). We decided to skip this for PRW 2.0, given:

* Non-trivial work to define those categories, agree-ing on those across Receivers.
* A bit unclear benefit on how Senders can utilize (programmatically) this information. Why is printing not enough? Those metrics could be retrieved from Receiver?
* Harder to adopt PRW 2.0 if we make it mandatory.

We propose to continue experimentation and experiment with such feature organically like we did with PRW 1.0 + new features. Implement it in Prometheus (can be done with PRW 2.0) and add PRW 2.1 or so when the idea is clearly useful.

In the meantime we more explicitly mentioned that the Receiver's error SHOULD contain information about the amount of the samples being rejected and for what reasons.

### String Interning

String interning was the impetus for creating the new version of the protocol in first place. We always knew the PRW 1.0 message format was inefficient in terms of string duplication. If we imagine a Prometheus instance in a Kubernetes cluster scraping all the pods in every namespace, there are going to be a lot of duplicated label names and strings on the series that end up in Write Requests. For example; container, namespace, HTTP method or status codes, repeated metric names, etc. The PRW 1.0 format includes the full string labelset for each series.

With the initial PoC version of the PRW 2.0 message format the goal was to reduce CPU compression time and reduce the overall amount of bytes that need to be sent over the wire. We tried interning all strings for label names and values in a single symbol table per Remote-Write Request. The series in the message then have integer references into the symbol table instead of duplicating the string data. While the snappy compression we use was already fast, by interning the strings data prior to compression we significantly reduce the amount of time we need to spend on compression. And as an end result, we saw as much as 60% reduction in the network wire bytes. 

For a deeper dive see Callum's talk from Tokyo DevOpsDays [here](https://youtu.be/xJlZpCbT3To?list=PL-bvtmk0kdw5JSayDScD7Y6XMdyANyQmB&t=6388). For some benchmarks, see [this issue](https://github.com/prometheus/prometheus/issues/13105#issuecomment-1806593500).

For symbols table, there is a potential to one day, pre=define certain integers for common labels. We keep it open for future (currently it's Sender decision), except the empty string, which has to be referred to 0 in symbols table. This means that ALL messages in PRW 2.0 new message format has to have symbol table with the first element being `""`, even if the message never specify empty string. This is required to be able to maintain behaviour of optional/required string fields which are NOT specified. For those which changed to symbols (e.g. unit_ref and help_ref in metadata) it might be common for e.g. unit to be NOT specified (e.g. even accidentally by Sender). Given the [Proto 3 default  semantics](https://protobuf.dev/programming-guides/proto3/#default), for example for not specified `unit_ref` field, the value will be zero, which will cleanly work with any Receiver 2.x implementation, as such value will be always present in symbols table.

### Always-on Metadata

Metadata is a core feature of Prometheus nowadays. It's useful for auto-completion and metric discovery features. In Remote Write context, some Receiver systems, even require metadata information like metric type for their storage to work optimally (e.g. Google Cloud with strongly typed metrics).

PRW 1.0 officially never supported metadata, mainly because of opposite ideas and metadata implementation being added after 1.0 spec was adopted. In-officially, Prometheus and certain Receivers, were [supporting experimental metadata field with stateful semantics](https://github.com/prometheus/prometheus/blob/42b546a43d9984d820a81723abe41013ca98f2ec/prompb/remote.proto#L27). This was great as we were able to organically experiment with some ideas.

The previous way of metadata handling for Remote-Write was built for the very initial Prometheus metadata handling. Prometheus didn't have metadata persistence or series differentiation. Metadata was actually cached in memory on a per-metric name basis. That meant that if two targets exported the same metric name with different metadata, whichever was scraped most recently would have its metadata cached. We also couldn't nicely gather metadata from the WAL until very recently like we do for all other data types, so metadata could only be sent *separately* from samples data on a periodic basis by checking the scrape subsystems cached metadata. This, in theory, allowed some efficiency gains, but was very complex to scale by Receivers, given stateful guarantees.

In the PRW 2.0 proto message we're decided that metadata SHOULD be always be included for every series in a Remote-Write request. This is reflected with the required Metadata field that has optional fields (type can be unspecified, help and unit empty). Receivers CAN respond with Invalid Sample if metadata is not set (e.g. type).

Given the above, it's tempting to make Metadata fields, or at least type a MUST. One argument against doing so is that some metrics generating systems/libraries do not currently generate the same metadata that Prometheus client libraries do, so there is nothing Sender can do. While in Prometheus we will commit to sending Metadata always, if we can, there might be edge cases of this data not being present. As a result, we keep it as SHOULD, with the Receiver option to reject those samples (partial write applies).

Metadata being part of every series, in the past, triggered some opposition, given duplicated data (e.g. large help string, the same across potentially a hundred samples) sent. For this reason both help and unit strings are fully symbolizing, mitigating the efficiency argument.

### Labels and UTF-8

PRW 1.0 message, as a part of spec, [was mandating a certain format for metric names, and label names](https://prometheus.io/docs/concepts/remote_write_spec/#labels:~:text=Senders%20MUST%20only%20send%20valid%20metric%20names%2C%20label%20names%2C%20and%20label%20values%3A). Recently [UTF-8](https://github.com/prometheus/proposals/blob/main/proposals/2023-08-21-utf8.md) proposal was approved, suggesting PRW 2.0 should allow any UTF-8 in names. Otherwise, sending UTF-8 series would need to be escaped for PRW transport, which technically:

* Senders have to do to support PRW 1.0 anyway (if they do).
* Adds overhead for Receivers supporting UTF-8.
* Requires to be versioned spec for escaping. We have proposed escaping [here](https://github.com/prometheus/proposals/blob/main/proposals/2023-08-21-utf8.md#text-escaping) and colliding escaping mechanism for OpenTelemetry sourced metrics.

After big discussion on [Slack](https://cloud-native.slack.com/archives/C01AUBA4PFE/p1716394693414599) and [DevSummit](https://docs.google.com/document/d/11LC3wJcVk00l8w5P3oLQ-m3Y37iom6INAMEu2ZAGIIE/edit#bookmark=id.2w42mtfjwuty), no census were made, with more [discussions](https://groups.google.com/g/prometheus-developers/c/ftnfizjXOmk) that followed.

To move forward with PRW 2.0 we identified three options:

* Option A:

  Names MUST be valid with PRW 1.0 regex. Add recommended escaping or content negotiation in future 2.x e.g:
  * `Content-Type: application/x-protobuf;proto=io.prometheus.write.v2.Request;charset=UTF-8`
  * `Content-Type: application/x-protobuf;proto=io.prometheus.write.v2.Request;charset=dots`

  Cons:
  * Doable, but content negotiation is a forever baggage we want to avoid. The charset/feature list can explode easily.
  * We have opportunity in PRW 2.0 to mention that UTF-8 is likely more common (or at least dots) and avoid this tech debt.

* Option B:

  Names CAN be any char from UTF-8; Receiver MUST support it to be compliant, recommend Escaping.

  Cons:
  * Community is still unsure of the current UTF-8 support, but likely it will stay.
  * Seems like community don't want to define one escaping (?)
  * Limits adoption, impossible to support right now even by Prometheus itself.

* Option C

  Names CAN be any char from UTF-8; Receiver can explicitly reject if they choose so.
  
  Cons:
  * Kind of mess, no one knows what to expect or do. 

* Option D:

  Names CAN be any char from UTF-8; SHOULD follow old format, with clear explanation why. 
  Intentionally, not mentioned explicitly if Receiver can reject UTF-8, but implicitly it should not.

We decided to pursue the option D. The most clear, open and future-proof. Sounds like no matter what, Senders will have to add some new, UTF-8 characters to names with escaping or not. The escaping scheme is not clear yet, and PRW should not define this (too much complexity). This is, kind of, on par with the OTLP being more open than SDKs or semantic convention. 

### Native Histograms

Similar to the above, [PRW 1.0 had experimental support for native histograms](https://github.com/prometheus/prometheus/blob/42b546a43d9984d820a81723abe41013ca98f2ec/prompb/types.proto#L129). PRW 2.0 adds it officially, in the same manner.

PRW 2.0 uses the same timestamp and stale marker semantics for "float" sample and histogram sample.

#### Custom Native Histograms

One notable change is that new native histogram proto now supports [custom bucketing too](https://github.com/prometheus/proposals/blob/main/proposals/2024-01-26_classic-histograms-stored-as-native-histograms.md), which allows storing classic histograms in native histogram structured value.

This has a huge benefit of essentially making [all histograms transactional](https://docs.google.com/document/d/1mpcSWH1B82q-BtJza-eJ8xMLlKt6EJ9oFGH325vtY1Q/edit?pli=1#heading=h.ueg7q07wymku), which was a big PRW 1.0 complain blocking an adoption. Having transactional histograms enables further Receiver scalability, without Sender complexity, as there is no risk buckets for the same histogram will come in different write requests.

For transactional reasons, Receivers MAY return Invalid Sample error on e.g. classic histograms. Prometheus will also have a feature soon to convert all scraped classic histogram to native histograms and potentially one day -- deprecating classic histograms.

#### Samples vs Native Histogram Samples

In the new 2.0 format we are saying that a write request MUST only contain float 64 samples or native histogram samples within a single time series. While the proto format currently allows for both to be present, mostly because the code to handle a proto `oneof` field is a bit unwieldly, part of being compliant would be that a sender never builds write requests that have both samples and histogram samples within the same time series.

The reason for this is as follows; while it technically possible for Prometheus to scrape both samples and histogram samples for the same metric name, these should result in separate time series in both TSDB and Remote-Write. Whether via client library misuse or two separate versions of the same application (one of which has been updated to use native histograms while the other is still using classic histograms), a native histogram series will have different labels than a classic histogram which would have labels like `le`. TSDB would see these as different series, and generated different series reference IDs, which in turn would be picked up by Remote-Write via separate WAL series records.

### Exemplars

Similar to native histograms, [PRW 1.0 had experimental support for exemplars](https://github.com/prometheus/prometheus/blob/42b546a43d9984d820a81723abe41013ca98f2ec/prompb/types.proto#L128). PRW 2.0 adds it officially, in the same manner.
 
One element that PRW 2.0 changes is that exemplars now take advantage of the symbols table and string interning to further reduce the amount of network bytes when exemplars are being generated. An exemplar consists of yet another label set that would contain more duplicated strings data. That's exacerbated by the fact that multiple series for classic histograms or counter vectors could all have exemplars on every scrape. As a result labels are symbolized.

Finally, we allow labels to be skipped (due to [this](https://github.com/prometheus/prometheus/issues/14208)) and for traces we say the label name SHOULD be `trace_id`.

### Created Timestamp

Created Timestamps were introduced to Prometheus in 2023 (see the [talk](https://www.youtube.com/watch?v=nWf0BfQ5EEA)). This information can improve the accuracy of query results for series that follow counter semantics. Some receivers require this information e.g. Google Cloud.

Created timestamp now should be associated with a series in the new proto message (optionally). Note that Prometheus has created timestamp in a form of "temporary" short term feature [`created-timestamp-zero-ingestion`](https://prometheus.io/docs/prometheus/latest/feature_flags/#created-timestamps-zero-injection), which works well for local querying, but is poor for remote storage. Essentially, this is not enough to set this field properly for PRW 2.0 (which is fine as it's optional). Longer term [we plan](https://github.com/prometheus/prometheus/issues/14217) to use per series metadata storage for created timestamp which will allow this field to be set by Prometheus.

One alternative is to remove this field and simply mention this information to be passed via "zero injection" method we have in Prometheus. This is not great, as it makes the process of distilling that information back by Receiver stateful, so not really scalable or feasible.

### Being Pull vs Push Agnostic

PRW 1.0 mentions that the protocol was being designed for pull based metrics (aka scrapes). In fact, language used and [the stale marker semantics (MUST)](https://prometheus.io/docs/concepts/remote_write_spec/#stale-markers) sound like metrics from any other collection pattern (e.g. OpenTelemetry Collector with metrics that were pushed) are not allowed e.g.

[> The remote write protocol is not intended for use by applications to push metrics to Prometheus remote-write-compatible receivers. It is intended that a Prometheus remote-write-compatible sender scrapes instrumented applications or exporters and sends remote write messages to a server.](https://prometheus.io/docs/concepts/remote_write_spec/#labels:~:text=The%20remote%20write%20protocol%20is%20not%20intended%20for%20use%20by%20applications%20to%20push%20metrics%20to%20Prometheus%20remote%2Dwrite%2Dcompatible%20receivers.%20It%20is%20intended%20that%20a%20Prometheus%20remote%2Dwrite%2Dcompatible%20sender%20scrapes%20instrumented%20applications%20or%20exporters%20and%20sends%20remote%20write%20messages%20to%20a%20server.)

It's true that PRW 1.0 was designed for pull-based metrics (Prometheus scrape style). At the time ecosystem was moving away from push based metrics, and Prometheus [strongly advocated for pull](https://prometheus.io/blog/2016/07/23/pull-does-not-scale-or-does-it/). However, in practice this only had one real consequence--stale markers were MUST, and 
we have a compliance [test](https://github.com/prometheus/compliance/blob/12cbdf92abf7737531871ab7620a2de965fc5382/remote_write_sender/cases/staleness.go#L16) for it.

Fast-forward to 2024 and Prometheus community stil recommends the pull model. However, the OpenTelemetry project was created and has now stable components that are push based centric. Open Telemetry collector also now supports PRW 1.0, with [the stale markers if scrape logic was used for those series](https://github.com/open-telemetry/opentelemetry-collector/pull/3423). Ecosystem also created interesting metric sources e.g. from Grafana Cloud like Tempo, k6 that can generate metrics from other type of data (traces and benchmarks) and send using PRW 1.0 to the backend. Is such a software "sender that scrapes instrumented applications"? Likely not. Does it mean this is a bad use of PRW? We would argue the opposite and adoption proved it.

Given above, we decided to:

* Remove mention of [the intention](https://prometheus.io/docs/concepts/remote_write_spec/#labels:~:text=The%20remote%20write%20protocol%20is%20not%20intended%20for%20use%20by%20applications%20to%20push%20metrics%20to%20Prometheus%20remote%2Dwrite%2Dcompatible%20receivers.%20It%20is%20intended%20that%20a%20Prometheus%20remote%2Dwrite%2Dcompatible%20sender%20scrapes%20instrumented%20applications%20or%20exporters%20and%20sends%20remote%20write%20messages%20to%20a%20server). It does not change anything and presented fuzzy message and what PRW can be used for.
* Made stale markers SHOULD generally, but MUST `if the discontinuation of time series is possible to detect` with 2 clear examples.
 
Rationales:

* This feels more clear on the intentions here, while keeping the useful staleness feature for everyone, and MUST for when it's trivial to add them (e.g. scrape, evaluations).
* Keeping stale markers MUST always, would technically mean that push based metrics cannot be sent, because it's impossible for sender to tell "when time series will be no longer appended" other than naive solutions like "auto-expire". In fact even Prometheus sender can violate that in error cases (crashes) and when target uses timestamps and `track_timestamps_staleness` option is disabled.
* "auto-expire" solution has to be implemented on Receiver side anyway, because there is no way to validate if staleness will be sent, plus there are valid cases of NOT emitting staleness markers (e.g. see above for Prometheus). In Prometheus ecosystem, that is a "lookback-delta" PromQL parameter that ideally is of 3x scrape interval or so.

Other alternatives considered:

* Do `Sender MUST send stale markers when a time series will no longer be appended to, for time series that were "scraped".`, but that's also not entirely true e.g. stale markers are useful for e.g. rule/alert evaluations too, so they kind of are MUST/SHOULD if you CAN track end of time series in any means. 
* Move to `SHOULD` for all cases is also sad, because it's trivial to do stale markers for scrapes in general and many other metric source mechanisms e.g. evaluations, when you control what you monitor (e.g. benchmarks, exporters who choose to PRW directly to Receiver).

## Other Alternatives

The section stating potential alternatives we considered, not mentioned in "How" section.

1. Deprecate Remote-Write, double down on the OTLP protocol support in Prometheus

(Copying what we shared in spec FAQ itself:)
> [OpenTelemetry OTLP](https://github.com/open-telemetry/opentelemetry-proto/blob/a05597bff803d3d9405fcdd1e1fb1f42bed4eb7a/docs/specification.md) is a protocol for transporting of telemetry data (such as metrics, logs, traces and profiles) between telemetry sources, intermediate nodes and telemetry backends. The recommended transport involves gRPC with protobuf, but HTTP with protobuf or JSON are also described. It was designed from scratch with the intent to support variety of different observability signals, data types and extra information. For [metrics](https://github.com/open-telemetry/opentelemetry-proto/blob/main/opentelemetry/proto/metrics/v1/metrics.proto) that means additional non-identifying labels, flags, temporal aggregations types, resource or scoped metrics, schema URLs and more. OTLP also requires [the semantic convention](https://opentelemetry.io/docs/concepts/semantic-conventions/) to be used.
> 
> Remote-Write was designed for simplicity, efficiency and organic growth. First version was officially released in 2023, when already [dozens of battle-tested adopters in the CNCF ecosystem](https://prometheus.io/docs/concepts/remote_write_spec/#compatible-senders-and-receivers) were using it for years. Remote-Write 2.0 iterates on the previous protocol by adding a few new elements (metadata, exemplars, created timestamp and native histograms) and string interning. Remote-Write 2.0 is always stateless, focuses only on metrics and is opinionated -- it is scoped down to elements that by Prometheus community, is all you need to have robust metric solution. We believe Remote-Write 2.0 proposes an export transport, for metrics, that is a magnitude simpler to adopt and use, and often more efficient than competitors.
 
Generally, there is a lot of frictions to adopt OTLP given complexity, so we want to provide simpler to use and adopt, organically grown and more efficient alternative.

1. Use gRPC for 2.0

Would increase friction to adopt and give little benefit. We could consider adding this in 2.x if someone would give us some clear data on benefits of doing this.

1. Use Arrow format

This is complex beast to tackle, but seems the benefits are clear. It would definitely increase friction of adoption, so it has to be done as an optional Proto Message and thanks for PRW 2.0 changes, this can be done in 2.x or so!

1. Stateful protocol

Interning allows us to avoid stateful protocol which can hinder adoption. Stateful protocols are harder to use, mainly because it's not trivial to scale them on both client and receiver sides for certain use cases (you need to maintain some state e.g. TCP stickiness). Again, PRW 2.x could add optional format for that if benefits are clear.

## Action Plan

The follow-up implementation tasks we are working on already:

* [ ] Merge / change status to published in https://github.com/prometheus/docs/pull/2462
* [ ] [Remote-Write 2.0 meta issue](https://github.com/prometheus/prometheus/issues/13105)
