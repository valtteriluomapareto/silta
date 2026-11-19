# Synthetic v7 database

Produced with the last writer before v8, built from
`f8dae4e3237b8de70c7ba83ef07d5ffe740efced`, using
`python3 scripts/make-docs-v7-fixture.py <v7-binary> Tests/Fixtures/storage-v6.db <output-db>`.
The historical writer migrates a temporary copy of the v6 fixture to v7 and adds
a synthetic Acme task. The recipe fills the triage audit fields on one rejected
revision. It leaves NULL audit fields on the other revisions and retains the
v6 fixture's unknown-column canary. Two recipe runs produced identical bytes.

The SHA-256 is `fc18deed55d2f1987f5ed0323b42c98dd4280504e9e47cbd637ad70f987724b6`.
