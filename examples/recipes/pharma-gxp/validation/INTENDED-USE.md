# Intended use

This recipe is a set of contract types and three reference automations that together record,
on an AGLedger Server, two GxP quality workflows:

1. **A complaint investigation that touches no system of record.** A named QA
   investigator opens a case; automations read the manufacturing, laboratory, distribution
   and complaint-history datasets and attach what they found as hash-bound evidence under
   the case; the investigator closes the case with a signature that carries its meaning.
2. **Batch record creation held behind a deterministic precondition check and a QA
   signature.** An automation proposes a batch; a named QA person opens the release from
   the product's control plan; a deterministic checker runs the required checks against the
   systems; the release cannot be completed before the check settles or after it fails; QA
   approves with a signature that carries its meaning; the writer creates the batch record
   from the approved payload and notarizes the system of record's receipt.

The ledger is the evidence of these workflows, not the system that performs them. It does
not decide whether a complaint is valid, whether a batch should be made, or whether a
reading is in specification. It records who proposed, who checked, what the systems
answered, who signed and with what meaning, in a form that verifies offline against
published keys.

## Systems in scope

- The AGLedger Server (published image `agledger/agledger`; this recipe was built and run
  against 2.0.0).
- The system of record the reference automations drive: Odoo 18.0 Community with the OCA
  quality modules, standing in for the MES, LIMS and ERP of a manufacturing site. The
  checker, the readers and the writer in `sor/` are reference implementations against it; a
  site replaces them with its own against its own systems, keeping the evidence shapes the
  types declare.
- The identities: the QA investigator and the QA release signer are people; the checker and
  the writer are deterministic code; the proposer may be an LLM-driven agent; the readers
  are automations. Each holds its own credential. Binding a credential to a named person
  is the site's (see "Binding a signer to a person" in the README).

## Out of scope

- Any judgement of product quality, process validation of the manufacturing step itself,
  or the content of the batch record beyond what the payload hash binds.
- The regulatory status of the Server as a computerised system under Annex 11 or Part 11:
  this package is the evidence a site's validation uses, not the site's validation.
- Generative or LLM components in a critical GMP role. The recipe keeps the LLM proposer off
  the critical path by construction (draft EU GMP Annex 22, 2025); the critical steps are the
  deterministic check and the human signature.

## Risk basis for the test effort (GAMP 5 second edition, FDA CSA)

Highest risk to product quality and patient safety: the release path (flow 2), where the
system of record is written. Every control on it is scripted and asserted in the OQ,
including the negative cases (failed check, shortened list, stale plan, no write on refusal).
Lower risk: the read-only complaint path, where no system of record changes; its controls are
scripted too, with one negative case (a mutating read). Exploratory, unscripted testing
belongs in the build notes (the README's "Lessons for implementers"), not in the OQ.
