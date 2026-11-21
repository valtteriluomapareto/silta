# v9 storage fixture

The v9 writer migrated a private copy of the populated [v8 fixture](storage-v8.md).
It raised the writer floor to 9 and kept the catalog. A synthetic former name
was added to the retained Acme app to pin the v9 history through migration.
The SQLite journal was checkpointed and its integrity checked.
