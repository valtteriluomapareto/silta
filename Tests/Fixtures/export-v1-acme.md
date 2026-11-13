# Frozen format 1 Acme export

Produced by source `725bf236bd3d68ec18055bbecaa952cd74927efb` before the document renderer changes. The pinned v4 writer exports an isolated synthetic workspace, including reserved app identities, unsafe legacy service/kind bytes, stored implicit code pointers, a proposed task and its comment. No docs are included because the genuine format 1 writer refuses them.

Recreate with `python3 scripts/make-docs-format1-fixture.py <v4-binary> <new-output-directory>`. Build the supplied binary from the pinned commit in an isolated checkout. The recipe verifies migration/writer/format markers, runs with temporary HOME and SILTA_HOME below /private/tmp, and freezes time/IDs. Two separate recipe runs produced identical bytes. The compatibility test reads the checked-in bytes directly; no local old binary is required.

File hashes:

- `alias_decisions.jsonl`: `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`
- `approvals.jsonl`: `296fe09a61827de96c8b790191e37f5f770f1c57a67e415a718e65c420a47771`
- `links.jsonl`: `e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855`
- `manifest.json`: `87712d20afbd020ce7c982015ff16122b39996d6c60d3e396b6e2587aabbd34e`
- `tasks/AC-1.jsonl`: `dcdcbadbc77b71e1d6c6754c69f82d2f6335ef4ab86fb00190c36e8e2fa96417`
- `tasks/AC-1.md`: `5589238bfb5438be27278ffb6cb9e816ee4c8d86331b0d04ef21946e5ee49f7f`
- `workspace.yaml`: `c00bb1c7da47b71c6c776916b8df2d6b6434fe5796a34397e4f66f1c917ad359`
