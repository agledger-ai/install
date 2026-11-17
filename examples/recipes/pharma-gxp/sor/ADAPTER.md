# Replacing the Odoo adapter with your MES, LIMS and ERP

`odoo.py`, `checker.py`, `readers.py` and `writer.py` are the only files that talk to the
system of record. The contract types, `oq/probes.py`, `oq/verify.py` and `oq/crosscheck.py`
never do. To move the recipe onto SAP, an MES or a LIMS you replace those four and keep the
shapes below. Only the Odoo adapter has been run; this is the interface it implements, not
a tested port.

## The client (`odoo.py`)

One client object per automation per run, with four duties:

| Member | Contract |
|---|---|
| `reads`, `writes` | Counters the client increments on every call it sends, by the call's kind. A reader reports `mutating` from its own client's `writes`, and the checker refuses to sign if `writes` moved. Classify by an allow-list of read operations: anything not on it counts as a write. |
| `stamps(model, ids)` | For each record, `{"model", "id", "writeDate"}`, where `writeDate` is the system's own last-modified stamp for that record as the system reports it. Strings, at most 80, 64 and 40 characters (the evidence-read type bounds them). |
| `stamp_digest(stamps)` | SHA-256 over the sorted `(model, id, writeDate)` tuples in canonical JSON. `oq/crosscheck.py` re-derives it with the same function, so keep the serialization or change both. |
| `sha256`, `canon` | The hash and the canonical JSON every evidence hash in the recipe uses. |

### Where the write stamp comes from

The stamp has to be one the system maintains, not one the automation computes, and it has
to move on every write to the record, including a write that changes no field. In Odoo that
is `write_date`. In another system, in order of preference:

1. A last-changed timestamp or version counter on the record itself, returned by the same
   read that returns the record (an ETag or a last-change field on an API entity).
2. The newest entry of the system's own audit trail or change log for that record (in SAP,
   the latest change document for the object).
3. If the system has neither for a table you read, the read cannot support the write-stamp
   digest: say so in the reader's `summary` and treat the read-only claim for that dataset
   as resting on the system's access log.

Confirm the choice with a test the OQ already has: case A writes to a record the reads
listed and asserts that the re-derived digest changed. If your stamp does not move on that
write, it is the wrong field.

## The checker (`checker.py`)

    names, plan_hash = read_control_plan(client, control_plan_ref)
    evidence = run(client, proposal, control_plan_ref)

- `read_control_plan` reads the plan from the quality system and returns the check names
  in plan order and a hash over the plan's reference, name and questions. QA's
  orchestration calls it when it opens the release, and the checker calls it again at check
  time; the engine compares the two hashes.
- Each check is a function `check(client, proposal)` returning
  `(passed, source_ref, observed, expected)` and registered under its plan name in `CHECKS`.
  A plan name with no function is reported failed, never skipped. Names are lower-case
  letters, digits and hyphens.
- What a check needs comes from the system, never from the proposal. `component-lots-on-hand`
  takes quantities from the BOM; a port keeps that rule for every check that has a
  system-held source of the expectation.
- `run` returns the completion body for `calder-precondition-check-v1` and raises if the
  client's `writes` moved.

## The readers (`readers.py`)

    evidence = READERS[source_system](client, lot_numbers, product_code, ledger=None)

Each returns the completion body for `calder-evidence-read-v1`: the query and its hash, the
hash of the canonical result, `recordCount` equal to the number of `sourceRecords`, the
stamps of every record read, `readAt`, `mutating` from the client's counter, and a bounded
`summary` in the reader's words. `sourceSystem` must equal the one the orchestrator
declared on the child's criteria. The complaint-history reader takes a callable that
searches the ledger; it needs a key that can see the cases (an agent key sees only its own).

## The writer (`writer.py`)

    payload = build_payload(client, proposal)                 # before the release completion
    receipt = write(client, payload, release_ref, ledger)     # after QA's accept

- `build_payload` is deterministic in the proposal and the system's ids, so the proposer
  can hash it before QA signs. `payload_hash` is over its canonical JSON.
- `write` calls `authorize` first and writes nothing if it raises `Refused`. `authorize`
  does not depend on the system of record and ports unchanged.
- `write` sends exactly `payload` and returns the criteria for `calder-sor-write-receipt-v1`,
  with the id, the name and the write stamp the system assigned. If your system creates the
  batch record in more than one call, the receipt names the record an inspector will look
  up, and the payload hash covers everything sent.

## After the port

Change the driver's fixtures in `oq/drive.py` (the product, the lots, the control plan
reference, the seeding step) to your own and run `oq/run.sh`. The probes, the verifier
step, the cross-record check and the matrix build run unchanged.
