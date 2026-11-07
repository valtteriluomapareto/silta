# Silta

Silta is a local context hub and backlog that keeps coding agents oriented across your repos and sessions.

Coding agent work loses its thread:

- Every session starts blind to the app, related services and work already underway.
- Context gets copied into chats and pasted between agents by hand.
- Plans and decisions leak into repository files or the team tracker.

Silta lets agents record that context once and retrieve it where they work. A Claude
Code SessionStart hook prints a brief; other agents, including Codex, run `silta brief`
themselves:

```text
acme / platform / api [high: explicit]
branch: api
task: AC-2
doing: Acme task (app: portal)
plan (revision 0):
1 done
2. [ ] Acme next
app: api
```

## When it pays off

- You have several repos or apps, including apps represented by branches of one repo.
- Work spans sessions and needs a handoff, review or decision to survive the chat.
- Several agents work in sequence or in parallel.
- You work through agents and want plans and decisions out of chat and out of repos.

## When not to use it

- You use one repo for short tasks: `AGENTS.md` and git already do the job.
- You need team coordination: Silta is single-user, local and has no sync; your team
  tracker remains the record of committed work.
- You need a server, MCP integration or a web UI.
- You are not on macOS 15 or later.

## Status

Silta is pre-1.0 and currently provides a CLI, not the planned macOS app.

## Install

Silta needs macOS 15 and Xcode 27.1 (Swift 6.4). From a clean `main` matching
`origin/main`:

```sh
scripts/install-dev.sh
export PATH="$HOME/.local/bin:$PATH"
```

Data lives in `~/.silta`, or in `SILTA_HOME` when set. Follow
[Getting started](docs/getting-started.md) to configure your first workspace and task.

## Learn more

- `silta --help` lists commands; each command has its own `--help`.
- `silta guide` and `silta schema` are the agent manuals.
- [The design](docs/spec.md) explains the product and technical model.
- Agents contributing to Silta start at [`AGENTS.md`](AGENTS.md); humans at
  [`CONTRIBUTING.md`](CONTRIBUTING.md).

## License

[MIT](LICENSE) © Valtteri Luoma
