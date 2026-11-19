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
description:
Acme task body
app: api
summary: Acme API
environment: prod https://api.acme.example
AGENTS.md: <repo>/AGENTS.md
neighbour: api -> service:push [uses] Acme push
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
- Your Mac runs an earlier version than macOS 26.

## Status

Pre-1.0. Coding agents use the CLI. Silta Dev gives people the inbox, board,
workspace map and Docs, with the supported [Mac app actions](docs/plans/mac-app-actions.md).

## Install

Check the [development installer requirements](docs/getting-started.md#1-requirements).
Run the installer from a clean `main` matching `origin/main`:

```sh
git clone https://github.com/valtteriluomapareto/silta.git
cd silta
scripts/install-dev.sh
export PATH="$HOME/.local/bin:$PATH"
```

Data lives in `~/.silta`, or in `SILTA_HOME` when set. Follow
[Getting started](docs/getting-started.md) to configure your first workspace and task.

## Learn more

- The [human's guide](docs/human-guide.md) covers the inbox, proposals, questions and approvals.
- `silta --help` lists commands; each command has its own `--help`.
- `silta guide` and `silta schema` are the agent manuals.
- Agents contributing to Silta start at [`AGENTS.md`](AGENTS.md); humans at
  [`CONTRIBUTING.md`](CONTRIBUTING.md).

## License

[MIT](LICENSE) © Valtteri Luoma
