# Standardize Prometheus GitHub teams and repository access

* **Owners:** Prometheus Steering Committee
  * [@ArthurSens](https://github.com/ArthurSens)
  * [@bboreham](https://github.com/bboreham)
  * [@bwplotka](https://github.com/bwplotka)
  * [@jan--f](https://github.com/jan--f)
  * [@kakkoyun](https://github.com/kakkoyun)
  * [@SoloJacobs](https://github.com/SoloJacobs)
  * [@superQ](https://github.com/superQ)

* **Implementation Status:**
  * Under Discussion

* **Other docs or links:**
  * https://docs.google.com/document/d/1XOi2e31TcxcnTJXA86VuKQc0UxP-6a_A6h2Q_CcHFfo/edit?tab=t.0#heading=h.qxl59ul17a3w

> TLDR; Standardizing team hierarchy, repository permissions, and MAINTAINERS.md maintenance across the prometheus and prometheus-community GitHub organizations.

This proposal introduces a consistent GitHub team hierarchy for the prometheus and prometheus-community organizations:

```
members
└── <repository>-maintainers
    └── <repository>-admins (only where explicitly needed)
```

Repository permissions increase with each level:

* members: Read
* `<repository>-maintainers`: Maintain
* `<repository>-admins`: Admin, only as a documented exception

Every active, non-fork public repository receives a dedicated Maintainers team. After replacement team access is verified, direct repository permissions are removed from organization members so that human access is inherited through teams. Human organization Owner access is limited to active Steering Committee members and approved temporary exceptions.

## Why

The two Prometheus GitHub organizations have grown organically. Their current team structure reflects that history:

* Repository ownership is not consistently represented by dedicated teams.
* Team names and permission levels are inconsistent.
* Some teams represent contributors, some represent maintainers, and some represent automation, without a shared naming model.
* Similar project teams use a mixture of Write, Maintain, and Admin.
* Some existing teams have members but no repository access.
* Membership onboarding requires adding people to both organizations, but there is no visible Members team representing the contributor ladder.
* Human repository permissions may be granted directly instead of through an auditable team.

## Goals

1. Give every Prometheus Member a clear place in a read-only Members team in both organizations.
2. Give every in-scope repository a dedicated Maintainers team.
3. Establish predictable, repository-specific team names and ownership.
4. Normalize Maintainer access on GitHub's Maintain permission.
5. Reserve Admin access for separately named and justified teams.
6. Automate maintenance of MAINTAINERS.md files in our GitHub repositories.
7. Remove direct repository grants from organization members after replacement team access has been verified.
8. Align human organization Owner access with active Steering Committee membership.

## Non-Goals

1. Change the membership application process.
2. Cover private, archived, or forked repositories.
3. Assign individual people to teams.
4. Infer maintainership where no clear maintainer record exists.
5. Reorganize bot, CI service-account, security-response, or other non-human access.
6. Change the internal ownership model or existing CODEOWNERS file in prometheus/prometheus.
7. Define a place to organize contributor roles

## How

### Members Teams

Each organization receives a visible members team:

* prometheus/members
* prometheus-community/members

Every accepted Prometheus Member becomes a GitHub organization member in
both organizations and belongs to the corresponding members team. Membership should be synchronized across both organizations.

GitHub already gives organization members Read access to public repositories by default. The Members teams therefore organize access rather than unlock otherwise unavailable public content. They provide:

* A visible representation of the Prometheus Member role.
* A consistent onboarding destination in both organizations.
* The root of the human-access team hierarchy.
* A roster that can be audited independently of repository-specific access.

### Repository Teams

Every in-scope repository receives:

* `<repository>-maintainers`
* `<repository>-admins`, only when Admin access is explicitly justified

The Maintainers team is nested below members. Any approved Admins team is nested below its repository's Maintainers team.

Repository teams exist only in the organization that owns the repository. The repository name should be used consistently even where an existing team uses a historical or inconsistent spelling. For example, prometheus-community/smartctl_exporter should use smartctl_exporter-maintainers.

This model creates 82 repository Maintainers teams and two organization-level Members teams. Admin, automation, and service-account teams are additional exceptions rather than part of this count.

### Maintainer and Admin permissions

Maintainer status does not automatically imply GitHub Admin access. Maintainers teams receive Maintain, which supports repository management without granting sensitive or destructive capabilities.

Where Admin access is operationally necessary, it is granted through a separate `<repository>-admins` team:

* Membership is limited to the smallest practical set of people.
* The reason for Admin access is documented.
* The team is nested below the corresponding Maintainers team.

### Team-only access for organization members

Repository permissions for human organization members are granted through teams, not directly to individual accounts. As an explicit exception, the Steering Committee may use its organization-owner authority to grant additional repository permissions directly to an individual.

During migration, existing direct grants may remain temporarily to avoid interrupting project work. After replacement team access is verified:

* Remove direct repository collaborator grants from the organization member.
* Ensure effective access is inherited from members, a repository Maintainers team, or an explicitly approved Admins team.
* Use a team for every future human access grant, including exceptional access.

Organization Owner access is governed separately below. Bot, service-account, and outside-collaborator access is not converted automatically and should be reviewed separately.

### Organization Owner access

Every active member of the Prometheus Steering Committee, as defined by `prometheus/governance`, must have GitHub Owner access to both the `prometheus` and `prometheus-community` organizations.

No other human organization member may hold Owner access except as a temporary exception approved by the Steering Committee. The approval and reason must be documented, and the exception must include an expiration or review condition.

When Owner access is revoked from an organization member, the person remains an organization member and retains legitimate repository access through the teams defined by this proposal. Before revoking Owner access, verify that the person's replacement team access is correct.

### Repository ownership and `MAINTAINERS.MD`

Every in-scope repository has one Maintainers team with Maintain access. Except for prometheus/prometheus, that team becomes the repository-wide fallback owner.

Automation will maintain MAINTAINERS.md files. When a GitHub user is added to or removed from a repository maintainer or admin team, this automation will open a Pull Request to reflect the change.

However, current metadata is incomplete:

* 61 of 82 in-scope repositories have a root MAINTAINERS.md.
* 21 do not have a root MAINTAINERS.md.
* 15 of 82 have a CODEOWNERS file in a GitHub-supported location.

No repository should be migrated by guessing its maintainers. For each of the 21 repositories without a clear MAINTAINERS.md record, the Steering Committee should validate or appoint maintainers.

If the Steering Committee cannot identify maintainers for a repository, record it as unmaintained. Its MAINTAINERS.md file must not name a Maintainers team; instead, it must contain a comment explaining that the repository is unmaintained and looking for contributors.

### Special handling for `prometheus/prometheus`

The prometheus/prometheus repository is organized around multiple components and areas of ownership. This proposal does not attempt to replace or simplify that structure.

The repository still receives a dedicated prometheus-maintainers team, and human repository permissions should still be inherited through teams. However:

* Keep its existing MAINTANIERS.md file unchanged during this migration.
* Do not add prometheus-maintainers as a repository-wide CODEOWNER through this proposal.
* Delegate future changes to its ownership and MAINTAINERS.md model to the repository's existing decision-making process.
* Address the relationship between its repository team and component owners in a separate future proposal.

### Inventory

#### prometheus org (51)

* prometheus/OpenMetrics
* prometheus/alertmanager
* prometheus/blackbox_exporter
* prometheus/busybox
* prometheus/circleci
* prometheus/client_golang
* prometheus/client_java
* prometheus/client_java-benchmarks
* prometheus/client_js
* prometheus/client_model
* prometheus/client_python
* prometheus/client_ruby
* prometheus/client_rust
* prometheus/cloudwatch_exporter
* prometheus/collectd_exporter
* prometheus/common
* prometheus/compliance
* prometheus/consul_exporter
* prometheus/demo-site
* prometheus/docs
* prometheus/exporter-toolkit
* prometheus/golang-builder
* prometheus/governance
* prometheus/graphite_exporter
* prometheus/influxdb_exporter
* prometheus/jmx_exporter
* prometheus/kube-demo-site
* prometheus/memcached_exporter
* prometheus/mysqld_exporter
* prometheus/node_exporter
* prometheus/opentelemetry-collector-bridge
* prometheus/otlptranslator
* prometheus/procfs
* prometheus/prom2json
* prometheus/promci
* prometheus/promci-artifacts
* prometheus/promci-images
* prometheus/promci-setup
* prometheus/prometheus
* prometheus/prometheus-mcp
* prometheus/prometheus-opentelemetry-collector
* prometheus/prometheus_api_client_ruby
* prometheus/promu
* prometheus/proposals
* prometheus/pushgateway
* prometheus/sigv4
* prometheus/snmp_exporter
* prometheus/statsd_exporter
* prometheus/talks
* prometheus/test-infra
* prometheus/test-sd-ownership

#### prometheus-community org (31)

* prometheus-community/PushProx
* prometheus-community/ansible
* prometheus-community/avalanche
* prometheus-community/bind_exporter
* prometheus-community/community
* prometheus-community/ecs_exporter
* prometheus-community/elasticsearch_exporter
* prometheus-community/fortigate_exporter
* prometheus-community/helm-charts
* prometheus-community/highlightjs-promql
* prometheus-community/ipmi_exporter
* prometheus-community/json_exporter
* prometheus-community/monaco-promql
* prometheus-community/node-exporter-textfile-collector-scripts
* prometheus-community/parquet-common
* prometheus-community/parquet-wg
* prometheus-community/pgbouncer_exporter
* prometheus-community/postgres_exporter
* prometheus-community/pro-bing
* prometheus-community/prom-label-proxy
* prometheus-community/prometheus-playground
* prometheus-community/promql-langserver
* prometheus-community/smartctl_exporter
* prometheus-community/snmp
* prometheus-community/stackdriver_exporter
* prometheus-community/sublimelsp-promql
* prometheus-community/systemd_exporter
* prometheus-community/ux-research
* prometheus-community/vscode-promql
* prometheus-community/windows_exporter
* prometheus-community/yet-another-cloudwatch-exporter

### Action Plan

#### Phase 1: Validate inventory and ownership

1. Confirm the repository inventory.
2. Confirm the canonical Maintainers team name for each repository.
3. Compare current access with each repository's MAINTAINERS.md.
4. Resolve the 21 repositories without a clear maintainer record through Steering Committee validation or appointment, or record them as unmaintained when no maintainers can be identified.
5. Identify exceptional Admin and non-human access that must remain separate.
6. Audit human Owner access in both organizations against the active Steering Committee roster.
7. Identify temporary Owner exceptions and confirm that their approval, reason, and expiration or review condition are documented.

#### Phase 2: Establish the hierarchy

1. Create closed members teams in both organizations.
2. Populate them with accepted Prometheus Members.
3. Create or rename a dedicated Maintainers team for every in-scope repository.
4. Nest every Maintainers team below members.
5. Nest any approved repository Admins team below its Maintainers team.
6. Grant Owner access in both organizations to every active Steering Committee member who does not already have it.

#### Phase 3: Apply repository permissions

For one repository at a time:

1. Grant Read to members.
2. Grant Maintain to the repository's Maintainers team.
3. Grant Admin only to an approved Admins team.
4. Verify the effective permissions of representative members at each level.

#### Phase 4: Standardize ownership

1. For every repository except prometheus/prometheus, add the Maintainers team as the repository-wide CODEOWNER and default reviewer.
2. Preserve valid path-specific ownership rules.
3. Confirm that MAINTAINERS.md resolves to a visible team with sufficient explicit repository access.
4. Reconcile team membership with MAINTAINERS.md.
5. Leave the existing prometheus/prometheus MAINTAINERS.md file unchanged.

#### Phase 5: Retire superseded access

1. For each human Owner who is not an active Steering Committee member or an approved temporary exception, verify replacement team access and revoke Owner access while retaining organization membership.
2. Verify that every organization member's effective access is provided by the correct teams.
3. Remove direct repository grants from organization members after replacement team access is verified.
4. Remove duplicate grants from legacy teams only after verification.
5. Remove each repository's MAINTAINERS.md after its Maintainers team has been populated and validated.
6. Retain separately scoped CI, bot, security, and service-account access.
7. Rename or retire empty and superseded human-access teams.
8. Record justified exceptions to the naming and permission model.
9. Audit all 82 repositories against the acceptance criteria.
