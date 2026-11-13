# Synthetic v6 database

Produced before the audit-column migration by source
`b65eab8994b7ada9f54495f9c050ebe5a3090d74` and the checked-in v4 database,
using `scripts/make-docs-v6-fixture.py <v6-binary> <v4-db> <output-db>`.
The real writer migrates isolated temporary state; the recipe then seeds documented
synthetic Acme history. It includes accepted, proposed, rejected and superseded
revisions, unknown columns, a source task, verification and revision reservation.
No triage decision can be inferred from those rows. Two recipe runs were identical.

SHA256: `33b22273111c806a29ed7ceadc81a90e517ece09d0eefd99b413df254ab57b4e`.
