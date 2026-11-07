# Getting started

Set up Silta on a few related repositories, then ask an agent to start its first task.
The examples call the workspace `acme` and use the task prefix `AC`; substitute your own.

## 1. Requirements

- macOS 15 or later.
- Xcode 27.1 (Swift 6.4), selected with `xcode-select`.
- Git, and local clones of the repositories you want to register.

## 2. Install the CLI

From a clean `main` checkout that matches `origin/main`:

```sh
scripts/install-dev.sh
export PATH="$HOME/.local/bin:$PATH"
silta --help
```

Add the `PATH` line to your shell profile if `silta` is not found in a new shell.

## 3. Register your repositories

Pass only the clones you want in this workspace:

```sh
silta init --scan ~/work/api ~/work/web --slug acme --prefix AC
cd ~/work/api
silta where
```

The scan registers repositories and discovers likely apps, but those apps still need
descriptions and production refs. The workspace is selected from a repository you enter;
use `--ws acme` when working outside one.

## 4. Describe the apps and their connections

Inspect the full configuration with `silta --ws acme ws show`. Read the repositories'
READMEs and update each app's summary, repo branch, production branch and any subpath.
Add deployment environments and the APIs or external services each app calls.

See the [annotated Acme workspace](examples/acme-workspace.yaml) for the complete YAML
shape, including several apps on branches of one repository. Start from the YAML shown
for your workspace: saving replaces the configuration, and omitted rows are removed.

`ws edit` changes configuration and therefore needs human approval. After reviewing the
YAML, apply it with `silta --ws acme ws edit -F <file>`; if run by an agent, it will name
the human approval step. Do not put secrets or private notes into the file.

## 5. Connect your agents

For Claude Code, preview the user-level instructions, skill and SessionStart hook:

```sh
silta agents install --claude --hook
```

Read the entire preview, copy its token into the displayed apply command and rerun it:

```sh
silta agents install --claude --hook --apply <token>
```

Repeat the preview with `--codex` too if you use Codex and want its instructions and
writable data root. Codex has no session hooks; your Codex agent runs `silta brief` at
session start itself. Then check the installation:

```sh
silta doctor --install
```

## 6. Start the first task

From a registered repository, tell your agent: **"Add a task for X and start it."** The
agent creates and claims the work, then can read context with `silta brief`.

You can check the current location, agent claims and your attention queue at any time:

```sh
silta
silta inbox --for me
```

## 7. Undo the agent integration

Preview removal, then apply the token from that preview:

```sh
silta agents uninstall --claude
silta agents uninstall --claude --apply <token>
```

Add `--codex` if you installed that integration too. Uninstalling leaves your workspace
data in `~/.silta` (or `SILTA_HOME`). Run `silta backup` to create an on-demand snapshot
of all workspaces before changing or removing that data.

## Troubleshooting

| Symptom | What to do |
|---|---|
| The Claude hook prints nothing | Run `silta brief` from a registered repo, then `silta doctor --install`; sessions outside registered repos have no brief. |
| `ambiguous_location` | Inspect `silta where --path <dir>`, then retry with the suggested `--ws <workspace>` or `--app <app>`. |
| `claimed` | Another agent session holds the task. Pick other work or ask that agent; do not take over its claim yourself. |
| Unknown workspace | Run `silta ws ls` and use an exact listed slug with `--ws <workspace>`. |
