# Agent rules

This repo holds the shared gRPC definitions of the VWS control plane. Server implementations, deployments and test environments are not built here.

## Rule table

| Item | Rule |
| --- | --- |
| Style | Google API style and AIPs. proto3, the `Service` suffix, standard method names |
| Lint | `buf lint`, on the `STANDARD` set |
| Breaking | `buf breaking`, on the `FILE` set |
| Package | `vws.<domain>.v1`. The directory matches the package |
| Resource envelope | Fields 1–10 of every resource are the same as the envelope in `vws/common/v1/resource.proto` |
| State | `spec` is the desired state. `status.observed` is the state the node reported |
| Mutating RPC | Returns a `google.longrunning.Operation`. Metadata is `vws.common.v1.OperationMetadata` |
| Read RPC | Returns the resource message |
| Lint exceptions | Only `RPC_RESPONSE_STANDARD_NAME` on `Get*`, and `RPC_RESPONSE_STANDARD_NAME` and `RPC_REQUEST_RESPONSE_UNIQUE` on mutating RPCs, because of AIP-131 and AIP-151 |
| Idempotency | Create, update, delete and status reports reach the same result when run again, following the rules written in `OperationMetadata` |
| Restart | The desired state and the operation are stored before the response. When the process comes back up, it reconciles from that record |
| Identifiers | `ResourceId` grammar except Object keys. Collection names are AIP-122 camelCase |
| Go package | `option go_package = "github.com/popododo0720/vws-proto/gen/go/<proto directory>;<domain><version>"`. `vws/compute/v1` is `computev1`. CI checks it against the file path |
| Generated code | The output of `buf generate` and `go mod tidy` (`gen/go`, `go.mod`, `go.sum`) goes in the same commit as the proto change. `gen/go` is never edited by hand |
| References | Other resources are referenced by full resource name, not linked by proto imports across packages |
| Branches | Do not commit or push to `main` directly. Changes go in through a branch and a PR |
| Commits | Atomic. One commit has one purpose |
| Notices | No logos and no trademark notices |
| Insider risk | A PR targets main and its body has `Part of #N` and no closing keyword. CI reports commits that reached main without a PR. This file has Insider-risk guardrails 1-7 below. The checks are `scripts/guard-agents.sh`, `.github/workflows/repo-guard.yml` and `.github/workflows/direct-push-watch.yml` |
| Tools | Do not use Cursor cloud agents. Follow the poteto-mode section below for the way of working |
| English only | The repo is English only (see "English only"). Hangul is allowed only in files `.github/english-allowlist` lists with a reason. `scripts/check-english.sh` checks it in the CI `english` job |

## English only

Write everything in this repo in English: README, code comments, docs, AGENTS.md, QUALITY.md, PR and issue templates, commit messages, PR and issue bodies, review comments and `Verified-by` sections. The `english` job in CI runs `scripts/check-english.sh`: `files` fails on a tracked file with Hangul unless `.github/english-allowlist` lists it as `<glob> <reason>` (only test data and user-facing UI strings belong there), and `text` and `commits` reject Hangul in the PR body and the PR's commit messages with no exception.

## Branches and commits

Do not work on `main`. Create a branch and get reviews through a PR.

One commit has one purpose. Do not mix the common contract, domain APIs, CI and docs in one commit. The final tree of a PR that changes proto must pass `buf lint` and `buf build`, with `gen/go` up to date. CI checks that tree.

## Way of working (poteto-mode)

- Write concisely and make the smallest change. Delete what you can.
- Decide the shape of the data before writing code. When the same mistake repeats, block it with lint or a CI check instead of a sentence.
- Say something is verified only if you actually ran it. Mark what you could not run as "unverified". Verification in this repo is `buf lint`, `buf build`, `scripts/check-generated-go.sh` and `go build ./...`.
- Write commit messages and PR descriptions as short plain statements. No unsupported claims and no made-up links.
- Do not use Cursor cloud agents (CloudAgent). The usage is exhausted; work with `gh` and `git`.

## Using pstack

When design or a fix falls into one of these, use that procedure.

| Situation | Procedure |
| --- | --- |
| A design across function boundaries: packages, services and the common contract change together | architect |
| A contested design: more than one shape could stay in the contract, with trade-offs | interrogate |
| A repeated mistake: the same lint violation, envelope mismatch or missing idempotency rule comes back | correct |

## /correct loop

1. When a bot is corrected (by the user Su Kim, tmp or eggbot, or by a failed `vws verify`), it opens an issue the same day with the `incident` label using the `.github/ISSUE_TEMPLATE/incident.yml` form. It must fill in the correction and "the check that would have caught this".
2. Every few days vws-verify runs a gardener pass. It groups open incidents by cause and promotes repeated ones to a check (test, lint, guard rule, archtest), not a sentence. The check must actually fail on an input that contains the mistake.
3. When the promoting PR is merged, close the incident with its link. An incident that will not be promoted is closed with the reason.
4. The milestone report (to tmp) lists the number of incidents in the period and the checks promoted.
5. The `incident` label is defined in `.github/labels.yml`, copied from vws-deploy. That file is only a definition and does not create the label on GitHub. `scripts/guard.sh correct` runs `scripts/guard-agents.sh correct`, which checks this section and its body, the required fields of the form and the label definition; `repo-guard.yml` runs it on every pull request and `scripts/guard_test.sh` shows it fails on an empty section.

## Insider-risk guardrails

Bots are insider risks too. The rules below have no exceptions. The design is vws-deploy#33.

1. **Independent verification**: an important result (merge, security, data) is never verified by the bot/model that wrote it. Another bot (or a person) verifies it. (Process rule; CI cannot enforce it.)
2. **Records**: every change leaves a trail of issue → PR (`Part of #N`) → commits. Work logs go in the PR body or issue comments in a form people can read. No force-push or history rewriting (except with the user's approval). In this repo, the body of a PR that changes proto states the impact on downstream repos (vws-compute, vws-storage, vws-network, vws-deploy) and whether it is breaking.
3. **Failure tests**: a new feature is not tested on the happy path only. Include at least one case each for power loss/restart, idempotent re-run and malicious or boundary input, or state in the PR why that is not possible. In this repo, the PR confirms that `buf breaking` fails when a field number is changed or removed, and input validation rules are written in `docs/validation.md`.
4. **Least privilege**: no direct pushes to main. Every change is a single PR from its own branch cut from main. No stacked PRs. No local merges. Tokens are scoped to the repo. RBAC covers only the resources the service code actually calls, as a Role (namespace scope) where possible.
5. **Separated audit**: author bot ≠ verifier bot ≠ merge decision. An author bot never merges its own PR. Merge only when base==main and every CI check on the head commit is success.
6. **Isolation and emergency stop**: a bot/agent is stopped immediately at the user's request or by the orchestrator stopping that bot's session and revoking its token (`gh auth`/PAT revoke). Risky work happens only in a sandbox (the box or a throwaway cluster). No access to production clusters.
7. **Incident disclosure**: rule violations and incidents are never hidden; record them in an issue as `Cause / Impact / Action / Prevention` (label `incident`).

Main is protected by the active `vws-main` ruleset: a pull request is required, only a squash merge is allowed, force push and deletion are off, and the required checks include `pr-hygiene`, `verify-gate` and `vws-verify`. The ruleset has no bypass actors. vws-deploy's `.github/drift/drift-check.sh` fails when this repo loses any of these. Guardrails 1, 5 and 6 stay process rules. For parts of 2 and 4, `.github/workflows/repo-guard.yml` checks the PR's base, `Part of #N` and that no PR text or commit closes an issue, and `.github/workflows/direct-push-watch.yml` reports after the fact any commit that reached main without a PR. How to copy it is in vws-deploy `docs/insider-risk.md`.

### Script push, PR and merge

A deterministic script (the factory orchestrator in vws-deploy `docs/factory-orchestrator.md`, the handoff submit) may push a branch, open a pull request and merge one. A script merge happens only when all of these hold:

- every CI check on the head commit is green;
- `verify-gate` passes;
- the `vws-verify` App check run passes;
- the pull request has no conflicts;
- the merge is a squash, made with `--match-head-commit` set to the verified head;
- the pull request is not labeled `blocked`.

`ORCHESTRATE_MERGE=apply` is approved only under these conditions. The lead (dr eggbot) is woken only for a decision or a failure (issue scope, real conflicts, a failed check), not for a routine push, pull request or merge. Guardrails 1, 4 and 2 still hold: the author bot is never the verifier, nothing pushes to main, and every pull request body has `Part of #N` with no closing keyword.

