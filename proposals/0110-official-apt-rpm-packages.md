## Official apt and rpm repositories for Prometheus

* **Owners:**
  * Conall O'Brien (@conallob)

* **Implementation Status:** Not implemented

* **Related Issues and PRs:**
  * https://github.com/prometheus/proposals/pull/110
  * https://github.com/prometheus/promu/issues/93
  * Whether to move Prometheus from promu to goreleaser is a separate, undecided question: [Announcing our intention to move to goreleaser](https://groups.google.com/g/prometheus-developers/c/Akx0WcSqQqM/m/EZOjvvhyAQAJ) (prometheus-developers, June 2021, retracted the next day pending discussion)

* **Other docs or links:**
  * [Debian package tracker for prometheus](https://tracker.debian.org/pkg/prometheus)
  * [pkgs.k8s.io announcement](https://kubernetes.io/blog/2023/08/15/pkgs-k8s-io-introduction/)
  * [nfpm](https://nfpm.goreleaser.com/)

> TL;DR: Prometheus should ship official, signed apt and dnf repositories, built from .deb and .rpm files that each component creates with nfpm in its own release, using shared defaults so per-repo work stays minimal. A central workflow turns each release into signed indexes on a prometheus.io subdomain, and package URLs redirect to the GitHub release assets, so the project hosts no large files. Adoption is opt-in and phased: node_exporter first, blackbox_exporter next, prometheus and alertmanager last. Cloudflare R2, packagecloud, Cloudsmith and OpenBuildService are compared as alternatives. **Decision asked of reviewers:** whether to proceed with a node_exporter proof of concept on this design. Key ownership, the RPM signing option and the hosting platform are the open items.

## Why

Users who want a current Prometheus on Debian-family or Fedora-family Linux have no official package source. Per the Debian package tracker, stable ships 2.53.3 and testing ships 3.5.3, while the tracker lists 3.15.1 as the new upstream. The community alternatives are third-party and thin: [lest/prometheus-rpm](https://github.com/lest/prometheus-rpm/issues) has open issues titled "Is this project alive?" (Nov 2025) and "Prometheus 3" (Mar 2025), and [jtyr/prometheus-deb](https://github.com/jtyr/prometheus-deb) covers only Prometheus, Alertmanager and Pushgateway. Both publish through packagecloud. The [Prometheus download page already reads release assets from GitHub](https://github.com/prometheus/docs), so the missing pieces are packaging, signing and a repository index, not a new build system.

It is also common for enterprises with a large installed base to build a private binary package for their own fleet and never contribute it back upstream. The same packaging work is then repeated privately across many organisations, and none of it benefits other users.

### Pitfalls of the current solution

* No official, signed, upstream-maintained apt or dnf repository exists. I found no authoritative prior proposal thread, though my search coverage is limited.
* Third-party repositories depend on individual volunteers and are stalled, as above.
* Distro packages lag upstream, and the promu thread notes distro packages built against mismatched dependency versions, such as a wrong procfs version in Debian's node_exporter.
* [promu issue 93](https://github.com/prometheus/promu/issues/93), "Support building Linux distribution packages", is years old. Its current status is not confirmed.
* Attaching packages to releases without a repository leaves users on old versions, a concern raised in that thread.

## Goals

Goals and use cases for the solution as proposed in [How](#how):

* Give users one official, signed apt and dnf source for Prometheus project binaries, for amd64 and arm64, with other architectures following each component's release builds.
* Keep each component's packaging next to its own release process, owned by that component's maintainers, and build packages there rather than rebuilding them centrally.
* Keep downstream work minimal: about 50 exporter repos build on promu, so shared defaults cover everything that does not differ per component.
* Publish new releases to the repos automatically.
* Keep hosting cost and operational load low, so a few volunteers can run it.
* Make the repos discoverable from prometheus.io and auditable, so any package traces back to a release with verified checksums.
* Make install, upgrade and remove behave cleanly: service user created, config preserved on upgrade, service run by systemd, and package names that do not collide with distro packages.
* Hold the signing key with more than one person, with a documented rotation plan.

Nice to have, not required for v1:

* One repo for all components, as [Grafana's apt and rpm hosts](https://forger.sitiv.fr/apitech/grafana/commit/f1f401147f5ea3bf71099b6358a5ee81f7c68f6a) do.
* Stability decided per binary by its own semver: releases with a pre-release suffix stay out of the stable index, and an optional repo per major version lets users pin to one.

### Audience

Prometheus users on Debian-family and Fedora-family Linux, maintainers of Prometheus components and exporters, and whoever operates the project's DNS and hosting accounts.

## Non-Goals

* Replacing Debian, Fedora or other distro packages, or seeking distro inclusion.
* Forcing any repo to migrate from promu to goreleaser, or deciding whether Prometheus should migrate. That question is orthogonal to this proposal.
* Other formats (apk, for example) or non-Linux platforms.
* Non-systemd init systems, and distribution variants beyond Debian-family and Fedora-family.
* Building from source in the repository. Packages are built in each component's own release.
* Packaging prometheus and alertmanager in the first phases. The design must not block adding them later.

## How

### Proposed design

Each component builds its own .deb and .rpm with nfpm in its release job and attaches them to its GitHub release. A central publishing repo regenerates signed apt and dnf indexes when a release lands. The indexes are served as static files from a prometheus.io subdomain, and package URLs redirect to the GitHub release assets, so the project never serves the large binaries itself.

**Prior discussion.** promu issue 93 records the constraints this design has to meet. About 50 exporter repos build downstream of promu, so packaging needs the minimum per-repo work. Maintainers raised doubts about packaging variation across distributions, the upkeep of a repository, and download-only packages leaving users on old versions. One maintainer said goreleaser is welcome in principle, with gaps around Makefile workflows and the CGO that node_exporter uses. The design answers these by running a real repository, limiting scope to systemd-based Debian-family and Fedora-family distributions, using nfpm without requiring a goreleaser migration (goreleaser users are supported as well), and generating packages from shared defaults.

**Packaging in component repos.** Component-specific packaging files, such as the systemd unit and default flags, live in the component repo next to its other packaging settings, starting with node_exporter. A shared reusable workflow builds the packages and attaches them to the release. Shared defaults cover the common parts, so a component adds only what differs and opts in with a one-line setting. Opt-in is by convention: a release that contains .deb and .rpm assets is included, so no central registry is needed. Whether this is a promu step (nfpm is a Go library) or a shared workflow is an open question.

**Independent of the release tool.** The publishing side only requires that a release has .deb and .rpm assets next to its tarballs and checksums. It does not care how they were created. A component on promu can build them with nfpm in a promu step or a shared workflow, and a component on goreleaser can use goreleaser's built-in nfpm support. Both release processes are supported, so this proposal is orthogonal to the open question of [migrating Prometheus to goreleaser](https://groups.google.com/g/prometheus-developers/c/Akx0WcSqQqM/m/EZOjvvhyAQAJ): it neither depends on that migration nor blocks it, and a component can change release tools later without touching the repositories. The asset naming and metadata conventions that the publishing job relies on are the contract, and they are documented as part of the shared defaults.

**Publishing repo.** A dispatch event carries component and version. The job downloads the release assets, verifies the sha256 checksums, regenerates metadata with `apt-ftparchive` and `createrepo_c`, signs it, and publishes the index. It is idempotent, keyed on component and version, and reads each asset once to compute sizes and hashes. aptly is not used because it keeps a local database, which fits stateless CI poorly. A pilot home under `prometheus-community` is suggested.

**Trigger.** The component's release workflow sends a `repository_dispatch` event after assets are uploaded, not on tag creation. Cross-repo dispatch [needs a credential with write access to the receiving repo](https://til.jakelazaroff.com/github/trigger-a-workflow-run-in-another-repo), so use a GitHub App token rather than a personal token. A slow scheduled reconcile job catches missed events.

**Hosting and redirects.** The index is small and static, and lives on a subdomain such as apt.prometheus.io. Where it is served from depends on the platform decision below. prometheus.io is [deployed through Netlify](https://github.com/prometheus/docs), and I was told by a core contributor that its DNS is on Cloudflare (I have not verified this). That leaves two ways to map `/pool/<component>/<file>` to the release asset URL:

* **Netlify:** a generated `_redirects` file or a small edge function. The size limits of `_redirects` are not verified.
* **Cloudflare:** a redirect rule or a small Worker. If the index path carries the release tag and organisation, for example `/pool/<org>/<component>/<tag>/<file>`, a single wildcard Single Redirect rule could map it to `https://github.com/<org>/<component>/releases/download/<tag>/<file>`. The free plan's [rule limits](https://developers.cloudflare.com/rules/url-forwarding/) (10 Single Redirects, wildcard supported, regex on higher plans) appear to allow this, but the exact substitution syntax must be tested. A Worker is the fallback, and the Workers free tier has request and CPU limits to check against expected traffic.

[apt follows redirects by default](https://www.mankier.com/1/apt-transport-http), but hosts that set `Acquire::http::AllowRedirect` to false would break. dnf behaviour is not verified.

**Signing.** apt needs only signed index files. dnf conventionally also checks per-package signatures, which conflicts with redirecting to release assets that no central key has signed. The options are:

* `repo_gpgcheck=1` with `gpgcheck=0` for these repos (weaker, unconventional).
* Sign RPMs in each component's CI with nfpm (the key sits in every repo's CI).
* Re-sign centrally and host the RPMs outside GitHub (loses the redirect, and is what the R2 alternative below provides).

Use one dedicated repo-signing key with tightly scoped Actions access, several holders, a written rotation plan, and a plan for the case where a holder disappears.

**Naming and policy.** Debian and Fedora ship their own prometheus and node exporter packages, so these packages need a naming and Conflicts/Replaces/Provides policy. A shared packaging policy covers the service user, unit hardening, default flags location (`/etc/default/` on Debian-family, `/etc/sysconfig/` on RPM-family), `config|noreplace` handling and upgrade behaviour.

### Hosting platform

The platform choice is the least settled part of this proposal. The comparison below uses the same requirements for every option, and the alternatives follow in detail. My current view is the proposed design first, with Cloudflare R2 as the planned fallback if the proof of concept shows that the redirect or RPM signing does not work.

| Requirement | Static index + GitHub redirect (proposed) | Cloudflare R2 + static serving | OBS | packagecloud | Cloudsmith | Release assets only |
|---|---|---|---|---|---|---|
| Signed apt and dnf repos | Yes; RPM signing open | Yes; central signing | Yes; OBS signs (not verified) | Signing listed for Enterprise plan; open-source plan not verified | Signing features listed | No repo |
| Component-owned packaging | Yes, nfpm with shared defaults | Yes | Specs and artifacts pushed | Yes, push by CLI or API | Yes, push by CLI or API | Yes |
| Automatic publication | Dispatch plus reconcile | Same | Release tooling pushes | CI push | CI push | Release upload only |
| Bandwidth cost | Index only; GitHub serves binaries | Zero egress; storage beyond 10 GB-month is billed | OBS host, or own bucket | Free for Open Source program by request; limits not published | Free tier, at least 200GB delivery | GitHub |
| Shared key custody | Project runs it | Project runs it | OBS-managed key | Not verified | Not verified | None |
| Operational load | Workflow plus redirect | Workflow plus bucket and custom domain | Low after setup; learning curve | Low | Low | Lowest |

### How we test and verify

The proof of concept is a pure pipeline test: build, sign, index, redirect, install. Acceptance checks, on both a Debian-family and a Fedora-family container:

* install, upgrade and remove;
* config survives upgrade;
* the service runs as the unprivileged user;
* the redirect is followed by both apt and dnf;
* for blackbox_exporter, an ICMP probe works.

### Migration and delivery phases

Adoption is opt-in, so no user or repo is migrated without choosing to be.

1. Proof of concept: node_exporter, end to end.
2. Canary: blackbox_exporter, which tests `config|noreplace` handling, reload via SIGHUP, and ICMP probes that need CAP_NET_RAW (to confirm against the repo).
3. Extract the shared workflow, convert two or three more exporters, then open the opt-in to other exporter maintainers with documentation.
4. prometheus and alertmanager last, because they carry the most policy: config layout, data directories, users and upgrade behaviour, and possibly version and channel policy such as LTS lines for the server.

### Open questions

* Who owns the signing key and the subdomain, and who carries the pager? Which Cloudflare (or Netlify) account would host the index or bucket, who pays, and whether CNCF or an existing Prometheus account covers it are not verified.
* Should nfpm packaging be a promu step with shared defaults, or a shared workflow? Either must keep per-repo work minimal.
* Which RPM signing option does the project accept?
* Do apt and dnf both follow the redirect chain to GitHub's asset host? The proof of concept settles this.
* Does the Cloudflare plan in use allow the redirect rule or Worker this design needs, within its limits?
* How much storage would a full R2 copy of all releases need, and does it fit the free tier or require sponsorship? Not estimated yet.
* Would packagecloud grant Prometheus its Free for Open Source program on terms that suit the project (limits, signing, key custody)? The 2021 announcement states none of these, so they need confirming with the vendor.
* Are the exporter repos' CI configurations shared (for example through a CircleCI orb), so the dispatch step needs adding in one place only? This is from memory and unverified.

## Alternatives

Each alternative is a whole candidate solution, compared against the same requirements as the proposed design. Doing nothing is the baseline described in [Why](#why).

### 1. Cloudflare R2 plus static serving

Same build and publish flow as the proposal, but the central job also copies the verified packages into a project-owned R2 bucket, served on a custom domain such as apt.prometheus.io together with the index. [pkgs.k8s.io](https://kubernetes.io/blog/2023/08/15/pkgs-k8s-io-introduction/) follows the same shape on other infrastructure: an S3 bucket behind a CloudFront CDN. The R2 figures below come from Cloudflare's pricing documentation: a free tier of 10 GB-month of storage, 1 million Class A and 10 million Class B operations per month, no egress fees, and $0.015 per GB-month beyond the free storage. The `r2.dev` endpoint is rate limited and not intended for production, so a custom domain is required.

* **Pros**
  * Plain static repo, with no dependence on redirect behaviour.
  * Central RPM signing works, which resolves the signing conflict.
  * No egress charges, and it fits a Cloudflare setup the project may already have for DNS.
  * Mirrors can be added later.
* **Cons**
  * A second copy of every binary beside the GitHub releases, with storage that may exceed the free tier.
  * Needs a bucket owner and credentials to secure, and a Cloudflare account that someone pays for or sponsors.
  * More moving parts than a static index: the bucket, the custom domain and the sync step.

### 2. OpenBuildService (OBS)

Kubernetes builds and publishes its packages through OBS: its release tooling pushes artifacts and package specifications to SUSE's instance, which builds the packages and pushes them to an S3 bucket, per the pkgs.k8s.io announcement. A [Debian wiki excerpt](https://wiki.debian.org/OpenSuseBuildService) says OBS publishes an apt repo per project with signing keys managed by the service (the page itself could not be opened).

* **Pros**
  * Proven by Kubernetes.
  * Builds for several architectures, and signing is handled by the platform.
  * Takes the key off any one person's machine.
* **Cons**
  * OBS is source-package oriented, with a [learning curve for RPM and DEB differences](https://phoenixnap.com/glossary/open-build-service).
  * Packages are rebuilt by OBS rather than being the nfpm artifacts attached to the release, and OBS generates the revision suffix.
  * Kubernetes works with a SUSE sponsorship. Terms for Prometheus on the public instance are not verified.

### 3. packagecloud

A hosted apt and rpm repository service. The existing third-party Prometheus repositories already publish there, so some users have it configured. packagecloud runs a [Free for Open Source program](https://blog.packagecloud.io/packagecloud-loves-oss/) (announced November 2021): open-source organizations and individuals can host packages for free, and the examples it gives are DEB and RPM repositories. To get it, a project starts the 14-day trial and then contacts packagecloud to request the program. The announcement states no eligibility criteria, storage or bandwidth limits, or conditions such as attribution, and it lists GPG signatures only among the Enterprise plan's features, so whether signing is included is unconfirmed. The author expects Prometheus to qualify, but approval is not guaranteed and current terms need to be confirmed with the vendor.

* **Pros**
  * No infrastructure to run, with a CDN and signing features included.
  * Packages push from CI by CLI or API.
  * Familiar to users of the current third-party repos.
* **Cons**
  * A vendor dependency for the project-wide install path. Moving later means changing every user's repo config.
  * The program is granted on request, with no published limits, so quota against Prometheus demand and the terms today are unknown. The announcement is from 2021.
  * Signing availability on the open-source plan and key custody under the hosted model are not verified.

### 4. Cloudsmith

A hosted service with an [open-source hosting policy](https://docs.cloudsmith.com/resources/open-source-hosting-policy) that gives open-source projects at least 50 GB of artifact data and 200 GB of package delivery free, with more available through sponsorship.

* **Pros**
  * No infrastructure to run, with CDN delivery and signing features included.
  * The open-source tier includes access logs and statistics.
  * Packages push from CI by CLI or API.
* **Cons**
  * A vendor dependency for the project-wide install path.
  * Requires attribution as the free host, and its quota against Prometheus demand is unknown.

### 5. Release assets only

Attach the .deb and .rpm files to each GitHub release and publish no repository. Users run `dpkg -i` or `dnf install <url>`.

* **Pros**
  * No infrastructure and no key custody problem.
  * Works as soon as one component adopts nfpm, and is the first step of the proposed design anyway.
* **Cons**
  * No automatic upgrades, so users stay on old versions and miss security fixes, a concern raised in the promu thread.
  * Users must fetch and trust a key by hand.
  * Does not fix discoverability.

## Action Plan

* [ ] Agree on the owner of the signing key, the subdomain and the hosting account.
* [ ] node_exporter proof of concept: nfpm config and systemd unit in the repo, packages attached to the release.
* [ ] Publishing repo under `prometheus-community`: dispatch receiver, checksum verification, index generation, signing.
* [ ] Test that apt and dnf follow the redirect, and decide the RPM signing option. If either fails, switch to the R2 design.
* [ ] blackbox_exporter canary, covering config handling, reload and CAP_NET_RAW.
* [ ] Extract the shared workflow and defaults, and convert two or three more exporters.
* [ ] Document the opt-in for exporter maintainers and link the repos from prometheus.io.
* [ ] Settle the packaging policy for prometheus and alertmanager, then enable them.
