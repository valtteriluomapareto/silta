# Isolated agent-harness acceptance

Run outside the coding sandbox, in an interactive terminal, from a checkout
containing all installer/SessionStart/Stop changes. Harness configuration stays
inside a fresh temporary HOME; Silta data uses a separate temporary SILTA_HOME.
Keep the temporary directories until you have recorded the result. Never copy
existing configuration or credentials into them.

## Prepare the fixture

From the Silta checkout, run this Bash setup. `h` is the only launcher used below.
It clears inherited actor, session, provider and harness overrides.

```bash
si35_binary="$PWD/.build/debug/silta"
si35_home=$(mktemp -d)
si35_data=$(mktemp -d)
si35_fixture=$(mktemp -d)
si35_control=$(mktemp -d)
si35_codex=$(command -v codex)
si35_claude=$(command -v claude)
si35_opencode=$(command -v opencode)
si35_path="$(dirname "$si35_binary"):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"
h() {
  env -i HOME="$si35_home" SILTA_HOME="$si35_data" USER=acme \
    CODEX_HOME="$si35_home/.codex" CLAUDE_CONFIG_DIR="$si35_home/.claude" \
    XDG_CONFIG_HOME="$si35_home/.config" XDG_DATA_HOME="$si35_home/.local/share" \
    XDG_CACHE_HOME="$si35_home/.cache" TMPDIR="${TMPDIR:-/tmp}" \
    PATH="$si35_path" TERM="${TERM:-xterm-256color}" "$@"
}
h swift build --only-use-versions-from-resolved-file -Xswiftc -warnings-as-errors
mkdir -p "$si35_home/.codex" "$si35_home/.claude" "$si35_fixture/acme/platform"
printf 'cli_auth_credentials_store = "file"\n' > "$si35_home/.codex/config.toml"
h /usr/bin/git -C "$si35_fixture/acme/platform" init -q -b main
printf 'Acme fixture\n' > "$si35_fixture/acme/platform/README.md"
h /usr/bin/git -C "$si35_fixture/acme/platform" add README.md
h /usr/bin/git -C "$si35_fixture/acme/platform" -c user.name=Acme \
  -c user.email=acme@example.invalid commit -qm 'Create Acme fixture'
h /usr/bin/git -C "$si35_fixture/acme/platform" remote add origin \
  https://example.invalid/acme/platform.git
h /usr/bin/git -C "$si35_fixture/acme/platform" update-ref refs/remotes/origin/main HEAD
h "$si35_binary" init --scan "$si35_fixture/acme"
h "$si35_binary" ws use acme
cd "$si35_fixture/acme/platform"
h "$si35_binary" brief
h "$si35_binary" agents install --hook --stop-hook --json > "$si35_fixture/install.json"
jq . "$si35_fixture/install.json"
si35_token=$(jq -r '.data.token' "$si35_fixture/install.json")
h "$si35_binary" agents install --hook --stop-hook --apply "$si35_token"
```

The last two calls must describe and apply the same edits. A repeated preview must
have no changes. Keep any refusal as evidence; do not bypass ownership checks.

## Codex: effective writable-root grant

Log in afresh with `h "$si35_codex" login`. File credential storage keeps this login
in the temporary CODEX_HOME; do not select an OS credential-store override.
[Codex authentication documents the storage choices](https://learn.chatgpt.com/docs/auth?surface=cli).

Record versions first: `h "$si35_codex" --version`, `h "$si35_claude" --version`
and `h "$si35_opencode" --version`. Open an interactive Codex process with the
exact sandbox/config flags below (omit `exec --json` and the prompt), run `/status`,
record the effective policy, then exit.

Run two new Codex processes with automatic temporary-directory grants disabled.
Do not use `--add-dir`, full access, an injected actor, or an injected session.

```bash
h "$si35_codex" --sandbox workspace-write --ask-for-approval never \
  -c sandbox_workspace_write.exclude_slash_tmp=true \
  -c sandbox_workspace_write.exclude_tmpdir_env_var=true exec --json \
  "Use the shell to write 'granted' to '$si35_data/grant-proof'. Separately try writing
  'control' to '$si35_control/denied-proof'. Do not request elevated permissions or
  change permissions. Report each actual shell result. Report only whether
  CODEX_THREAD_ID exists, never its value. Touch no other paths."
test -f "$si35_data/grant-proof"
test ! -e "$si35_control/denied-proof"
h "$si35_binary" agents uninstall --codex --json > "$si35_fixture/uninstall-codex.json"
jq . "$si35_fixture/uninstall-codex.json"
si35_token=$(jq -r '.data.token' "$si35_fixture/uninstall-codex.json")
h "$si35_binary" agents uninstall --codex --apply "$si35_token"
h "$si35_codex" --sandbox workspace-write --ask-for-approval never \
  -c sandbox_workspace_write.exclude_slash_tmp=true \
  -c sandbox_workspace_write.exclude_tmpdir_env_var=true exec --json \
  "Try writing 'removed' to '$si35_data/removed-proof' using the shell. Do not request
  elevated permissions or change permissions. Report the actual shell result."
test ! -e "$si35_data/removed-proof"
```

Check tool results, not just the model's claim. A successful sibling-control write
makes this run inconclusive: another grant or managed policy is active. The exclusion
keys and writable-root field are in the [configuration reference](https://learn.chatgpt.com/docs/config-file/config-reference).

## Claude: loading, propagation and Stop

Run `h "$si35_claude"` and sign in with a fresh **claude.ai** login for this temporary
config directory. Avoid Console sign-in without an API key: that mode is not fully
separated by CLAUDE_CONFIG_DIR. The directory scopes ordinary credentials and the
macOS credential entry, as described in [Claude authentication](https://code.claude.com/docs/en/authentication).

Verify the SessionStart brief appears automatically. Then give this prompt:

> This is the isolated Acme fixture. Load the Silta skill using the harness skill
> mechanism. Check that SILTA_SESSION is present without printing its value. Create
> one non-code task with `silta --ws acme task add --start --app none 'Acme hook check'`;
> use its returned ref to store a short plan. For this test, attempt your first
> response without a handoff. If the Stop hook requests a continuation, follow its
> scoped command with a short handoff body. Touch only these temporary roots.

Record actual skill loading, automatic brief, subsequent shell session presence,
actor consistency between the hook log and created task, one Stop continuation,
successful handoff and no continuation loop. Do not infer propagation merely from
reading the environment file. The [hook reference](https://code.claude.com/docs/en/hooks)
describes ENV_FILE and Stop control; this live run supplies the missing evidence.

## OpenCode: compatibility discovery

Run `h "$si35_opencode"` from the same fixture and authenticate within its fresh
profile. Ask it to load the discovered `silta` skill with its native skill tool and
run `silta brief`. Verify a real skill-tool result, not a manual file read. Report
only whether any OPENCODE_* names were present in a child shell, and the observed
actor tool label, without marker/session values. Compatibility discovery is
[documented by OpenCode](https://opencode.ai/docs/skills/) but still needs this run.

## Uninstall and report

Preview `h "$si35_binary" agents uninstall --claude --json`, inspect it, and apply
its token with `h "$si35_binary" agents uninstall --claude --apply <token>`.
Confirm only Silta's owned instructions, skill and hooks disappeared; fresh profile
settings/authentication created by the harnesses remain. Never repair a real profile.

Report harness versions, pass/fail/inconclusive for each check, actual refusal codes
and redacted evidence. Keep auth files and unredacted transcripts out of the repo.
Exit the isolated clients and log out of these temporary profiles before deleting
only the four mktemp directories created above. Do not mark D42's live checks
verified until these results exist.
