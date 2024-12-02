## Recommendations for WAL Format Changes

* **Owners:**
  * [@bwplotka](https://github.com/bwplotka)

* **Contributors:**
  * [@krajorama](https://github.com/krajorama)
  * [@bboreham](https://github.com/bboreham)

* **Implementation Status:** Not implemented

* **Related Issues and PRs:**
  * https://github.com/prometheus/prometheus/issues/15200
  * https://github.com/prometheus/prometheus/issues/14730
  * [WAL changes for NHCB](https://docs.google.com/document/d/1oYmvK7rrRFNrkM4Hrze8OsaK4z0GGj4pXl6VT6S_ef0/edit?tab=t.0#heading=h.545ogb8wlxze)

* **Other docs or links:**
  * [`#prometheus-wal-dev`](https://cloud-native.slack.com/archives/C082ALTBY4S)
  * https://github.com/prometheus/prometheus/blob/main/tsdb/docs/format/wal.md
  * [Ganesh's blog](https://ganeshvernekar.com/blog/prometheus-tsdb-the-head-block/)

> TL;DR: We need to break forward compatibility of the WAL format. This proposal explores various data migration strategies for WAL and ways we can be more transparent about those in each Prometheus release.

## Glossary

For this document, I use the following compatibility wording, related to Prometheus compatibility towards the WAL format.

* **Backward Compatibility**: When new Prometheus can read old WAL format.
* **Forward Compatibility**: When old Prometheus can read the new WAL format, it is required for potential reverts.

In this document "compatibility" means not only a no crash, but 100% lossless e.g. reads between Prometheus and WAL versions.

## Why

Recently we discussed various improvements to Prometheus Write-Ahead-Log (WAL, also used in WBL) to:

* Support new features (created timestamp (CT), native histograms with custom buckets (nhcb)).
* Efficiency improvements and tech debt cleanup (parallelization/sharding, combining records, different decoding formats).

The current (https://github.com/prometheus/prometheus/blob/975d5d7357a220192fe1307b10ded9b35130ab1c/tsdb/docs/format/wal.md) WAL data is a handwritten variadic-encoding binary format. It's generally not versioned, and it does not support unknown fields or data except 3 specific places:

* [record type](https://github.com/prometheus/prometheus/blob/e410a215fbe89b67f0e8edef9de25ede503ea4e0/tsdb/record/record.go#L38)
* [metric type in metadata record](https://github.com/prometheus/prometheus/blob/e410a215fbe89b67f0e8edef9de25ede503ea4e0/tsdb/record/record.go#L111)
* [metadata fields are arbitrary labels in metadata record](https://github.com/prometheus/prometheus/blob/e410a215fbe89b67f0e8edef9de25ede503ea4e0/tsdb/record/record.go#L608).

Historically we didn't hit major problems because we were only adding new semantic data (e.g. exemplars, metadata, new native histograms) as new records. At this point, however, we need to add features to existing data (e.g. custom buckets that will replace classic histograms, or created timestamps to samples). Even if we create a new record for those and use it for new samples, any rollback will **lose that information as they appear unknown in the old version**.

For TSDB changes (see the [context](#context--tsdb-format-changes)), we use ["2-fold" migration strategy](#two-fold-migration-strategy). However, WAL data is typically significantly smaller, around ~30m worth of samples (time to gather 120 samples for a chunk, for 15s intervals), plus 2h series records in WAL.

### Pitfalls of the current solution

* We don't have an officially documented migration strategy for WAL and TSDB in general (only tribal knowledge).
* Users don't know if version X of Prometheus works with version X-2 (except on some minor release that makes the change).
* No e2e testing for migration strategies, no consistent documentation when this happens on releases.

As a result:

* Reduced contribution and development velocity, prolonging bugs, important features and efficiency efforts.
* Increased operational cost and reduced trust for users who run highly durable Prometheus setups.

### Context: TSDB format changes

TSDB format, including chunk format (also used in the head with mmapped chunks), is also a handwritten variadic-encoding binary format. Compared to WAL it's generally versioned e.g.

* [Chunk disk file format](https://github.com/prometheus/prometheus/blob/12c39d5421cc29a4bfc13fc57fd9ccd3dbc310f0/tsdb/docs/format/chunks.md#L14).
* [Head chunk disk format](https://github.com/prometheus/prometheus/blob/fd62dbc2918deea0ceae94758baf7a095b52dd5b/tsdb/docs/format/head_chunks.md#L13).
* [Index file](https://github.com/prometheus/prometheus/blob/d699dc3c7706944aafa56682ede765398f925ef0/tsdb/docs/format/index.md#L8).
* [Block meta file](https://github.com/prometheus/prometheus/blob/5e124cf4f2b9467e4ae1c679840005e727efd599/tsdb/block.go#L171).
* Chunks have its own ["encoding type"](https://github.com/prometheus/prometheus/blob/a693dd19f244f000da40bcbac85041846b78cfc1/tsdb/chunkenc/chunk.go#L29) that could be used for versioning.

No docs or formal strategy was developed, but Prometheus generally follow the ["2-fold" migration strategy explained below](#two-fold-migration-strategy).

## Goals

* Agree on the official recommendations for **lossless WAL migrations** strategies for devs and users.
* Balancing development velocity with user data stability risks.

## Non-Goals

* TSDB format can but does not need to follow the same recommendations. We want to change the WAL format now, so prioritizing WAL.
* Mentioning Write-Before-Log, it uses WAL format so all apply to WBL too.
* To reduce scope we don't mention [memory snapshot format](https://github.com/prometheus/prometheus/blob/fd5ea4e0b590d57df1e2ef41d027f2a4f640a46c/tsdb/docs/format/memory_snapshot.md#L1) for now.

## How

We recommend the [Two-Fold Migration Strategy](#two-fold-migration-strategy) with two details:

* A new flag that tells Prometheus what WAL version to write.
* There can be multiple "forward compatible" version, but the official minimum is one (see, the rejected [LTS idea](#require-lts-support))

We propose to add a string `--storage.tsdb.stateful.write-wal-version` flag, with the default to `v1` that has a "stateful" consequence -- once new version is used, users will be able to revert only to certain Prometheus versions. Help of this flag will explain clearly what's possible and what Prometheus version you will be able to revert to.
 
In other words, we propose to add a TSDB flag `--storage.tsdb.stateful.write-wal-version=<version>` that tells Prometheus to use a particular WAL format for both WAL and WBL. This kind of flag will change its default to a new version ONLY when (at least) one previous Prometheus version can read that version (while writing the old one). The initial version would be `v1`.

There are two reasons for this flag:

* Allows users to get the new features sooner and skip the safety mechanism.
* It simplifies the process as the flag default mechanism guides users and devs in the rollout and revert procedures e.g:
  * when we switch to writing v2, it's clearly visible in a flag default value. 
  * when we at some point remove support of WAL v1, it's clear when it happens (v1 flag value is removed).
* It allows users to set new version to write old format if needed (de-risking further).
* Gives devs quicker feedback, makes testing easier, and motivates further contributions.

We propose to document that behaviour in:

* dedicated guide for users
* flag help
* tsdb/docs for devs

To achieve WAL versioning we also propose to start versioning the WAL, as [a whole format](https://github.com/prometheus/prometheus/blob/main/tsdb/docs/format/wal.md). This is necessary to communicate a breaking change and to tell Prometheus what WAL format to write in.

We propose the addition of a `meta.json` file in the wal directory, similar to [block meta.json](https://github.com/prometheus/prometheus/blob/5e124cf4f2b9467e4ae1c679840005e727efd599/tsdb/block.go#L171), with Version field set to `1` for the current format and `2` for new changes e.g. when we start to write [new records](https://github.com/prometheus/prometheus/pull/15467/files). No `meta.json` is equivalent to `{"version":1} `meta.json` file.

We propose to also store the new WALs in separate directories e.g. `wal.v2`. Thanks to that the rewrite from one version to another is eventual and can be done segment by segment.
The additional advantage of this way of versioning is that it's clear when your WAL fully migrated to a certain version.

Finally, we propose that all Prometheus releases will contain the following table:

| Data        | Supported | Writes |
|-------------|-----------|--------|
| WAL         | v1, v2    | v1     |
| Block index | v2        | v2     |

```
The last revertable Prometheus version: v3.0 
```

See [alternatives](#alternatives) for other ideas.

### Two-Fold Migration Strategy

Given the following example:

![twofold.png](../assets/2024-11-25_changing_wal_format/twofold.png)

1. We release Prometheus X+1 version that supports both Y and Y+1 data but still writes Y.
2. We release Prometheus X+2 version that supports both Y and Y+1 data, but now it writes new data as Y.

While this example shows only one version where of forward compatibility (when Y and Y+1 are supported, but Y is still written), in practice there could be more "forward compatible releases" within this strategy.

Pros:
* Users have a durable rollout path back and forth.
* Dev has clarity on how to develop "breaking revert" changes.
* In theory, it allows revert to X from X+2, by going through X+1 and ensuring all data was migrated (eventually) to Y version. In practice however that eventuality is long, or hard to discover.

Cons:
* It can catch users by surprise
  * **Mitigation**: We also plan guide and documentation.
* It takes time to rollout new changes if you want them fast.
  * **Mitigation**: We plan to add a flag to opt-in sooner
* It is a breaking change which shouldn't be made in a major release.
* **Mitigation**: We accept that fact, given precedence and no other way to support both formats in the same time without major performance penalties.

## Alternatives

### Require LTS support

We could add a variation to the [Two-Fold Migration Strategy](#two-fold-migration-strategy) (let's call it a "LTS migration strategy") where both X+1 and the last LTS (long time support version) before X+1, is able to read Y+1 version. Only then we are allowed to release X+2 that switches the default.

For example:

1. LTS 3.1 only supports WAL v1.
2. 3.3 adds WAL v2.
3. we wait unit next LTS so e.g. 3.24.
4. 3.25 can now switch to WAL v2.
5. 4.0 can remove WAL v1 support.

Pros:
* Gives a bit more stability to users and less surprises.

Cons:
* Extremely heavy process that will make us afraid/refuse to make improvements to WAL, because it's too much work. It might fails our goal of `Balancing development velocity with user data stability risks`
  * One mitigation would be an LTS retroactive strategy e.g. LTS 3.1 only supports WALv1, 3.3 adds WALv2, we do 3.1.1 with WALv2 too, 3.4 can now switch to WALv2, 4.0 can remove WALv1 support. It gives us more flexibility, but it's not very realistic to do patch release of LTS with risky feature like a new WAL.
* We literally have no formal process for LTS versions and we don't do them regularly.

### Add a CLI tool that rewrites WAL to a specific version

We could add a `promtool` command that rewrites WAL segments to a given version.

Users can then migrate their WAL with a single command either as an init process before reverting or manually on a disk.

This should take ~minutes even for larger WAL files.

Pros:
* Less need for a two-fold strategy?

Cons:
* We need to write migration code and ensure it's efficient enough for bigger data
* A bit painful to use on scale and remotely (e.g. on Kubernetes)

### Rewrite WAL before/during replay

Instead of supporting multiple directories for WAL for various versions, we could rewrite WAL on the start.

Pros:
* Simpler implementation

Cons:
* We already suffer from replay problems, so I propose an eventual rewrite.
* Rewrite is more risking than read-only WAL (of previous version)

### Don't version WAL, don't introduce a flag

Cons:
* Takes more time for features to be available to users
* Demotivating for format changes (long feedback loop)
* Harder to communicate what exactly changed in each Prometheus version or even implement backward compatibility?

### Record-based or segment based WAL versioning

Given we usually change WAL by changing its records, the WAL version could be simply [max number of types](https://github.com/prometheus/prometheus/blob/5e124cf4f2b9467e4ae1c679840005e727efd599/tsdb/record/record.go#L54) we write to WAL.
Alternatively, it could be per segment e.g. introduce a special version record type that is only in the front of the segment file.

Pros:
* Simpler to implement now.
* This would allow mixing Y and Y+1 segments/records in the same WAL, we would not need a new directory.

Cons:
* Won't work for bigger changes e.g.
  * changes that merge records 
  * sharding?

### Maintain two WALs (well four, with WBL)

Duplicating records would be too expensive for already painful latency and CPU/mem usage for e.g. replay.

However, we could write an entirely new WAL with only a disk latency and space penalty.

Cons:
* Disk space increased
* Inconsistent with the TSDB format strategy.
* Complex to implement.

### Use feature flag instead

Instead of `--storage.tsdb.stateful.write-wal-version` we could add a feature flag like logic.

We could add a flag that is similar to the current feature flags `--enable-feature`, but it has a "stateful" consequence -- once used, users will be able to revert only to certain Prometheus versions. For example a new `--enable-stateful-feature` flag to signal that behaviour.

Pros:
* No new flags for other storage pieces

Cons:
* No clear logic for defaulting here
* No clear ability to force Prometheus to write to wal v1 here unless we add a "feature flag value" for v1, which is odd.

## Action Plan

The tasks to do in order to migrate to the new idea.

* [ ] Introduce multi-directory WAL reading and v1 and v2 file, plus flag.
* [ ] Document WAL proposed recommendation for devs and users.
* [ ] Each release of Prometheus should mention either each version of the data format or what Prometheus version you can roll back it to.

## Resources

* https://stackoverflow.com/questions/13933275/use-wal-files-for-postgresql-record-version-control
