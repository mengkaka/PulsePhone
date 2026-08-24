# PulsePhone Optional High-Assurance Validation

> Status: Optional / non-normative for default product delivery
>
> Owner activation required: release owner must explicitly select this profile
>
> Baseline preserved from the pre-2026-07-22 release evidence contract
>
> Current activation and unmet prerequisites are tracked only in
> [`DEFERRED_VALIDATION.md`](DEFERRED_VALIDATION.md). This document preserves the
> profile contract and does not maintain live execution status.

## 1. Purpose

This document preserves the original high-assurance release validation plan. It is
not part of the default PulsePhone product-completion gate and must not block a
usable build on the devices that are actually available to the project.

The profile is appropriate when the release owner needs extended compatibility,
long-duration stability, auditable evidence lineage, or external distribution
assurance beyond the default product-delivery scope.

Selecting this profile is explicit. Absence of its external resources or evidence
is `notTested` for default delivery, not a product failure and not a reason to hide
an otherwise working product build.

## 2. Activation Boundary

The high-assurance profile is active only when all of the following are true:

1. The release owner records an explicit activation decision.
2. The selected candidate and public support scope are identified.
3. The required devices, hosts, credentials, network conditions and evidence
   storage are available for the selected run.
4. `Verification/evidence-policy.v1.json` and the release requirement shards are
   selected as the executable policy for that run.

Without that activation, the policy and its M3 release-flow tasks remain available
tooling and backlog, but they are not dependencies of the default product-delivery
milestone.

## 3. Preserved Stage Matrix

| Stage | Duration | Physical reconnects | Additional rule |
| --- | ---: | ---: | --- |
| Internal Alpha | 30 minutes | 5 | development environment allowed |
| External Beta | 2 hours | 20 | signed, notarized candidate and full matrix |
| Formal Release | 8 hours | 50 | 3 consecutive passing runs |

The original Formal cohort therefore requires three non-overlapping 8-hour runs
and 150 physical reconnects. A failed, unknown or incomplete ordinal closes the
series; passing runs from separate attempts cannot be combined.

## 4. Preserved External Inputs

The optional profile may require:

- Apple Developer ID signing and `notarytool` credentials.
- A resettable clean macOS 14 arm64 host or VM.
- At least two simultaneously connected USB iPhones.
- Exact-device coverage for legacy, iOS 17.x boundary/intermediate, and current
  modern iOS builds.
- Resettable Camera, Microphone and Input Monitoring TCC states.
- Controlled online, offline, cache-hit, selected-Xcode, TSS and source-egress
  environments.
- Authorized dependency, license, Developer Support source/use and TSS review.
- A release-owner performance threshold decision after repeatable baselines.
- A durable restricted EvidenceStore with retention, backup and hold support.

These inputs are optional for default delivery. When this profile is activated,
missing required input produces a high-assurance `unknown` or `No-Go` result only;
it does not retroactively invalidate the default product-delivery result.

## 5. Preserved Verification Areas

The high-assurance profile retains the original coverage for:

- full command, supporting-action and non-command feature matrices;
- same-name and multi-device target/source binding safety;
- USB detach/reconnect, Runtime/Helper generation and media recovery;
- complete TCC denial, revoke and regrant sequences;
- clean-machine install, upgrade and movable application paths;
- exact and bounded OS support claims;
- Developer Support, DDI, cache, TSS and network source policy;
- signing, notarization, staple and Gatekeeper verification;
- performance baseline, threshold decision, freeze and reevaluation;
- immutable candidate, EvidenceStore, selection, lineage, WAL and release holds;
- final store-to-dist byte identity and repeated signature/staple verification.

The detailed executable contracts remain in TRD 08 sections 36-42,
PRD/TRD、`Verification/`、`Schemas/evidence/`
and `Scripts/evidence-tool`.

## 6. Default Delivery Relationship

Default product delivery has a different purpose: produce a usable PulsePhone app
and verify it on the USB iPhones that the owner can provide. Its required result is
limited to the exact observed device and OS builds. Other devices and environments
are recorded as `notTested` and may be evaluated later under this document.

The following rules remain mandatory in both profiles:

- never display one device while controlling another;
- never route a command to a different canonical UDID;
- do not reuse stale connection, source or geometry epochs;
- do not report a component/model test as a working production UI;
- do not claim an untested device or OS version as verified;
- preserve truthful failure and supersession history.

## 7. Historical Evidence

Existing Alpha attempts, performance artifacts, EvidenceStore records, Timeline
entries and Pitfalls remain immutable historical facts. Reclassifying the profile
as optional does not convert a failed run into a passing run and does not require
deleting the evidence.

Future high-assurance work should start from an explicit profile activation and a
new clean task boundary. It must not be resumed implicitly by a default MVP task.
