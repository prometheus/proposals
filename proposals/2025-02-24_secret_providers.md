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

The motivation behind this design document is to enhance the flexibility of secret management in Prometheus. Currently, Prometheus only supports reading secrets from the filesystem or directly from the configuration file, which can be cumbersome when running it in certain enviroments or when frequent secret rotations are needed.

This proposal introduces secret discovery, similar to service discovery, where different secret providers can contribute code to read secrets from their respective APIs. This would allow for more dynamic secret retrieval, eliminating the need to store secrets in the filesystem and simplifying the user experience.

### Pitfalls of the current solution

In certain enviroments, configuring secrets through the filesystem often requires extra setup steps or it might not even be possible. This can be cumbersome for users.

Storing secrets inline is always possible, but it can lead to configuration files becoming cluttered and difficult to manage. Additionally rotating inline secrets will be more troublesome.

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
  <type of the provider>:
    <property1>: <value1>
    ...
    <propertyN>: <valueN>
```

For example when specifying a password fetched from the kubernetes provider with an id of `pass2` in namespace `ns1` for the HTTP passsword field it would look like this:

```
        password:
          kubernetes:
            namespace: <ns>
            name: <secret name>
            key: <data's key for secret name>
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

If we are starting up prometheus and do not get any secret values, startup will continue and prometheus will continue to run and retry finding secrets. If there are components that are fully specified, they will run during this time. The idea is that it is better to send partial metrics than no metrics, and the emitted metrics for secrets can alert users if there is a problem with their service providers.

### Secret Refresh and Caching

Prometheus will fetch secrets from configured providers and cache them locally. There is a trade off here between up-to-date credentials with performance considerations and API costs, which users might make different choices on.

* **Local Caching:** Secrets retrieved successfully from a provider are stored in memory
* **Background Refresh:** A dedicated background process periodically attempts to refresh each configured remote secret from its provider.
* **Refresh Interval:** A default refresh interval of 1 hour is used, avoiding excessive calls to external secret providers (typical rotation schedules often measured in hours or days). However, this interval should be configurable on a per-provider instance basis. For example:
```yaml
scrape_configs:
  - job_name: 'example'
    basic_auth:
      username: 'user'
      password:
        vault: # Example provider
          address: "https://vault.example.com"
          path: "secret/data/prometheus/example_job"
          key: "password"
          refresh_interval: 30m # Override default for this secret
    # ... other config ...
```
* **Caching Behavior on Failure:** If a scheduled background refresh attempt fails (e.g., due to network issues, temporary provider unavailability, invalid credentials after rotation), Prometheus will continue to use the last successfully fetched secret value. This ensures components relying on the secret can continue operating with the last known good credential, preventing outages due to transient refresh problems. Failed refresh attempts will be logged, and the `prometheus_remote_secret_state` metric will reflect the 'stale' state.
* **Permission Errors:** If a component using a cached secret reports a specific permission or authentication error, this might indicate the cached secret is no longer valid. Hence, an immediate refresh attempt for that specific secret is triggered, bypassing the regular refresh interval.
* **Not Querying Per-Scrape:** It is explicitly **not** the default behavior to query the secret provider on every use.


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
* success: the last request was succesful

```
# HELP prometheus_remote_secret_state Describes the current state of a remotely fetched secret.
# TYPE prometheus_remote_secret_state gauge
prometheus_remote_secret_state{provider="kubernetes", secret_id="pass1", state="success"} 0
prometheus_remote_secret_state{provider="kubernetes", secret_id="auth_token", state="stale"} 1
prometheus_remote_secret_state{id="myk8secrets", secret_id="pass2", state="error"} 2
```

### Nested secrets

Secret providers might require secrets to be configured themselves. We will allow secrets to be passed in to secret providers.

```
...
        password:
          bootstrapped:
            secret_id: pass1
            auth_token:
              kubernetes:
                name: <secret name>
                key: <data's key for secret name>
```

Note that there is a 'chicken and egg' problem here, where you need to have credentials to access the secret provider itself. Normally this bootstrapping would be done through inline or filesystem secrets. For cloud enviroments, there is usually an identity associated with the machine in the enviroment that can be used. However, in both cases this type of 'bootstrapping' doesn't really increase security as you should already have access to the underlying secrets. Our goal here is just to decrease toil.

However, an initial implementation might only allow inline secrets for secret providers. This might limit the usefulness of certain providers that require sensitive information for their own configuration.

### Where will code live

Both the Alertmanager and Prometheus repos will be able to use secret providers. The code will eventually live in a separete repository specifically created for it.

## Open questions

* What is the process for creating a secret provider implementation?
* How can we prevent too many dependencies from getting pulled in from different providers?

## Secret provider interfaces in the wild 

A summary of popular secret providers
### [HashiCorp Vault](https://developer.hashicorp.com/hcp/docs/vault-secrets)

```
// Step 1: Authenticate with the Vault server
// This typically involves providing credentials or using an authentication method (e.g., token, AppRole)
authentication_response = authenticate_with_vault(authentication_method, credentials)
auth_token = authentication_response.token

// Step 2: Specify the path to the secret you want to retrieve
secret_path = "secret/data/my_application/database_credentials"

// Step 3: Read the secret data from the specified path using the auth token
secret_data_response = read_vault_secret(secret_path, auth_token)
```

### [AWS Secrets Manager](https://docs.aws.amazon.com/secretsmanager/latest/userguide/intro.html)

```
// Step 1: Configure AWS credentials and region
// This is typically done via environment variables, IAM roles, or config files
configure_aws_sdk()

// Step 2: Specify the name or ARN of the secret
secret_name = "my/application/database_secret"

// Step 3: Retrieve the secret value from AWS Secrets Manager
// The secret value is returned as a string, often containing JSON
secret_value_response = get_aws_secret_value(secret_name)
secret_password = secret_value_response.secret_string
```

### [Azure Key Vault](https://learn.microsoft.com/en-us/azure/key-vault/general/overview)

```
// Step 1: Authenticate with Azure Active Directory
// This is often done using Managed Identity or a Service Principal
authentication_client = create_azure_identity_client()
credential = authentication_client.get_credential()

// Step 2: Create a Key Vault client
key_vault_url = "https://my-key-vault-name.vault.azure.net/"
key_vault_client = create_key_vault_secret_client(key_vault_url, credential)

// Step 3: Specify the name of the secret
secret_name = "DatabasePassword"

// Step 4: Retrieve the secret
secret = key_vault_client.get_secret(secret_name)
```

### [Google Secret Manager](https://cloud.google.com/secret-manager/docs)

```
// Step 1: Authenticate with Google Cloud
// This is typically handled by the client library using environment variables or service account keys
secret_manager_client = create_google_secret_manager_client()

// Step 2: Specify the secret name and version
// Format: projects/PROJECT_ID/secrets/SECRET_NAME/versions/VERSION_ID (use 'latest' for the current version)
secret_version_name = "projects/my-gcp-project/secrets/my-database-secret/versions/latest"

// Step 3: Access the specified secret version
response = secret_manager_client.access_secret_version(secret_version_name)
```

### [Kubernetes Secrets](https://kubernetes.io/docs/concepts/configuration/secret/)

```
// Step 1: Configure Kubernetes client
// This typically involves loading the kubeconfig file or using in-cluster configuration
kubernetes_client = configure_kubernetes_client()

// Step 2: Specify the namespace and name of the secret
secret_namespace = "my-application-namespace"
secret_name = "my-database-secret"

// Step 3: Retrieve the secret object from the Kubernetes API
secret_object = get_kubernetes_secret(secret_namespace, secret_name, kubernetes_client)
```

## Action Plan

* [ ] Create action plan after doc is stable!