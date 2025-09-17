# remote_write_sender: Add Support for Remote Write 2.0

**Date**: 16/09/2025 \
**Status**: In Review \
**Authors**: Minh Nguyen ([https://github.com/pipiland2612](https://github.com/pipiland2612)) \
**Relevant Links**:
* [https://github.com/prometheus/compliance/issues/101](https://github.com/prometheus/compliance/issues/101)
* [https://github.com/prometheus/prometheus/issues/16944](https://github.com/prometheus/prometheus/issues/16944)


## What

**TL;DR**: I propose extending the Prometheus compliance test for remote write senders to support Remote Write 2.0, clarifying the test scope in the README, and replacing the current TSDB-based implementation with the official Remote Write client from remote_api.go. This will improve test clarity, reduce maintenance overhead, and ensure robust testing for Remote Write 2.0 features like native histograms, NHCB, exemplars, and metadata.


## Why

The goal is to improve the stability and reliability of Prometheus Remote Write 2.0 implementations by:



* Adding comprehensive compliance tests for Remote Write 2.0.
* Making it easier to test both write and receive implementations for v1 and v2 protocols.
* Addressing limitations in the current test setup, which is overly tied to Prometheus’s TSDB and lacks clear scope definition.


### Problems with the Current State



1. **Unclear Test Scope**: The current compliance test not only validates Remote Write (v1) but also tests scraping logic (Prometheus text format, labels like job and instance, up metric, staleness, and ordering). This mixed scope is not well-documented, causing confusion about what the test expects from a "scraper + sender" system.
2. **TSDB Nuances**: The test relies on Prometheus’s TSDB Appender, which introduces storage-specific complexities (e.g., separate metadata/exemplar storage, feature flag-dependent logic). These nuances can change over time, making tests brittle.
3. **No Remote Write 2.0 Support**: The test only covers Remote Write v1, missing support for v2 features like cumulative totals (CT), native histograms, NHCB (native histogram cumulative buckets), exemplars, and metadata.


## Goals



1. Clearly document the scope of the compliance test in the README, covering both scraping and remote write expectations.
2. Use the official Remote Write client (remote_api.go) to process raw v1.WriteRequest and v2.Request structs, removing TSDB nuances (Appender).
3. Add test cases for v2-specific features (CT, native histograms, NHCB, exemplars, metadata) while maintaining v1 compatibility.


## How


### First Goal: Clarify Test Scope

Update the README.md to explicitly describe the compliance test’s scope, covering both scraping and remote write components.


### Second Goal: Replace TSDB Nuances with Official Remote Write Client

Replace the current TSDB Appender-based setup with the new Remote Write handler from [https://github.com/prometheus/client_golang/blob/main/exp/api/remote/remote_api.go](https://github.com/prometheus/client_golang/blob/main/exp/api/remote/remote_api.go).



* Current Setup: Uses TSDB’s Appender to process remote write requests into storage-specific formats (batches, samples), which introduces issues like separate metadata/exemplar storage and feature flag dependencies.
* New Setup: Implement a test server using the remote_api handler to capture raw protobuf structs.
* Conversion to Samples: To avoid duplicating validation logic for v1 and v2, convert both v1.WriteRequest and v2.Request to a common Sample struct for shared checks (e.g., labels, values). This preserves existing test logic without relying on TSDB.


### Third Goal: Comprehensive Remote Write 2.0 Tests

Add test cases for Remote Write 2.0, covering:



* CT: Validate that timeseries include correct cumulative totals.
* Native Histograms: Check for correct histogram bucket formats
* NHCB: Allow scrapers to enable NHCB via configuration (e.g., test-specific flag or header) and validate the output.
* Exemplars: Ensure exemplars are correctly attached to timeseries.
* Metadata: Validate metadata fields (e.g., unit, type)


## Action Plan



1. Update README to add a section clarifying the test scope (scraping and remote write expectations).
2. Replace TSDB Appender with remote_api.go handler.
3. Convert v1.WriteRequest and v2.Request to Sample struct for validation.
4. Add test cases for CT, native histograms, NHCB, exemplars, and metadata.: