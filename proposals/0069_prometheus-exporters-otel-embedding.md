## Embeddable Prometheus Exporters in OpenTelemetry Collectors

* **Owners:**
  * [@ArthurSens](https://github.com/ArthurSens)

* **Implementation Status:** Not implemented

* **Related Issues and PRs:**
  * https://github.com/prometheus/exporter-toolkit/pull/357
  * https://github.com/prometheus/node_exporter/pull/3459
  * https://github.com/ArthurSens/prometheus-opentelemetry-collector (proof of concept)

* **Other docs or links:**

> TL;DR: This proposal introduces a mechanism to embed Prometheus exporters as native OpenTelemetry Collector receivers, reducing duplication of effort between the two ecosystems and enabling the "single binary" promise for telemetry collection without forcing reimplementation of hundreds of existing Prometheus exporters.

## Why

The OpenTelemetry Collector ecosystem faces a significant challenge: many components in collector-contrib are "drop-in" replacements for existing Prometheus exporters but often become unmaintained before reaching stability. This duplication of effort occurs because the promise of "one binary to collect all telemetry" is valuable to users, leading to reimplementation of functionality that already exists in mature Prometheus exporters.

This issue became particularly visible during OpenTelemetry's CNCF Graduation attempt, where feedback highlighted that users often feel frustrated when upgrading versions. In response, the Collector SIG decided to be stricter about accepting new components and more proactive in removing unmaintained or low-quality ones.

Meanwhile, the Prometheus community has developed hundreds of exporters over many years, many of which are stable. Creating parallel implementations in the OpenTelemetry ecosystem wastes community resources and often results in "drive-by contributions" that are abandoned shortly after acceptance.

### Pitfalls of the current solution

1. **Duplication of Work**: Infrastructure monitoring receivers are reimplemented in OpenTelemetry when functionally equivalent Prometheus exporters already exist.

2. **Unmaintained Components**: Many OpenTelemetry receivers that replicate Prometheus exporter functionality become unmaintained in early development stages.

3. **Quality and Stability Issues**: The pressure to provide comprehensive coverage leads to accepting components that may not meet quality standards, contributing to collector-contrib's stability problems.

4. **Diverging Ecosystems**: Two communities are solving the same problems independently, fragmenting effort and expertise.

5. **Maintenance Burden**: Both ecosystems must independently maintain similar functionality for monitoring the same infrastructure components.

## Goals

* Enable embedding of Prometheus exporters as native OpenTelemetry Collector receivers via the OpenTelemetry Collector Builder (OCB).
* Reduce duplication of effort between Prometheus and OpenTelemetry communities.
* Maintain the "single binary" promise for users who want comprehensive telemetry collection.
* Leverage existing, mature Prometheus exporters instead of reimplementing them in OTel Collector's side.
* Unify the two ecosystems to increase the likelihood of attracting more maintainers and contributors.

### Audience

* Prometheus exporter maintainers and developers
* OpenTelemetry Collector users and contributors
* Organizations using both Prometheus and OpenTelemetry in their observability stack
* Distribution builders (e.g., Grafana Alloy, OllyGarden Rose, AWS ADOT, DataDog DDOT, Elastic EDOT)

## Non-Goals

* Replace the existing OpenTelemetry Prometheus receiver (which scrapes Prometheus endpoints).
* Force all Prometheus exporters to implement embedding interfaces immediately.
* Automatically remove existing OpenTelemetry receivers that overlap with Prometheus exporters (this follows OpenTelemetry's own component removal policy).
* Mandate that OpenTelemetry collector-contrib includes embedded Prometheus exporters (distributions can be customized).

## How

### Overview

Prometheus exporters function similarly to OpenTelemetry Collector receivers: they gather information from infrastructure and expose it as metrics. The key difference is the output format and collection mechanism. Prometheus exporters expose an HTTP endpoint (typically `/metrics`) that is scraped, while OpenTelemetry receivers push metrics into a pipeline.

This proposal introduces a bridge between these two paradigms by:

1. **Creating a new Go library** (`prometheus-collector-bridge`) that defines interfaces Prometheus exporters can implement
2. **Providing adapter code** that converts Prometheus Registry metrics to OpenTelemetry's pmetric format
3. **Implementing OpenTelemetry Collector receiver interfaces** that wrap the adapter and Prometheus exporter

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                  OpenTelemetry Collector                    │
│                                                             │
│  ┌────────────────────────────────────────────────────┐     │
│  │         Prometheus Exporter Receiver               │     │
│  │                                                    │     │
│  │  ┌─────────────────────────────────────────────┐   │     │
│  │  │      Prometheus Exporter                    │   │     │
│  │  │   (implements ExporterLifecycleManager)     │   │     │
│  │  │                                             │   │     │
│  │  │  ┌──────────────────────────────────────┐   │   │     │
│  │  │  │    Prometheus Registry               │   │   │     │
│  │  │  │  (Collectors gathering metrics)      │   │   │     │
│  │  │  └──────────────────────────────────────┘   │   │     │
│  │  └─────────────────────────────────────────────┘   │     │
│  │                      │                             │     │
│  │                      ▼                             │     │
│  │  ┌───────────────────────────────────────────────┐ │     │
│  │  │Prometheus-Collector-Bridge(Registry → pmetric)│ │     │
│  │  │  (Periodic collection + conversion)           │ │     │
│  │  └───────────────────────────────────────────────┘ │     │
│  │                      │                             │     │
│  └──────────────────────┼─────────────────────────────┘     │
│                         ▼                                   │
│              ┌──────────────────────┐                       │
│              │    Consumer.Metrics  │                       │
│              │   (Pipeline data)    │                       │
│              └──────────────────────┘                       │
│                         │                                   │
│                         ▼                                   │
│              ┌──────────────────────┐                       │
│              │     Processors       │                       │
│              └──────────────────────┘                       │
│                         │                                   │
│                         ▼                                   │
│              ┌──────────────────────┐                       │
│              │      Exporters       │                       │
│              └──────────────────────┘                       │
└─────────────────────────────────────────────────────────────┘
```

### New Interfaces in prometheus-collector-bridge

The new `prometheus-collector-bridge` library will be created in a dedicated repository under the Prometheus organization. This library will define interfaces that Prometheus exporters must implement to be embeddable in OpenTelemetry Collectors:

#### ExporterLifecycleManager Interface

```go
// ExporterLifecycleManager is the interface that Prometheus exporters must implement
// to be embedded in the OTel Collector.
type ExporterLifecycleManager interface {
	// Start sets up the exporter and returns a prometheus.Registry
	// containing all the metrics collectors.
	Start(ctx context.Context, exporterConfig Config) (*prometheus.Registry, error)

	// Shutdown is used to release resources when the receiver is shutting down.
	Shutdown(ctx context.Context) error
}
```

#### Configuration Interfaces

```go
// ConfigUnmarshaler is the interface used to unmarshal the exporter-specific
// configuration using mapstructure and struct tags.
type ConfigUnmarshaler interface {
	// GetConfigStruct returns a pointer to the config struct that mapstructure
	// will populate. The struct should have appropriate mapstructure tags.
	GetConfigStruct() Config
}

// Config is the interface that exporter-specific configurations must implement.
type Config interface {
	// Validate checks if the configuration is valid.
	Validate() error
}
```

#### Receiver Configuration

```go
// ReceiverConfig holds the common configuration for all Prometheus exporter receivers.
type ReceiverConfig struct {
	// ScrapeInterval defines how often to collect metrics from the exporter.
	// Default: 30s
	ScrapeInterval time.Duration `mapstructure:"scrape_interval"`

	// ExporterConfig holds the exporter-specific configuration.
	ExporterConfig map[string]interface{} `mapstructure:"exporter_config"`
}
```

### Prometheus Registry to pmetric Conversion

The `prometheus-collector-bridge` library will include a scraper component that:

1. Calls `registry.Gather()` to collect metrics from the Prometheus Registry
2. Converts Prometheus metric families to OpenTelemetry's pmetric format

This conversion logic can leverage or adapt existing conversion code from the OpenTelemetry Prometheus receiver.

### OpenTelemetry Collector Receiver Implementation

The `prometheus-collector-bridge` library will provide a complete implementation of OpenTelemetry's receiver interfaces:

1. **component.Factory** - for component type and default configuration
2. **component.Component** - for lifecycle management
3. **receiver.Factory** - for creating receiver instances
4. **receiver.Metrics** - for producing pmetric data

This implementation will:
- Start the Prometheus exporter and obtain its Registry
- Run a periodic scrape loop based on the configured interval
- Convert scraped metrics to pmetric format
- Push metrics to the OpenTelemetry pipeline consumer

### Using with OpenTelemetry Collector Builder

Once a Prometheus exporter implements the new interfaces, it can be included in custom OpenTelemetry Collector distributions via OCB:

```yaml
# ocb-config.yaml
receivers:
  - gomod: github.com/prometheus/node_exporter v1.x.x
```

The OCB will recognize the exporter as a valid receiver and include it in the built collector binary.

### Example Configuration

In the OpenTelemetry Collector configuration:

```yaml
receivers:
  node_exporter:
    scrape_interval: 30s
    exporter_config:
      # Node exporter specific configuration
      collectors:
        - cpu
        - diskstats
        - filesystem

exporters:
  otlp:
    endpoint: otelcol:4317

service:
  pipelines:
    metrics:
      receivers: [node_exporter]
      exporters: [otlp]
```

### Implementation Steps

1. **Create the prometheus-collector-bridge repository** under the Prometheus organization
2. **Define the interfaces** in the new library (ExporterLifecycleManager, ConfigUnmarshaler, Config)
3. **Implement the Prometheus to pmetric converter** (potentially adapting existing code)
4. **Update one reference exporter** (e.g., node_exporter) to implement the new interfaces as a proof of concept
5. **Validate** with OpenTelemetry Collector Builder
6. **Document** the integration pattern for other exporters
7. **Gradually adopt** across other Prometheus exporters based on community interest

### Migration and Compatibility

* **No breaking changes** to existing Prometheus exporters that don't adopt the interfaces
* **Opt-in adoption** - exporters can choose when/if to implement embedding support
* **Backward compatibility** - embedded exporters still work as standalone exporters

### Known Problems

1. **Dependency conflicts**: Prometheus exporters and OpenTelemetry collector-contrib use different dependency versions. Building a distribution with both may require dependency alignment or replace directives.

2. **Scope of adoption**: It's unclear how many Prometheus exporters will adopt these interfaces. The proposal targets exporters in the `prometheus` and `prometheus-community` GitHub organizations initially.

3. **Metric semantics**: Subtle differences in how Prometheus and OpenTelemetry handle certain metric types may require careful mapping.

## Alternatives

### 1. Continue parallel implementation

Continue the current approach where OpenTelemetry community reimplements Prometheus exporter functionality.

**Rejected because**: This perpetuates the duplication of effort, maintenance burden, and quality issues that prompted this proposal.

### 2. Separate process managed by collector

Start Prometheus exporters as separate processes managed by the OpenTelemetry Collector, OpenAMP supervisor, or Kubernetes operator. The collector would scrape these processes' `/metrics` endpoints.

**Trade-offs**:
- Pros: No code changes needed to exporters; simpler dependency management
- Cons: Loses the "single binary" promise; increased operational complexity; higher resource usage; more complex deployment

This could serve as a complementary approach for exporters that cannot be embedded (e.g., those with complex dependencies or those requiring special privileges or written in languages that are not Go).

### 3. Use OpenTelemetry receiver exclusively

Rely solely on OpenTelemetry's existing Prometheus receiver that scrapes Prometheus exporters.

**Rejected because**: This doesn't solve the "single binary" goal and still requires running separate exporter processes. It also doesn't address the underlying duplication problem for new infrastructure integrations.

### 4. Use exporter-toolkit for adapter implementation

Extend the existing `exporter-toolkit` project to include the adapter code and interfaces for embedding exporters.

**Rejected because**: The exporter-toolkit was designed specifically to facilitate HTTP interactions (TLS, authentication, etc.) for Prometheus exporters. Adding adapter logic and OpenTelemetry receiver interfaces would expand its scope beyond its original purpose and design. A dedicated library with a clear focus on the bridge between Prometheus exporters and OpenTelemetry Collectors is more appropriate.

### 5. Wait for universal OTLP adoption

Wait until all infrastructure components natively export OTLP metrics.

**Rejected because**: This will take many years and may never fully happen. Prometheus exporters represent significant existing investment and will continue to be developed.

## Action Plan

The tasks to implement this proposal:

* [ ] 
