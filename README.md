# Silta

A local bridge between your coding agents, your repos and what was decided.

Silta (Finnish for *bridge*, as in a ship's *komentosilta*) gives every agent session
the picture when it starts. It shows the app it's in, the apps it talks to (even when
they live on other branches of the same repo), the task at hand, the last handoff and
recent decisions. It also gives agents a local backlog with plans, questions, handoffs
and reviews, so they stop filing tickets in the team tracker or leaving plan files in
repos.

- **CLI** (`silta`) for agents. Claude Code, Codex, OpenCode and others use it through
  their shell tool.
- **macOS app** (later) for you: triage, review and sign off.
- **One Swift core** on a local SQLite database. No server, no MCP, no daemon.

## Status

The first milestone (M1, daily use) is in progress; its slices are in
[`docs/plans/m1-daily-use.md`](docs/plans/m1-daily-use.md). The design is in
[`docs/spec.md`](docs/spec.md). Silta is built with Silta: the current dogfooding
stage is in [`AGENTS.md`](AGENTS.md#dogfooding).

The CLI has these commands today: `init`, `ws`, `repo fetch`, `where`, `code`,
`task`, `comment`, `inbox` (discussion only so far), `brief`, `doctor`, `schema` and
`guide`. Run `silta --help` for the list and `silta guide` for the agent manual. Not
built yet: agent install, export and restore (spec §16 marks each command's
milestone).

## Install

Silta needs macOS 15 and Xcode 27.1 (Swift 6.4). From a clean `main` that matches
`origin/main`:

```sh
scripts/install-dev.sh
```

It builds a release binary and installs it as `~/.local/bin/silta`. Data lives in
`~/.silta`, or in `SILTA_HOME` when set.

## Contributing

Agents start at [`AGENTS.md`](AGENTS.md); humans at [`CONTRIBUTING.md`](CONTRIBUTING.md).
Everything runs through `scripts/verify.sh`.

## License

[MIT](LICENSE) © Valtteri Luoma
