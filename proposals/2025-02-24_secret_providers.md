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

Storing secrets in the filesystem poses risks, especially in environments like Kubernetes, where any pod on a node can access files mounted on that node. This could expose secrets to attackers. Additionally, configuring secrets through the filesystem often requires extra setup steps in some environments, which can be cumbersome for users.

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

* Support for non-string secret values
* Secret transformations/processing
  * Things like String concatenation, base64 encoding/decoding
* Default values

## How


### Configuration

Wherever a secret can be inserted in the configuration file, we will allow users to specify a special YAML tag for secrets.

```
        password: !secret provider=kubernetes namespace=ns1 secret_id=pass1
...
        password: !secret
          provider: kubernetes
          namespace: ns1
          secret_id: pass2
```
Additionally there will be a global section to partially configure secret providers to prevent duplication. For instance if the kubernetes provider is used multiple times like above, it can be rewritten as: 

```
global:
  base_secrets:
  - id: myk8secrets
    provider: kubernetes
    namespace: ns1
...
        password: !secret id=myk8secrets secret_id=pass1
...
        password: !secret
          id: myk8secrets
          secret_id: pass2
```

### Inline secrets

When specifying secrets inline in the config file, the inline provider will be used. If a string is passed in, it is automatically converted to an inline provider to be consistent with previous syntax.
```
        password: !secret provider=inline secret=my_important_secret
...
# String types that are passed in are converted to the inline secret provider
        password: my_important_secret
```

### Error handling

We can classify all errors stemming from secret provider failures into 2 cases.

The first case is that we have not gotten any secret value since startup. In this case we should not initialize any component that mentions this faulty secret, log this failure and schedule a retry to get this secret value and initialize the component.

The second case is that we already have a secret value, but refreshing it has resulted in an error. In this case we should keep the component that uses this secret running with the potentially stale secret, schedule a retry and 

### Metrics

Metrics should be present to help users identify the errors mentioned above (in addition to logs). Therefore the following metrics should be reported per secret present in the config file:

The time since the last successful secret fetch

```
prometheus_remote_secret_last_successful_fetch_seconds{provider="kubernetes", secret_id="pass1"} 15
```

A state enum describing in which error condition the secret is in:
* error: there has been no successful request and no secret has been retrieved
* stale: a request has succeeded but the latest request failed
* none: the last request was succesful

```
# HELP prometheus_remote_secret_state Describes the current state of a remotely fetched secret.
# TYPE prometheus_remote_secret_state gauge
prometheus_remote_secret_state{provider="kubernetes", secret_id="pass1", state="none"} 0
prometheus_remote_secret_state{provider="kubernetes", secret_id="auth_token", state="stale"} 1
prometheus_remote_secret_state{id="myk8secrets", secret_id="pass2", state="error"} 2
```

### Nested secrets

Secret providers might require secrets to be configured themselves. We will allow secrets to be passed in to secret providers.

```
global:
  base_secrets:
  - id: myk8secrets
    provider: kubernetes
  - id: bootstrapped
    provider: bootstrapped
    auth_token: !secret id=myk8secrets secret_id=auth_token
...
        password: !secret id=bootstrapped secret_id=pass1
```

However, an initial implementation might only allow inline secrets for secret providers. This might limit the usefulness of certain providers that require sensitive information for their own configuration.

### Where will code live

Both the alertmanager and prometheus repos will be able to use secret providers. The code will eventually live in a separete repository specifically created for it.

## Alternatives

### Secret references

Instead of allowing users to partially fill in the remaining fields of the secret provider, require all fields to be filled ahead of time and only a reference must be passed in:

 ```
global:
  secrets:
  - id: myk8secret1
    provider: kubernetes
    namespace: ns1
    secret_id: pass1
...
        password_ref: myk8secret1
```

However a downside of this approach is the large number of fields that would need to have variants created. (Currently 22 cases from searching [here](https://prometheus.io/docs/prometheus/latest/configuration/configuration/) for `<secret>`)

## Action Plan

* [ ] Create action plan after doc is stable!