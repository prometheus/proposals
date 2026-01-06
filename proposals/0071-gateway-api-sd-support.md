## Gateway API Support in Kubernetes Service Discovery

* **Owners:**
  * @rexagod

* **Implementation Status:** Not implemented

* **Related Issues and PRs:**
  * https://github.com/prometheus/prometheus/issues/15863

* **Other docs or links:**
  * [Kubernetes Gateway API Documentation](https://gateway-api.sigs.k8s.io/)
  * [Gateway API v1.0 Announcement](https://kubernetes.io/blog/2023/10/31/gateway-api-ga/)
  * [Prometheus Kubernetes SD Configuration](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#kubernetes_sd_config)

> TL;DR: This proposal adds Gateway API support to Prometheus's `kubernetes_sd_config`, enabling service discovery for all relevant resources falling under the former's stable version. This complements the existing Ingress role to the newer Gateway API standard, which is positioned as "Ingress V2" and is now GA in Kubernetes.

## Why

The Kubernetes Gateway API is the successor to the Ingress API, providing a more expressive, extensible, and role-oriented networking configuration for Kubernetes. Gateway API GA'd a good while ago and is rapidly gaining adoption as the standard way to configure ingress traffic in Kubernetes clusters.

Currently, Prometheus supports service discovery for traditional Ingress resources through the Ingress role in `kubernetes_sd_config`. This enables blackbox monitoring and other use cases where users need to discover and monitor exposed HTTP endpoints. However, as the Kubernetes ecosystem transitions to Gateway API, Prometheus users need equivalent discovery capabilities for Gateway API resources.

### Pitfalls of the current solution

Users migrating from Ingress to Gateway API lose the ability to automatically discover their exposed routes in Prometheus. The Ingress role enables monitoring Ingress endpoints, but there's no equivalent for equivalent Gateway API resources, creating monitoring blind spots.

As Gateway API becomes the standard (and is already GA), updating Prometheus's service discovery capabilities to cater to the Kubernetes networking evolution would ensure users can continue to leverage automated discovery for their Ingress endpoints without manual configuration.

## Goals

* Add support for discovering Gateway API **v1** resources in `kubernetes_sd_config`.
* Support the following Gateway API resources:
  * `HTTPRoute`: HTTP(S) routing rules
  * `GRPCRoute`: gRPC routing rules
* Provide appropriate metadata labels for discovered targets.
* Maintain backward compatibility with existing `kubernetes_sd_config` configurations.
* Follow existing patterns established by the Ingress role for consistency, wherever applicable.

### Audience

* Platform engineers managing Kubernetes clusters with Gateway API.
* Prometheus users running workloads on Kubernetes.
* SREs monitoring HTTP(S)/gRPC endpoints.
* Users migrating from Ingress to Gateway API.

## Non-Goals

* Replace or deprecate the existing Ingress role (both should coexist).
* Support non-stable Gateway API resources (TLSRoute, TCPRoute, UDPRoute are non-stable resources and excluded).
* Support Gateway API implementations outside of what's offered by the Kubernetes Gateway Controller, i.e., Contour, Gloo, Kong, etc. CNCF projects that overlap this effort to some degree are subject to discussion and may receive support in the future (such as Istio).

## How

### Overview

Extend the `kubernetes_sd_config` mechanism with new roles for Gateway API resources. The implementation will follow the existing pattern used for Ingress discovery, wherever applicable, adapting it to the Gateway API resource structure.

### Supported Roles

Add the following new roles to `kubernetes_sd_config`:

1. `httproute`: Discovers HTTPRoute resources
   * Enables monitoring of HTTP(S) endpoints
   * One target per hostname/path combination

2. `grpcroute`: Discovers GRPCRoute resources
   * Enables monitoring of gRPC endpoints
   * One target per hostname/method combination

### Configuration Example

```yaml
scrape_configs:
  - job_name: 'gateway-api-blackbox'
    metrics_path: /probe
    params:
      module: [http_2xx]
    kubernetes_sd_configs:
      - role: httproute
        namespaces:
          names:
            - production
            - staging
    relabel_configs:
      - source_labels: [__meta_kubernetes_httproute_scheme, __address__, __meta_kubernetes_httproute_path]
        action: replace
        target_label: __param_target
        regex: (.+);(.+);(.+)
        replacement: ${1}://${2}${3}
      - source_labels: [__param_target]
        target_label: instance
      - target_label: __address__
        replacement: blackbox-exporter:9115
```

### Metadata Labels

Each role will expose appropriate metadata labels following the existing Kubernetes SD conventions:

#### HTTPRoute Role Labels
* `__meta_kubernetes_httproute_name` - Name of the HTTPRoute
* `__meta_kubernetes_httproute_namespace` - Namespace of the HTTPRoute
* `__meta_kubernetes_httproute_hostname` - Hostname from the route rule
* `__meta_kubernetes_httproute_path` - Path from the route rule
* `__meta_kubernetes_httproute_scheme` - Scheme (http/https)
* `__meta_kubernetes_httproute_parent_ref_name` - Name of the parent Gateway
* `__meta_kubernetes_httproute_parent_ref_namespace` - Namespace of the parent Gateway
* `__meta_kubernetes_httproute_label_<labelname>` - Each label from the HTTPRoute
* `__meta_kubernetes_httproute_labelpresent_<labelname>` - `true` for each label
* `__meta_kubernetes_httproute_annotation_<annotationname>` - Each annotation
* `__meta_kubernetes_httproute_annotationpresent_<annotationname>` - `true` for each annotation

Similar metadata label patterns will be established for the GRPCRoute role, following the same conventions as HTTPRoute with appropriate adaptations for gRPC-specific attributes (e.g., method matching instead of path matching).

#### Gateway Role Labels
* `__meta_kubernetes_gateway_name` - Name of the Gateway
* `__meta_kubernetes_gateway_namespace` - Namespace of the Gateway
* `__meta_kubernetes_gateway_class` - GatewayClass name
* `__meta_kubernetes_gateway_class_label_<labelname>` - Each label from the GatewayClass
* `__meta_kubernetes_gateway_class_labelpresent_<labelname>` - `true` for each GatewayClass label
* `__meta_kubernetes_gateway_class_annotation_<annotationname>` - Each annotation from the GatewayClass
* `__meta_kubernetes_gateway_class_annotationpresent_<annotationname>` - `true` for each GatewayClass annotation
* `__meta_kubernetes_gateway_listener_name` - Listener name
* `__meta_kubernetes_gateway_listener_port` - Listener port
* `__meta_kubernetes_gateway_listener_protocol` - Listener protocol
* `__meta_kubernetes_gateway_label_<labelname>` - Each label from the Gateway
* `__meta_kubernetes_gateway_labelpresent_<labelname>` - `true` for each label
* `__meta_kubernetes_gateway_annotation_<annotationname>` - Each annotation
* `__meta_kubernetes_gateway_annotationpresent_<annotationname>` - `true` for each annotation

NOTE: While BackendTLSPolicy is a Gateway API v1 GA resource that configures TLS for Gateway-to-backend connections, metadata labels for BackendTLSPolicy are not included in this initial proposal. BackendTLSPolicy's `targetRef` can reference any resource kind (Service or other resources via CEL), which would require dynamic informers to track arbitrary resource types. This adds some implementation complexity for the initial design, which should ideally be preceded by some level of discussion first. BackendTLSPolicy metadata support may be added in future iterations once the core Gateway API discovery functionality is established.

NOTE: Following the established [pattern](https://github.com/rexagod/prometheus/blob/main/discovery/kubernetes/ingress.go#L259) from the Ingress role, the `__address__` label will be set to the **hostname** from the route specification, not a pod IP or service endpoint.

### RBAC Requirements

The Prometheus service account will need additional permissions to access Gateway API resources:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: prometheus
rules:
  - apiGroups:
      - gateway.networking.k8s.io
    resources:
      - backendtlspolicies # only for metadata labels, not service discovery
      - gateways           # only for metadata labels, not service discovery
      - gatewayclasses     # only for metadata labels, not service discovery
      - httproutes
      - grpcroutes
    verbs:
      - get
      - list
      - watch
```

NOTE: `GatewayClass` is only slated for metadata tracking, not service discovery, as the controller information exposed by them may be be fetched using existing `service` or `pod` roles (same practice as with Ingress controllers).

### Migration Path

Users currently using Ingress discovery can:
* keep using those role configurations (no breaking changes),
* gradually add Gateway API roles as they migrate their workloads,
* run both in parallel during migration period, and finally,
* remove Ingress configurations once fully migrated to the Gateway API.

## Alternatives

### 1. `static_configs` for Gateway API endpoints

Users could manually configure targets for Gateway API endpoints. However, this:
* requires manual maintenance whenever routes change,
* loses the automation benefits of service discovery,
* is error-prone and doesn't scale well, and,
* defeats the purpose of Prometheus's powerful SD mechanisms.

### 2. `relabel_configs` from existing roles

Users could rely on existing `service` or `pod` roles and relabel them to find referenced resources as reflected in the Gateway API resources. However, this:
* doesn't provide visibility into the actual exposed routes,
* cannot discover the hostnames and paths exposed by the native Gateway API implementation, and,
* adds complexity to configurations.

### 3. `gatewayapi` role instead of separate roles

Instead of separate `httproute`, and `grpcroute` roles, use one `gatewayapi` role. This would be simpler from a configuration perspective. However:
* HTTP(S) and gRPC routes have different metadata and use cases,
* separate roles provide better filtering and more intuitive relabeling,
* separate roles follow the existing pattern of having distinct roles for different Kubernetes resources, and,
* separate roles help users discover only the route types relevant to their monitoring needs.

## Action Plan

* [ ] Implement Gateway API discovery framework:
  * [ ] Add `grpcroute` role support
  * [ ] Add `httproute` role support
* [ ] Implement metadata labels:
  * [ ] Add `backendtlspolicy` resource labels (most likely in a follow-up PR, see "Metadata Labels" section for details)
  * [ ] Add `gateway` resource labels
  * [ ] Add `gatewayclass` resource labels
  * [ ] Add `grpcroute` resource labels
  * [ ] Add `httproute` resource labels
* [ ] Add unit and integration tests for new roles and labels
* [ ] Update RBAC and user documentation
