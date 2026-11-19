# Shipped SQLite catalogs

Each line records an object's type, name, owning table and literal SQL, ordered
by type and name. The SQL is NULL for SQLite-managed autoindexes. Allocation
details such as root page numbers are outside the catalog contract.

The first eight goldens were captured by applying the shipped DDL at
`3ee9931f064fffa6b1a9068be8020c2792d40c08` in SQLite. The v4 and v6 catalogs
were also checked against their frozen stores, accounting for the stores'
deliberately unknown `doc_rev.future` column. Add a golden for each new migration
and retain the existing checkpoints.
