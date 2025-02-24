## Remote Secrets (Secret Providers)

* **Owners:**
  * Henrique Matulis (@hsmatulisgoogle)

* **Implementation Status:** Not implemented

* **Related Issues and PRs:**
  * https://github.com/prometheus/prometheus/issues/8551
  * https://github.com/prometheus/prometheus/issues/11477
  * https://github.com/prometheus/alertmanager/issues/3108
  * https://github.com/prometheus/prometheus/pull/13955
  * https://github.com/prometheus/exporter-toolkit/pull/141
  * https://github.com/prometheus/prometheus/issues/5795




* **Other docs or links:**
  * [Prometheus Remote Secrets Doc](https://docs.google.com/document/d/1EqHd2EwQxf9SYD8-gl3sgkwaU6A10GhiN7aw-2kx7NU/edit?tab=t.0)
    * Previous proposal by @TheSpiritXIII
  * https://stackoverflow.com/questions/43609144/can-prometheus-store-basic-auth-passwords-in-any-format-other-then-plain-text
  * https://groups.google.com/g/prometheus-users/c/yWLE9qoG5GU/m/ke8ewxjIAQAJ
  

> TL;DR: This document proposes adding a new way for Prometheus to discover and use secrets from various secret providers, similar to how service discovery works. It introduces a new configuration section where users can specify different secret providers and their configurations. It also defines interfaces and methods for secret providers to implement, allowing for flexibility in how secrets are fetched and managed.

## Why

The motivation behind this design document is to enhance the security and flexibility of secret management in Prometheus. Currently, Prometheus only supports reading secrets from the filesystem or directly from the configuration file, which can lead to security vulnerabilities and limitations when working with certain service providers.

This proposal introduces secret discovery, similar to service discovery, where different secret providers can contribute code to read secrets from their respective APIs. This would allow for more secure and dynamic secret retrieval, eliminating the need to store secrets in the filesystem and reducing the potential for unauthorized access.

### Pitfalls of the current solution

Storing secrets in the filesystem poses risks, especially in environments like Kubernetes, where any pod on a node can access files mounted on that node. This could expose secrets to attackers. Additionally, configuring secrets through the filesystem often requires extra setup steps in some enviroments, which can be cumbersome for users.

Storing secrets inline can also pose risks, as the configuration file may still be accessible through the filesystem. Additionally it can lead to configuration files becoming cluttered and difficult to manage.

## Goals

Goals and use cases for the solution as proposed in [How](#how):

* Allow Prometheus to read secrets remotely from secret providers.
* Introduce secret discovery, similar to service discovery, where different secret providers can contribute code to read secrets from their respective API.

### Audience

* Prometheus maintainers
* Alertmanager maintainers
* Secret providers interested in contributing code
* Users looking to use secret providers

## Non-Goals

* Implement a variety of secret providers.

## How


### Interfaces

Secret providers will be created from their configurations through the following interface:

```
type SecretProviderConfiguration interface {
	// Returns the secret provider for the given configuration.
	Load() (SecretProvider, error)
}
```

Secret providers will have to satisfy the following interface. Secret providers will be expected to be long lived to allow for caching. However they will be re-instantiated in case of a configuration change. The Fetch method will be called before each http request done through `prometheus/common/config`

```
type SecretProvider interface {
	// Returns the secret value for the given configuration.
  Fetch(ctx context.Context, secretRef string) (string, error)
}
```

### Configuration

Globally there will be a section to configure secrete providers to be used throught the config file. Here is an example:

```
global:
  secret_providers:
  - name: my_secret_provider
    kubernetes_sp_config:
      namespace: ns1
```


For secret related fields under http_config, a new `ref` variant will be added that can reference these secret providers. For instance, basic_auth will have the following form

```
basic_auth:
...
  password: <secret>
  password_file: <string>
  password_ref:
    <string>: <string>
```

and could be instantiated as follows:

```
basic_auth:
  password_ref:
    my_secret_provider: 'my-secret-key'
```

#### Full configuration example
```
global:
  secret_providers:
  - name: kube1
    kubernetes_sp_config:
      namespace: ns1
  - name: kube2
    kubernetes_sp_config:
      namespace: ns2
...
  scrape_configs:
  - job_name: 'http-basic-auth-endpoint'
    http_config:
      basic_auth:
        username: 'myuser'
        password_ref:
          kube1: 'myuser-pass'
    static_configs:
    - targets: ['www.endpoint.com/basic-auth']
  scrape_configs:
  - job_name: 'http-authorization-auth-endpoint'
    http_config:
      authorization:
        credentials_ref:
          kube2: 'header-credentials'
    static_configs:
    - targets: ['www.endpoint.com/authorization-auth']
  scrape_configs:
  - job_name: 'tls-certificate-endpoint'
    http_config:
      tls_config:
        key_ref:
          kube2: 'header-credentials'
    static_configs:
    - targets: ['www.endpoint.com/tls-certificate']
```


## Alternatives

### Modify Secret type

Currently most secrets in the config use the prometheus.common.config.Secret alias. We could modify this type such that if only a string is passed it behaves the same as before, and if a map is passed in it assumes it to be a reference to be fetched from the associated secret provider.

This would mean the config would look like this instead:
```
basic_auth:
  password: 'my-secret-value'
...
basic_auth:
  password:
    my_secret_provider: 'my-secret-key'
```

Pros:
* Simpler, more unified config
* Defines a clear way to use secrets outside of the `http_config` component

Cons:
* Can be more confusing
* Requires more careful documentation
* Unclear how to refresh the configs for arbitrary components that could now change dynamically


## Action Plan

* [x] Add a secret manager to `prometheus.common.config`
* [ ] Add secret providers to prometheus  
* [ ] Add docs 
