## Opt-in code-signing service for Prometheus ecosystem projects

* **Owners:**
  * [@jkroepke](https://github.com/jkroepke)

* **Implementation Status:** Not implemented

* **Related Issues and PRs:**
  * [windows_exporter README: binaries signed with a self-signed certificate](https://github.com/prometheus-community/windows_exporter/blob/main/README.md)

* **Other docs or links:**
  * [Azure Artifact Signing](https://learn.microsoft.com/azure/artifact-signing/)
  * [Azure Artifact Signing pricing](https://azure.microsoft.com/pricing/details/artifact-signing/)
  * [SignPath Foundation terms](https://signpath.org/terms)

> TL;DR: This proposal asks the Prometheus team to obtain shared access to a publicly trusted code-signing service (for example Azure Artifact Signing, provisioned through the CNCF / Linux Foundation) and to make it available to repositories in the `prometheus` and `prometheus-community` GitHub organizations. Using it is **opt-in per repository**: the maintainers of each project decide on their own whether and what they sign. Only release builds are signed, never snapshots or pull request builds. This proposal deliberately does **not** decide whether Prometheus binaries should be signed.

## Why

Some Prometheus ecosystem projects are mainly or exclusively consumed on platforms where code signing matters to users. The most visible example is [windows_exporter](https://github.com/prometheus-community/windows_exporter), which ships `.exe` binaries and `.msi` installers for `amd64` and `arm64`.

Today a project that wants publicly trusted signatures has no path inside the Prometheus organizations. A publicly trusted code-signing certificate requires a validated legal identity, and neither `prometheus` nor `prometheus-community` is a legal entity. Individual maintainers can usually not fill that role either: services like Azure Artifact Signing only validate individual developers in a few countries, and a certificate issued to a maintainer personally would publish their legal name and location as the publisher of a community project.

### Pitfalls of the current solution

* windows_exporter signs its binaries and installers with a **self-signed certificate** and asks users to import it into their trusted root store. That is a poor security practice to recommend, and it does not help with Microsoft Defender SmartScreen or with enterprise allow-listing.
* Unsigned or self-signed binaries are blocked or flagged by SmartScreen, Smart App Control, and many enterprise policies (AppLocker / App Control for Business). Users then run ad-hoc workarounds or rebuild from source.
* The signing key of windows_exporter is a long-lived PFX file stored as a GitHub Actions secret. A leak cannot be scoped or revoked in a fine-grained way.
* Each project that wants signing would have to solve identity validation, billing, and key custody alone.

## Goals

* Give interested projects in `prometheus` and `prometheus-community` access to a publicly trusted code-signing service.
* Keep the decision to sign with each project's maintainers. Projects that do not want signing are not affected at all.
* Sign **release builds only**. Snapshot, nightly, `main` branch, and pull request builds stay unsigned, so a signature always identifies an artifact the maintainers deliberately released.
* No long-lived signing keys in GitHub secrets: signing is authorized through GitHub Actions OIDC, scoped per repository.
* Low operational overhead for the Prometheus team after the initial setup.

### Audience

Maintainers of Prometheus ecosystem projects that publish binaries, the Prometheus team (who would own the account and access control), and CNCF / Linux Foundation staff (who would provide the legal identity and billing).

## Non-Goals

* Deciding that Prometheus or any other project **must** sign its binaries. There is no ecosystem-wide signing policy in this proposal.
* Changing the release process of projects that do not opt in, including `promu` defaults.
* Container image signing or artifact attestations (cosign / Sigstore, SLSA provenance). These solve a different problem and can be discussed separately.
* Apple code signing and notarization. The same governance model could be reused later, but it is out of scope here.

## How

### Governance

1. The Prometheus team agrees that a shared signing service may exist and who administers it (for example the Steering Committee or a small set of named admins).
2. Each repository opts in by a decision of its own maintainers, recorded by opening an issue or PR against the repository that holds the signing configuration. No ecosystem-wide vote is needed per project.
3. The admins grant the repository access. They can also revoke it, for example if a project becomes unmaintained or misuses the service.

This keeps the ecosystem-level decision small ("the service exists, here is how to get access") and leaves the actual signing decision where the knowledge is: with the project maintainers.

### Service

The preferred option is **Azure Artifact Signing** (formerly Trusted Signing):

* The account, the identity validation, and the billing belong to the **Linux Foundation / CNCF**, which is an eligible organization for Public Trust certificates. The certificate subject would be the validated legal name of that organization.
* Cost is low: the Basic tier is about USD 10 per month and includes 5,000 signatures. Because only releases are signed, a project such as windows_exporter needs four signatures per release (two executables and two MSIs), so even many opted-in projects together stay far below the quota.
* Certificates are short-lived (rotated daily) and keys never leave Microsoft-managed HSMs. There is no PFX file to leak.
* SmartScreen reputation is tied to the validated publisher identity instead of a single certificate, so it carries over across releases and projects.
* It signs everything `signtool` can sign (PE files, MSI, MSIX, scripts) and has an official GitHub Action.

Access control per repository:

* One certificate profile for the ecosystem, or one per project if separate publisher reputation is preferred.
* One Microsoft Entra application with **federated credentials** per opted-in repository, scoped by the GitHub OIDC subject (for example `repo:prometheus-community/windows_exporter:environment:release`). The application holds the "Trusted Signing Certificate Profile Signer" role on the profile.
* Projects use a GitHub Actions environment (for example `release`) restricted to release tags (for example `v*`) with tag protection. The federated credential only trusts that environment, so snapshot builds, branch pushes, and pull requests cannot obtain a signature even if a workflow tries.

Usage in a project's release job is then a single step, without secrets beyond non-sensitive IDs:

```yaml
environment: release # only available for release tags
permissions:
  id-token: write
  contents: read
steps:
  - uses: azure/login@v2
    with:
      client-id: ${{ vars.SIGNING_CLIENT_ID }}
      tenant-id: ${{ vars.SIGNING_TENANT_ID }}
      subscription-id: ${{ vars.SIGNING_SUBSCRIPTION_ID }}
  - uses: azure/artifact-signing-action@v2
    with:
      endpoint: https://weu.codesigning.azure.net/
      signing-account-name: prometheus
      certificate-profile-name: prometheus
      files-folder: output
      files-folder-filter: exe,msi
      file-digest: SHA256
      timestamp-rfc3161: http://timestamp.acs.microsoft.com
      timestamp-digest: SHA256
```

A shared reusable workflow could later wrap this, but it is not required for a first version.

### Testing and rollout

windows_exporter would be the first adopter, replacing its self-signed certificate. Verification is `Get-AuthenticodeSignature` / `signtool verify /pa` on the released artifacts.

### Open questions

* Does the CNCF / Linux Foundation already hold, or want to host, an Artifact Signing account (or another publicly trusted signing service) for its projects? This proposal would be the basis for a CNCF service desk request.
* Which publisher name appears on the certificate (for example "The Linux Foundation" or "Cloud Native Computing Foundation"), and is that acceptable to the projects?
* One shared certificate profile or one per project? A shared profile builds reputation faster; separate profiles isolate a compromised or misbehaving project.
* Who in the Prometheus team administers the account and grants access?

## Alternatives

1. **Status quo (each project on its own).** Projects keep self-signed certificates or no signatures. This does not solve the identity problem described above.
2. **SignPath Foundation (free for open source).** Signing is free and also uses a hosted HSM. Its manual approval per signing request fits the release-only model. However, the certificate is issued to "SignPath Foundation" as publisher, every release needs that manual approval in SignPath, each project must publish a code signing policy page and define author / reviewer / approver roles, and SignPath decides on acceptance. This is a reasonable fallback if the CNCF cannot provide an account, and the same opt-in governance model applies.
3. **A classic OV or EV certificate bought by the CNCF.** Keys must live on a hardware token or a cloud HSM, renewals are manual, and costs are higher (several hundred USD per year) than Artifact Signing, with no advantage for SmartScreen since EV certificates no longer grant instant reputation.
4. **An ecosystem-wide signing policy.** Deciding that all Prometheus binaries must be signed would require a much larger discussion (supported platforms, release tooling, `promu` changes). This proposal intentionally avoids it; such a policy could still be proposed later on top of the service.

## Action Plan

* [ ] Agree on this proposal and on the admins of the signing service.
* [ ] Open a CNCF service desk request for an Artifact Signing account (or equivalent) owned by the CNCF / Linux Foundation.
* [ ] Create the certificate profile and the Entra application with federated credentials for the first adopter.
* [ ] Document how a project opts in (issue template plus workflow snippet).
* [ ] Migrate windows_exporter from its self-signed certificate and limit its signing to release builds.
