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

Design phase. The draft spec is in [`docs/spec.md`](docs/spec.md), and the first
milestone is planned in [`docs/plans/m1-daily-use.md`](docs/plans/m1-daily-use.md).

## Contributing

Agents start at [`AGENTS.md`](AGENTS.md); humans at [`CONTRIBUTING.md`](CONTRIBUTING.md).
Everything runs through `scripts/verify.sh`.

## License

[MIT](LICENSE) © Valtteri Luoma
