# Historical SQLite fixtures

These files contain only synthetic Acme records. Tests open the originals read-only
and migrate private copies.

| Fixture | Historical schema |
|---|---|
| `storage-v1.db` | `872d27bfc539dc4c5b3f830519610a50f67ebebb` |
| `storage-v2.db` | `eda7fd68ccecd3dfa604f38e94926e19ff3c3adf` |
| `storage-v3.db` | `4b52b9c55a3722bc6b57d9f341390f8f846c2a39` |
| `storage-v5.db` | `dc868192e3877a29d79dc54681f0f57b72c3f56f` |

The first three use SQL from the corresponding [frozen catalogs](storage-schema/),
the historical GRDB stamps and metadata, and one Acme workspace and task with its
counter. The current migrator was not used to create them.

The v5 writer ran `silta --ws acme task add "Acme v5 writer evidence" --app none`
against a temporary copy of the populated v4 database with fixed Acme identity,
time, and ID seed. SQLite's `VACUUM INTO` captured the migrated store. The v5
fixture pins the original populated document backfill.
