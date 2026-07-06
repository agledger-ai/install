# Software delivery (GitHub): AGLedger vertical recipe

A set of contract types for notarizing an agent-driven code-delivery flow end to end: the
authoring agent's stated intent and claims, the CI conclusion as GitHub computed it on the
exact commit, the human authorization to merge or deploy, and the outcome as GitHub reports
it. One offline-verifiable chain from "the agent said" to "the SoR concluded" to "a human
authorized" to "this landed." It is a **starting point you adapt**, not a turnkey product: a
working scaffold meant to be imported into your own Server and reshaped to your delivery
process and your repository policy.

The system of record here is unusual: GitHub is the first SoR in this catalogue that carries
its own **native human gates** (PR review with author-cannot-self-approve; environment
protection with required reviewers). This recipe's main job is to compose AGLedger's Gate
with those native gates without duplicating the decision. The rule throughout: **one
decision, one holder**, and the record type names the holder.

## Why a gate here

Merging into a protected default branch and releasing a deployment are one-shot, outward
facing acts. GitHub records who executed them, but has no primitive for what the author
*claimed* the change does and tested, and its approval trail lives inside the same blast
radius as the platform itself (repository deletion, account or org compromise; a history
rewrite cannot alter GitHub's approval records but can orphan the commits they refer to).
The AGLedger record binds the agent's claims, the CI conclusion, and the authorization to
the exact commit, signed, and verifiable offline without querying either system: tampering
with the recorded history is detectable against the out-of-band signing key. Truth of the
relayed content is a separate property; it rests on the relay being re-checkable against
GitHub while GitHub's data exists.

## What you get

Seven contract types in `types/`, registered in the order below. Five are notarize-only
(they record what happened and terminalize in one signed call); two are principal-gates
whose human verdict is held on-chain.

| # | Type | Lifecycle | Purpose |
|---|------|-----------|---------|
| 01 | `change-authored-v1` | notarize-only | The agent's own word at submission: intent, `headSha`, `diffHash`, `changeClass`, `testsRun`, `riskAssessment`. Unverified claims, deliberately: the divergence against the SoR's computed truth is the audit value. |
| 02 | `ci-conclusion-v1` | notarize-only | The SoR's rendered CI conclusion, relayed hash-bound: `runId` + `headSha` + the closed `conclusion` enum. Re-checkable against GitHub by anyone. |
| 03 | `review-verdict-v1` | notarize-only | SoR-held merge gate outcome: a PR review as GitHub rendered it (reviewer, state, `commitId` pin). |
| 04 | `merge-authorization-v1` | **principal-gate** | AGLedger-held merge gate: one-shot authorization of PR `{n}` at exactly `headSha`, rendered before the seam fires `PUT /merge` with the `sha` pin. |
| 05 | `deploy-authorization-v1` | **principal-gate** | AGLedger-held deploy gate: verdict first, then the seam approves GitHub's held `pending_deployments`. |
| 06 | `deployment-approval-v1` | notarize-only | SoR-held deploy gate outcome: the environment approval or rejection as GitHub rendered it. |
| 07 | `delivery-outcome-v1` | notarize-only | What landed: `mergeSha` / `deploymentId` + state, `executedBy`, `authorizedRef` back to whichever record held the decision. |

## Choosing the gate holder

- **AGLedger-held** (`merge-authorization-v1` / `deploy-authorization-v1`): the principal
  renders the Verdict in AGLedger first; the seam executes it against GitHub. Use when the
  authorization record must be system-independent proof, which is typical when agents drive
  delivery and the human decision happens outside GitHub's UI anyway.
- **SoR-held relay** (`review-verdict-v1` / `deployment-approval-v1`): the human decides
  inside GitHub where they already work; the record notarizes GitHub's rendered decision.
  Use when the org keeps its approval workflow in GitHub.
- Do not run both gates for the same decision: the same human answering the same question
  twice adds a signature, not evidence. Pick per decision point; a real pipeline commonly
  mixes the two (SoR-held review for the merge, AGLedger-held gate for the deploy, or the
  reverse).

## The GitHub seam

Four points connect this recipe to a live GitHub. The recipe was wired to GitHub; the shape
carries to any forge that exposes a review, check, and deployment lifecycle.

- **CI conclusion in.** `GET /repos/{o}/{r}/commits/{sha}/check-runs`. Relay `conclusion`
  verbatim with `runId` + `headSha` so the relay is independently re-checkable. Note that
  `pull_request`-triggered runs execute the head-into-base test merge, not the head commit
  in isolation; push-triggered runs execute the head itself.
- **On the FULFILLED merge verdict.** `PUT /repos/{o}/{r}/pulls/{n}/merge` with
  `sha=<authorized head>`. The pin is the one-shot binding and the enforcement line: GitHub
  409s if the head moved after authorization; open a fresh gate.
- **On the FULFILLED deploy verdict.** `GET /repos/{o}/{r}/actions/runs/{id}/pending_deployments`,
  then POST `{environment_ids, state: approved|rejected, comment}` after (AGLedger-held) or
  instead of (SoR-held) the AGLedger verdict.
- **Gate config as data.** `GET /repos/{o}/{r}/rules/branches/{branch}`. Notarizing which
  protection regime was in force at decision time is cheap and useful.

A rejected environment gate concludes the run `failure` (not `cancelled`); key the
`deploy-rejected` outcome off the rejection record, not the run conclusion.

## Controls in this recipe

- **Schema rigor (engine-enforced at create and completion time).** 40-hex SHA patterns,
  GitHub's closed enums verbatim, `additionalProperties: false` everywhere,
  conditional-required (`outcomeKind: merged` requires `mergeSha`; a merge proposal with
  `ciConclusion != success` requires `overrideJustification`, so merge-on-red states its
  reason on-chain).
- **Echo rules (engine, advisory under principal mode).** The gated completions must echo
  the authorized `headSha` / `ciConclusion` / `environment` (exact string equality). A
  mismatch is stamped on the record for the principal to read before rendering the verdict
  via `POST /v1/records/{id}/verdict`; under `gateMode: auto` the same rules are decisive
  (FAILED). The *enforcement* line for the merge is the seam's `sha` pin on `PUT /merge`:
  GitHub 409s if the head moved after authorization.
- **Separation of duties (deployment configuration, not type-enforced).** Provision the
  authoring agent, the release agent, and the release-manager principal as distinct
  identities with their own keys. AGLedger permits self-principal on create, and
  `gateMode: auto` on create can override a `principal` default; the orchestrator must not
  do either on the gated types. GitHub's native SoD
  (author-cannot-self-approve 422; environment `prevent_self_review`) is an independent
  second line: this is the one vertical where the SoR is stricter than the notary, and both
  lines are worth keeping on.

## Lessons for implementers

What we learned building and exercising this recipe: the things worth knowing before you
adapt it.

### The honesty boundary: the agent's word vs the SoR's rendering

`change-authored-v1` is deliberately unverified: AGLedger notarizes the agent's own account
(intent, `changeClass`, `testsRun`, risk) without checking it against anything. That is the
point, not a gap. The SoR-computed truth arrives separately in `ci-conclusion-v1`, bound to
the same `headSha`, so a divergence (agent claimed tests passed, CI concluded `failure` on
the same commit) is provable from the chain. `changeClass` is an agent-attested claim; a
CI-side path check is the cross-check for misclassification (an application change claimed
as docs to reach a lighter review lane). AGLedger holds the claims and the renderings; it
does not judge either.

For anything an auditor relies on, read `GET /v1/records/{id}/audit-export` (or pass
`?integrity=true`), not the plain `GET /v1/records/{id}` body. The plain read is a
rewritable projection; the export offline-verifies (Ed25519 / COSE) against the public key
from `GET /v1/verification-keys`, with no AGLedger code in the loop.

### GitHub quirks that shape the wiring

- **Agent PRs from inside Actions need a non-`GITHUB_TOKEN` push.** Events created with the
  workflow token do not trigger workflows (GitHub's recursion guard), so a token-created PR
  gets no gate run and required checks never report. Push the branch with a deploy key or
  authenticate the agent as a GitHub App; PR creation can stay on the token to keep the bot
  author identity.
- **Protect the check definition.** The agent cannot forge GitHub's rendering, but it
  authors the inputs, including the check definition on `pull_request`-triggered workflows.
  Protect `.github/workflows/` (CODEOWNERS, or a check computed outside the PR-controlled
  tree) or a lying agent can make the check itself pass. The relayed conclusion is only as
  trustworthy as that protection.
- **An active ruleset binds admins too.** Maintenance pushes to the protected branch need a
  PR or a deliberate enforcement toggle; that friction is the control working.
- **Post-merge CI runs on the merge commit.** Keep `changeRef` pointing at the ancestor
  change record and set `headSha` to the merge commit; the delivery-outcome record's
  `headSha` / `mergeSha` pair is the lineage link between the two commits.
- **When the ruleset forces a PR review under an AGLedger-held gate,** treat the review as
  seam execution: render the AGLedger verdict first, then submit the approving review with
  the authorization record id in the review body. The review satisfies GitHub's mechanical
  requirement; the AGLedger record remains the decision.

### Engine echo rules: wiring details that bite

- **Give every echo rule its own free-form ruleId.** Two `fieldMappings` sharing a
  verb-form ruleId (`string:exact`) silently collapse to one at registration: 201, no
  warning, and the dropped rule never evaluates. Free-form ruleIds dispatch
  to the valueType's default verb (`string` maps to exact equality), which is what these
  rules use.
- **Read rules back under `rulesConfig`.** `GET /v1/schemas/{type}` returns the live rule
  wiring at `rulesConfig.fieldMappings`; the top-level `fieldMappings` key (the one you
  register with) reads null, and `/template` drops the wiring entirely, so a template fork
  silently loses the rules. Keep the type JSON in version control as the
  source of truth. Note the read-back cannot catch the duplicate-ruleId collapse: a
  duplicate-ruleId type shows both rows in `rulesConfig` while the engine evaluates one.
- **Principal-mode engine rules advise; they do not block.** The principal can accept over
  a failed echo rule. Treat the engine result as what the human reads, and put the hard
  stop in the seam (the merge `sha` pin, the environment id).
- **The verdict body is closed** (`additionalProperties: false`): `{verdict, completionId}`
  plus optional `checks` (structured, signature-covered) and `notes` / `reason`. Put
  anything an auditor needs to read programmatically in `checks`.

### Identities and scopes

- **Give the coding agent its own AGLedger identity.** `change-authored-v1` is
  first-person; a release agent relaying someone else's change can only file a second-hand
  account (`testsRun: not-run`, relay noted in `intent`). In a CI-authored setup that means
  a notarize step inside the authoring workflow, with its own key.
- **The performer needs `records:write`.** `POST /v1/records/{id}/accept` (a performer
  accepting a delegated proposal) is a `records:write` action that the
  `agent-performer-only` profile deliberately lacks, and `autoActivate` with a distinct
  performer is refused so the consent step cannot be skipped. Provision release agents that
  participate in the gated types with `agent-full` or a custom profile carrying
  `records:write`; `agent-performer-only` performers can never open the gate.

### Two honest shapes for a merge denial

If the gate is live (the performer accepted), the performer submits the proposal via
`POST /v1/records/{recordId}/completions` and the principal rejects via
`POST /v1/records/{id}/verdict`; a `delivery-outcome-v1` with `outcomeKind: merge-declined`
then closes the chain. If the gate never left PROPOSED (for example the performer cannot
accept), the principal cancels with the full decision in `reason`: the text lands inside
the Ed25519-signed state-change entry, so the denial is still attributable and
tamper-evident. Either way, close the chain with the outcome record pointing
`authorizedRef` at the gate.

### Keep type descriptions short if you will distribute

`POST /v1/schemas` (register) accepts a long `description`, but `POST /v1/schemas/import`
(the manifest / distribution form) rejects descriptions over 2000 characters, so an
over-long description makes the type un-distributable. Put long-form deployment guidance in
this README, not in the schema `description`.

## Install

You administer your own Server, so registering these types *is* the install: no external
registry, no shared signing infrastructure.

```bash
export AGLEDGER_API_URL=https://agledger.internal.example
export AGLEDGER_API_KEY=agl_...   # an admin/platform key with schemas:write
./register.sh
```

`register.sh` POSTs each type to `POST /v1/schemas` in order and prints what landed.
Re-running registers a new version of any type whose schema changed compatibly; an
incompatible change is rejected and reported. See `register.sh` for the `RECIPE_FORCE=1`
reset option (destructive; scratch orgs only).

For the per-call mechanics (preview, compatibility modes, versioning, and sharing types
across Servers), see the **Define Custom Types** guide. For the Notify subscriptions in
`notify.yaml`, see the **Webhooks** guide.

## Air-gapped

This recipe is files. Once you have this directory on the target host, `register.sh` talks
only to the `AGLEDGER_API_URL` you give it (your own Server) and makes no outbound calls to
any registry, our website, Docker Hub, or npm. GitHub is a separate system you integrate;
on a GitHub Enterprise Server install the same seam endpoints apply against your own host,
and AGLedger notarizes whatever the forge reports.

## Adapt it

Imported types are ordinary, editable contract types under your org. Keep, edit, rename, or
delete any of them. AGLedger ships a deliberately minimal core rather than opinionated
built-in types; a recipe is a head start you own, not a platform-managed type kept in
lockstep with your business.
