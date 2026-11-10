## Establishing Prometheus Special Interest Groups

* **Owners:**
  * Arthur Sens [@ArthurSens](https://github.com/ArthurSens)

* **Implementation Status:** `Not implemented`

* **Other docs or links:**
  * [Prometheus governance](https://prometheus.io/governance/)
  * [Prometheus contributor roles](https://github.com/prometheus/governance/blob/main/ROLES.md)
  * [Kubernetes community governance](https://github.com/kubernetes/community/blob/master/governance.md)
  * [OpenTelemetry Technical Committee charter](https://github.com/open-telemetry/community/blob/main/tech-committee-charter.md)
  * [CNCF Technical Advisory Groups](https://contribute.cncf.io/community/tags/)

> TL;DR: Establish a process for creating Special Interest Groups (SIGs) with authority to make decisions within an approved scope. Each SIG has a public charter, at least two leads, and a supporting Steering Committee liaison. SIGs coordinate work across their assigned repositories and areas, while repository maintainers retain responsibility for their implementations. The Steering Committee approves SIG creation and scope changes, supports their success, and resolves escalations.

## Why

Prometheus has groups of contributors who organize around particular repositories, projects, and shared concerns. These groups form organically and hold much of the expertise needed to move their work forward. As the community grows, they need a recognized scope and clear authority to make decisions together.

The Steering Committee stewards the project's direction and governance. It should enable groups to make decisions using their expertise while keeping the broader community aligned. Routing routine technical and organizational decisions through the Steering Committee would make the committee a bottleneck and move decisions away from the people doing the work.

The existing contributor ladder already gives maintainers responsibility for strategy and policy within their repository or part of the codebase. This proposal builds on that authority by recognizing groups that coordinate shared concerns across repositories or other areas of the project.

### Pitfalls of the current solution

* **Unclear decision boundaries.** Contributors sometimes seek technical decisions from the Steering Committee even when the relevant expertise sits with a project's maintainers. A recognized group and scope would help clarify where those discussions belong.
* **Shared concerns lack a recognized owner.** For example, a group focused on exporters or SDKs could develop expectations and processes for its area, including how to evaluate and support prospective donations. The Steering Committee does not necessarily have the expertise to perform those assessments itself.
* **Repository work can grow without sufficient alignment.** Related repositories can be created without a shared understanding of their purposes or how they fit together. A SIG could provide a forum for discussing direction and coordinating related efforts.

These examples motivate delegation. The donation process and the creation of any particular SIG are separate decisions.

## Goals

* Define a process for proposing, reviewing, and recognizing SIGs.
* Give recognized groups of people authority to make decisions within an explicit scope.
* Enable experimentation and coordinated initiatives within that scope.
* Make responsibilities and communication channels discoverable to the whole community.

### Audience

Prometheus Members, maintainers, Steering Committee members, and anyone interested in participating in a SIG.

## Non-Goals

* Create an initial set of SIGs or assign existing repositories to them.
* Introduce a new level in the contributor ladder.
* Define a general policy for inactive SIGs.
* Implement automation or prescribe its technical design. Codifying this proposal is deferred until it is accepted.

## How

### Purpose and authority

A SIG is a recognized group responsible for a defined area of Prometheus. Its scope may cover related repositories, a shared technical concern, or a project function. The charter establishes the boundaries of its authority.

Every recognized SIG receives the same baseline authority within its approved scope: it can set shared direction, establish shared practices, organize initiatives, and experiment with ways to improve its area. It exercises this authority within project-wide governance and policies, without seeking Steering Committee approval for each decision.

SIG leads organize the group for success and work closely with the maintainers of its assigned repositories. They help contributors align on shared concerns and direction. Repository maintainers retain responsibility for implementation decisions in the repositories or parts of the codebase they maintain.

Leads and maintainers should work through disagreements together. When they cannot reach agreement, they may escalate to the Steering Committee. The same applies to unresolved disagreements between SIGs. Groups that can agree directly should do so without requiring the Steering Committee to mediate or approve their collaboration.

### Proposing a SIG

Any [Prometheus Member](https://github.com/prometheus/governance/blob/main/ROLES.md#member) may propose a SIG. The Steering Committee may also identify a need and help assemble a prospective group. Both paths use the same public review and approval process.

The proposal is a pull request to [prometheus/governance](https://github.com/prometheus/governance) adding a SIG charter to the repository's `sigs/` folder. The charter includes:

* The SIG's purpose and the need it addresses.
* Its scope and explicit exclusions.
* Its initial assigned repositories or areas of responsibility.
* At least two initial leads, each of whom is a Prometheus Member.
* Its public communication channels.
* Its supporting Steering Committee liaison.

A documented decision process is not a prerequisite for recognition.

During review, the prospective leads and the Steering Committee consult maintainers of the initially assigned repositories and discuss boundaries with any affected groups. They iterate on the charter in the PR until the responsibilities and delegation are clear. The proposed leads must agree to take on the role, and a Steering Committee member must volunteer to support the SIG as its liaison.

The Steering Committee approves SIG creation under its governance decision process. Merging the approved charter records the SIG's recognition and its delegated scope. Informal groups can continue collaborating before or without seeking recognition.

The Steering Committee may decline a SIG proposal if its purpose or scope is unclear, conflicts with the project's mission or policies, substantially overlaps an existing SIG without a clear need for a separate group, or lacks the leads or Steering Committee liaison required to support it. These are examples rather than an exhaustive list of reasons.

The Steering Committee should explain its reasons in the charter PR and identify whether changes could address its concerns. Where scope overlaps, it may recommend joining an existing SIG or proposing a change to that SIG's scope. Proposers may revise the charter or submit a new proposal when circumstances change.

### Participation and transparency

Anyone can participate in a SIG, including people who are not Prometheus Members. SIG leadership is held by at least two Prometheus Members.

SIG work, meetings, and communication are public by default, following Prometheus's existing approach to public collaboration. Charters, current leads, assigned repositories, communication channels, and significant decisions should be publicly discoverable. Leads are responsible for organizing participation and keeping this information current.

SIGs may develop their own processes as their needs evolve. This proposal does not prescribe a meeting schedule or require a particular decision-making mechanism at creation.

### SIG lead access

SIG leadership is a responsibility separate from the contributor ladder. Leads must be Prometheus Members and receive GitHub Maintain permission on every repository assigned to their SIG while serving in the role.

These permissions support coordination and administration. They do not automatically confer repository Maintainer status or replace the implementation authority of existing maintainers. Repository maintainership follows the existing nomination process, including for SIG leads who also want to become repository Maintainers.

Access granted through SIG leadership follows the SIG's approved repository assignments. When a lead leaves the role or a repository leaves the SIG's scope, the corresponding access granted through that role is removed. Independently held repository maintainership and access continue.

### Steering Committee liaison

Each SIG has an assigned Steering Committee member who supports its success and helps keep its work aligned with the wider Prometheus community. Given the Steering Committee's existing mandate from the project's Members to guide the community's direction, the liaison helps SIG leads bring that direction into their work while preserving the SIG's authority to make decisions within its scope.

The liaison:

* Maintains communication in both directions, bringing the SIG's needs, ideas, and concerns to the Steering Committee and sharing the broader community's direction and priorities with the SIG.
* Works with the leads to keep the SIG's work aligned with its charter and the project's mission, and helps identify opportunities for collaboration with other groups.
* Helps establish the resources and access the SIG needs. A non-exhaustive list includes setup requiring elevated GitHub organization permissions, creating secrets in 1Password, creating Slack channels, scheduling recurring meetings on the Prometheus public calendar, and setting up mailing lists.
* Helps the SIG navigate scope changes and escalations.
* Checks in with the leads about the SIG's health, support needs, and alignment with the wider community.

The leads and liaison agree on the frequency and format of check-ins. When alignment concerns arise, the liaison discusses them with the leads and helps find a shared path forward. Unresolved concerns may be escalated to the Steering Committee.

The liaison supports the SIG and facilitates alignment while preserving its authority to decide within its approved scope. The assignment does not give that individual a veto or make them an approver of routine SIG decisions.

The Steering Committee manages liaison assignments and continuity. If a liaison leaves the committee or can no longer support a SIG, the Steering Committee arranges replacement support and may redistribute assignments as new committee members join. A liaison vacancy does not suspend the SIG's existing authority.

### Scope changes and leadership continuity

A SIG that wants to expand its scope must propose the change through a PR to its charter in the governance repository. The Steering Committee reviews and approves scope changes, consulting affected maintainers and groups. Related infrastructure changes go through the appropriate infrastructure PRs managed by the Steering Committee. The liaison helps coordinate this work.

When leads resign, the Steering Committee is responsible for deciding whether to appoint replacement leads or dissolve the SIG, in consultation with the remaining participants and affected maintainers. The public charter must reflect the outcome. Dissolving a SIG does not itself remove repository maintainers or end maintenance of its repositories.

## Action Plan

* [ ] Reach consensus on this proposal.
* [ ] Add proposing a SIG and eligibility to serve as a SIG lead to Member privileges in `prometheus/governance/ROLES.md`.
* [ ] Describe SIG leadership separately from the contributor ladder in `prometheus/governance/ROLES.md`, including leads' organizing and coordination responsibilities.
* [ ] Clarify maintainer responsibilities in `prometheus/governance/ROLES.md`: maintainers retain implementation authority and work with SIGs on shared direction and practices.
* [ ] Document SIG leads' GitHub Maintain permissions in `prometheus/governance/ROLES.md`, distinguishing these permissions from repository Maintainer status and preserving the existing maintainer nomination process. Update the repository access policy and configuration in `prometheus/org-infra` to grant access to leads across their SIG's assigned repositories and remove role-based access when leadership or repository assignments end, preserving independently held access.
* [ ] Update the Roles, Charter, Decision process, Authority, Facilitation, and Decision-Making sections of `prometheus/governance/GOVERNANCE.md` to explicitly recognize SIGs and their delegated authority. Cover Steering Committee approval of SIG creation and scope changes, direct coordination between groups, and escalation of unresolved disagreements. Clarify which decisions SIGs can make within their charters without a Steering Committee vote.
* [ ] Document liaison assignment, support, community alignment responsibilities, and reassignment in `prometheus/governance/GOVERNANCE.md`, together with the Steering Committee's responsibility to appoint replacement leads or dissolve a SIG when leads resign.
* [ ] Add the SIG creation process and a charter template under `prometheus/governance/sigs/`, covering the required charter fields, consultation with affected maintainers, and Steering Committee volunteer liaison.
* [ ] Provide an index under `prometheus/governance/sigs/` linking approved charters and making current leads, repository assignments, communication channels, and Steering Committee liaisons discoverable.
* [ ] Announce the process so Members can propose SIGs and the Steering Committee can help organize groups where needed.
