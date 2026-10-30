## Opt-in Windows Authenticode code signing for Prometheus ecosystem projects via SignPath Foundation

* **Owners:**
  * [@jkroepke](https://github.com/jkroepke)

* **Implementation Status:** Not implemented

* **Related Issues and PRs:**
  * [windows_exporter README: binaries signed with a self-signed certificate](https://github.com/prometheus-community/windows_exporter/blob/main/README.md)
  * [Discussion in the CNCF TAG Security and Compliance Slack channel](https://cloud-native.slack.com/archives/C08JZ9YLAA3/p1791834990035849)

* **Other docs or links:**
  * [SignPath Foundation](https://signpath.org/)
  * [SignPath Foundation conditions for open source projects](https://signpath.org/terms)
  * [CNCF Software Supply Chain Best Practices](https://contribute.cncf.io/projects/best-practices/security/supply-chain/supply-chain-best-practices/)
  * [SignPath GitHub Action `signpath/github-action-submit-signing-request`](https://github.com/signpath/github-action-submit-signing-request)
  * Precedent in a CNCF project: [telepresenceio/telepresence](https://github.com/telepresenceio/telepresence) ([code signing policy](https://github.com/telepresenceio/telepresence#code-signing-policy), [signing workflow](https://github.com/telepresenceio/telepresence/blob/release/v2/.github/workflows/sign-windows.yaml), [artifact configuration](https://github.com/telepresenceio/telepresence/tree/release/v2/build-aux/signpath))

> TL;DR: This proposal allows repositories in the `prometheus` and `prometheus-community` GitHub organizations to sign their **Windows** release artifacts (`.exe` binaries and `.msi` installers) with a publicly trusted **Authenticode** certificate from the [SignPath Foundation](https://signpath.org/), which offers free code signing to open source projects. The CNCF project [Telepresence](https://github.com/telepresenceio/telepresence) already does this. Using it is **opt-in per repository**: the maintainers of each project decide on their own whether and what they sign. Only release builds are signed, and every release needs a manual approval by the project's maintainers. Linux binaries, macOS binaries, and container images are out of scope. This proposal deliberately does **not** decide whether Prometheus binaries should be signed.

## Why

Some Prometheus ecosystem projects are mainly or exclusively consumed on platforms where code signing matters to users. The most visible example is [windows_exporter](https://github.com/prometheus-community/windows_exporter), which ships `.exe` binaries and `.msi` installers for `amd64` and `arm64`.

Today a project that wants publicly trusted signatures has no path inside the Prometheus organizations. A publicly trusted code-signing certificate requires a validated legal identity, and neither `prometheus` nor `prometheus-community` is a legal entity. Individual maintainers can usually not fill that role either: services like Azure Artifact Signing only validate individual developers in a few countries, and a certificate issued to a maintainer personally would publish their legal name and location as the publisher of a community project.

The SignPath Foundation solves exactly this problem for open source projects: it is the legal identity on the certificate, it verifies that each signed binary was built from the project's public repository, and it keeps the private key in an HSM. It is free for open source projects and does not need a contract, an account, or billing on the side of the CNCF / Linux Foundation or the Prometheus team.

### Pitfalls of the current solution

* windows_exporter signs its binaries and installers with a **self-signed certificate** and asks users to import it into their trusted root store. That is a poor security practice to recommend, and it does not help with Microsoft Defender SmartScreen or with enterprise allow-listing.
* Unsigned or self-signed binaries are blocked or flagged by SmartScreen, Smart App Control, and many enterprise policies (AppLocker / App Control for Business). Users then run ad-hoc workarounds or rebuild from source.
* The signing key of windows_exporter is a long-lived PFX file stored as a GitHub Actions secret. Anyone who obtains it can sign arbitrary binaries, and a leak cannot be scoped or revoked in a fine-grained way.
* Each project that wants signing would have to solve identity validation, billing, and key custody alone.

## Goals

* Give interested projects in `prometheus` and `prometheus-community` a documented path to publicly trusted Windows Authenticode signatures for their Windows release artifacts (`.exe` binaries and `.msi` installers).
* Keep the decision to sign with each project's maintainers. Projects that do not want signing are not affected at all.
* Sign **release builds only**. Snapshot, nightly, `main` branch, and pull request builds stay unsigned, so a signature always identifies an artifact the maintainers deliberately released.
* No signing keys in GitHub secrets: the private key stays in SignPath's HSM, and a leaked CI token alone cannot produce a release signature without a manual approval.
* No cost and no operational overhead for the Prometheus team or the CNCF.

### Audience

Maintainers of Prometheus ecosystem projects that publish Windows binaries, and the Prometheus team, who would agree that projects may present themselves as signed by the SignPath Foundation.

## Non-Goals

* Deciding that Prometheus or any other project **must** sign its binaries. There is no ecosystem-wide signing policy in this proposal.
* Changing the release process of projects that do not opt in, including `promu` defaults.
* Signing Linux or other non-Windows binaries. Linux has no OS-level equivalent of Authenticode, and the service only produces Authenticode signatures here.
* Container image signing or artifact attestations (cosign / Sigstore, SLSA provenance). These solve a different problem and can be discussed separately.
* Apple code signing and notarization. The same governance model could be reused later, but it is out of scope here.

## How

### SignPath Foundation

[SignPath Foundation](https://signpath.org/) is a non-profit that issues a code-signing certificate in its own name for open source projects and runs the signing on [SignPath.io](https://about.signpath.io/) for free. The certificate subject (publisher) is **SignPath Foundation**. In return the Foundation enforces a set of [conditions](https://signpath.org/terms). The ones relevant here are:

* **Eligibility.** OSI-approved license without commercial dual licensing, no proprietary components, actively maintained, already released in the form that should be signed, and functionality described on the download page. Prometheus ecosystem projects are Apache-2.0 licensed and meet this.
* **Sign your own projects and binaries only.** The team that signs must be the team that maintains the repository, and only artifacts built from the project's own source are signed. Unsigned upstream binaries may be bundled inside a signed installer.
* **Verified origin.** SignPath verifies for every signing request that the artifact is an automated build of the source code in the project's repository (through its GitHub integration, using artifacts built on GitHub-hosted runners).
* **Manual approval of every release.** Each signing request under the release policy must be approved in the SignPath portal by a project member with the *approver* role.
* **Team roles and MFA.** The project defines *authors* (committers), *reviewers* (every outside contribution is reviewed), and *approvers*. All of them use multi-factor authentication on GitHub and SignPath.
* **Code signing policy page.** The project's home page and release page contain a "Code signing policy" section with the sentence "Free code signing provided by SignPath.io, certificate by SignPath Foundation", the team roles, and a privacy statement.
* **File metadata.** Signed binaries carry the project name as product name and the release version as product version, enforced by the SignPath artifact configuration.
* **No hacking tools, no undisclosed data collection, and an uninstall path** for anything with an installer.

SignPath Foundation reviews every project application on its own and can suspend a project or revoke the certificate if a project violates these rules.

### Precedent: Telepresence (CNCF)

[Telepresence](https://github.com/telepresenceio/telepresence) is a CNCF project that signs its Windows release artifacts through SignPath Foundation since v2.32.0. Its integration is small and can be copied almost as is:

* A reusable workflow, [`sign-windows.yaml`](https://github.com/telepresenceio/telepresence/blob/release/v2/.github/workflows/sign-windows.yaml), runs after the release is published. It downloads the unsigned `.exe` and `.msi` assets, uploads them as one GitHub Actions artifact, and submits it with [`signpath/github-action-submit-signing-request`](https://github.com/signpath/github-action-submit-signing-request). The job waits (up to just under the six hour job limit) until an approver approves the request in the SignPath portal, then verifies the signatures and replaces the release assets with the signed ones.
* The job runs in a protected GitHub environment (`windows-signing`) that holds the SignPath API token. It is skipped entirely until `vars.SIGNPATH_ORGANIZATION_ID` is set, so the workflow can be merged before the SignPath project exists.
* Two signing policies are used: `release-signing` (manual approval, SignPath Foundation certificate) for releases, and `test-signing` (no approval, test certificate) to exercise the pipeline against pre-release tags.
* The [artifact configuration](https://github.com/telepresenceio/telepresence/blob/release/v2/build-aux/signpath/core.xml) that lives in the SignPath portal is mirrored in the repository, so changes to what gets signed are reviewed like code. It signs both standalone executables and both MSIs in one request, including a deep signature of the executables embedded in each MSI.
* A `verify-signatures` script fails the job if any `.exe` or `.msi` (also inside `.zip` files and inside the MSIs) lacks a valid, timestamped signature, and the release tests check `Get-AuthenticodeSignature` on the downloaded binary.
* The [code signing policy](https://github.com/telepresenceio/telepresence#code-signing-policy) is a short section in the README and the installation docs that links the GitHub teams for committers / reviewers and approvers, and the release notes link to it.

### Governance

1. The Prometheus team agrees that projects in `prometheus` and `prometheus-community` may sign their Windows release artifacts with a SignPath Foundation certificate, and therefore name SignPath Foundation as publisher of those artifacts.
2. Each repository opts in by a decision of its own maintainers. The maintainers apply to SignPath Foundation for their project, add the code signing policy section, and integrate the signing workflow. No ecosystem-wide vote is needed per project.
3. The roles required by SignPath map to existing GitHub teams: the repository's maintainers / write team are authors and reviewers, and the approvers are a subset of the maintainers chosen by the project. Branch protection already enforces review of outside contributions.
4. The Prometheus team (for example the GitHub admins of the two organizations) keeps the ability to remove a project's signing integration, for example if a project becomes unmaintained, and is informed when a project opts in.

This keeps the ecosystem-level decision small ("projects may use SignPath Foundation, here is how") and leaves the actual signing decision where the knowledge is: with the project maintainers.

### Setup per project

1. Apply at [signpath.org/apply](https://signpath.org/apply). After acceptance, SignPath creates an organization and project on SignPath.io with a `test-signing` and a `release-signing` policy.
2. Connect the GitHub repository as a trusted build system in SignPath, define the artifact configuration (product name and version restrictions), and add the approvers.
3. Store the SignPath CI user API token as a secret of a protected GitHub environment that is only available for release tags (for example `v*` with tag protection), and the organization ID and project slug as variables.
4. Add a "Code signing policy" section to the README and link it from the release notes.

Usage in a project's release workflow is then one extra job, modeled on Telepresence:

```yaml
sign-windows:
  needs: release
  runs-on: windows-latest
  environment: windows-signing # only available for release tags
  permissions:
    contents: write
    actions: read
  steps:
    - name: Download unsigned Windows artifacts
      run: gh release download ${{ github.ref_name }} -p '*.exe' -p '*.msi' -D unsigned
      env:
        GH_TOKEN: ${{ github.token }}
    - id: unsigned
      uses: actions/upload-artifact@v7
      with:
        name: unsigned
        path: unsigned
    - uses: signpath/github-action-submit-signing-request@v3
      with:
        api-token: ${{ secrets.SIGNPATH_API_TOKEN }}
        organization-id: ${{ vars.SIGNPATH_ORGANIZATION_ID }}
        project-slug: ${{ vars.SIGNPATH_PROJECT_SLUG }}
        signing-policy-slug: release-signing
        artifact-configuration-slug: release
        github-artifact-id: ${{ steps.unsigned.outputs.artifact-id }}
        wait-for-completion-timeout-in-seconds: "21000" # manual approval
        output-artifact-directory: signed
        parameters: |
          version: ${{ toJSON(github.ref_name) }}
    - name: Replace release assets with the signed ones
      run: gh release upload ${{ github.ref_name }} signed/* --clobber
      env:
        GH_TOKEN: ${{ github.token }}
```

A shared reusable workflow could later wrap this, but it is not required for a first version.

### Testing and rollout

windows_exporter would be the first adopter, replacing its self-signed certificate. The pipeline is first exercised with the `test-signing` policy against a pre-release tag, then switched to `release-signing`. Verification is `Get-AuthenticodeSignature` / `signtool verify /pa` on the released artifacts, ideally as a CI step like Telepresence's `verify-signatures`.

### Relation to CNCF supply chain best practices

The [CNCF Software Supply Chain Best Practices](https://contribute.cncf.io/projects/best-practices/security/supply-chain/supply-chain-best-practices/) do not restrict which signing provider a project uses. They recommend signing release artifacts so they can be verified independently, keeping signing keys out of reach of the build (hardware-backed key management), and separating duties so no single identity can push a change all the way to a signed release. The SignPath setup follows these points: the key never leaves SignPath's HSM, the origin of every signed artifact is verified against the repository, and the manual approval separates the build from the release decision. Authenticode signing complements, and does not replace, Sigstore / SLSA provenance, which remain out of scope here.

### Trade-offs

* **Publisher name.** Windows shows "SignPath Foundation" as publisher, not "Prometheus" or "The Linux Foundation". The code signing policy page explains the relationship, and enterprise allow-listing rules can combine the publisher with the product name that SignPath enforces in the file metadata.
* **Manual approval per release.** A release is only signed after an approver acts in the SignPath portal. For projects that release a few times per month this is acceptable, and it is also a security property: a compromised CI token or workflow cannot obtain a signature on its own.
* **External dependency.** SignPath Foundation decides on acceptance and can suspend a project. If it ever stops serving a project, that project falls back to unsigned releases; nothing else in the ecosystem depends on it.

### Open questions

* Is the Prometheus team fine with "SignPath Foundation" appearing as publisher on Windows artifacts of Prometheus ecosystem projects?
* Should all opted-in projects share one SignPath organization owned by the Prometheus GitHub admins, or does each project apply and hold its own? Telepresence holds its own; a shared organization would give the Prometheus team a single place to revoke access.
* Should a shared reusable workflow (for example in `prometheus/promci`) provide the signing job once a second project opts in?

## Alternatives

1. **Status quo (each project on its own).** Projects keep self-signed certificates or no signatures. This does not solve the identity problem described above.
2. **Azure Artifact Signing through a CNCF / Linux Foundation account.** An earlier version of this proposal asked the CNCF / Linux Foundation for an Artifact Signing account in its Azure tenant. That depends on the CNCF / Linux Foundation providing and paying for the subscription and on someone administering access per repository, while SignPath Foundation needs none of that and is already used by a CNCF project. This option is not pursued.
3. **A classic OV or EV certificate bought by the CNCF.** Keys must live on a hardware token or a cloud HSM, renewals are manual, and costs are several hundred USD per year, with no advantage for SmartScreen since EV certificates no longer grant instant reputation.
4. **An ecosystem-wide signing policy.** Deciding that all Prometheus binaries must be signed would require a much larger discussion (supported platforms, release tooling, `promu` changes). This proposal intentionally avoids it; such a policy could still be proposed later on top of this one.

## Action Plan

* [ ] Agree on this proposal, including SignPath Foundation as publisher.
* [ ] Decide whether opted-in projects share one SignPath organization or apply individually.
* [ ] Apply to SignPath Foundation for windows_exporter.
* [ ] Add the code signing policy section and the signing workflow to windows_exporter, test it with `test-signing`, then sign a release with `release-signing` and remove the self-signed certificate.
* [ ] Document how other projects opt in (a short guide plus the workflow snippet, or a reusable workflow).
