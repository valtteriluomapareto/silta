# v8 storage fixture

An installed writer built from commit 605a8a69 migrated a private copy of
the populated [v7 fixture](storage-v7.md) after running init. It added the
nullable document target snapshot column and set the writer floor to 8.
The fixture retains the synthetic Acme data and the unknown-column canary.
Its journal was checkpointed and SQLite integrity was checked before copying.
