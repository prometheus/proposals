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
  

> TL;DR: This proposal introduces "secret providers" for Prometheus and Alertmanager, enabling them to fetch secrets from external systems. The config format will allow specifying a provider and its parameters for `<secret>` fields.

## Why

The motivation behind this design document is to enhance the security and flexibility of secret management in Prometheus. Currently, Prometheus only supports reading secrets from the filesystem or directly from the configuration file, which can lead to security vulnerabilities and limitations when working with certain service providers.

This proposal introduces secret discovery, similar to service discovery, where different secret providers can contribute code to read secrets from their respective APIs. This would allow for more secure and dynamic secret retrieval, eliminating the need to store secrets in the filesystem and reducing the potential for unauthorized access.

### Pitfalls of the current solution

Storing secrets in the filesystem poses risks, especially in environments like Kubernetes, where any pod on a node can access files mounted on that node. This could expose secrets to attackers. Additionally, configuring secrets through the filesystem often requires extra setup steps in some environments, which can be cumbersome for users.

Storing secrets inline can also pose risks, as the configuration file may still be accessible through the filesystem. Additionally it can lead to configuration files becoming cluttered and difficult to manage.

## Goals

Goals and use cases for the solution as proposed in [How](#how):

* Allow Prometheus to read secrets remotely from secret providers.
  * Anywhere in the configs([1](https://prometheus.io/docs/prometheus/latest/configuration/configuration/),[2](https://prometheus.io/docs/alerting/latest/configuration/#configuration-file-introduction)) with the `<secret>` type, it should be possible to fetch from secret providers
  * This will include Alertmanager 
* Introduce secret discovery, similar to service discovery, where different secret providers can contribute code to read secrets from their respective API.
* Backwards compatibility for secrets in config

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
* De-duplication and re-using common config values for secret provider configs
  * This will be left to a follow up proposal if needed

## How


### Configuration

Wherever a `<secret>` type is present in the configuration files, we will allow users to specify a map specifying how to fetch from a secret provider. The generic format would be

```
secret_field:
  provider:  <type of the provider>
  <property1>: <value1>
  ...
  <propertyN>: <valueN>
```

For example when specifying a password fetched from the kubernetes provider with an id of `pass2` in namespace `ns1` for the HTTP passsword field it would look like this:

```
        password:
          provider: kubernetes
          namespace: ns1
          secret_id: pass2
```

### Inline secrets

When specifying secrets inline in the config file, a string can be passed in as usual for backwards compatibility.
```
        password: my_important_secret
```

### Error handling

We can classify all errors stemming from secret provider failures into 2 cases.

The first case is that we have not gotten any secret value since startup. In this case we should not initialize any component that mentions this faulty secret, log this failure and schedule a retry to get this secret value and initialize the component.

The second case is that we already have a secret value, but refreshing it has resulted in an error. In this case we should keep the component that uses this secret running with the potentially stale secret, and schedule a retry.


### Secret rotation

When a secret is rotated, it is possible for this to happen out of sync. For  example, one of the following could happen with secrets used for target scraping:

1. The scrape target's secret updated but the currently stored secret hasn't updated yet.
2. The secret provider's secret changes but the scrape target hasn't updated to the new secret yet.

Therefore to help alleviate 1. we can ignore caching and query the secret provider again if permission errors are reported by the component.

To alleviate 2. we can store the previous secret value before rotation for a period of time and use it as a fallback in case of permission errors.

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
...
        password:
          provider: bootstrapped
          secret_id: pass1
          auth_token:
            provider: kubernetes
            secret_id: auth_token
```

However, an initial implementation might only allow inline secrets for secret providers. This might limit the usefulness of certain providers that require sensitive information for their own configuration.

### Where will code live

Both the Alertmanager and Prometheus repos will be able to use secret providers. The code will eventually live in a separete repository specifically created for it.

## Action Plan

* [ ] Create action plan after doc is stable!