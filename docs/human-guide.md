# The human's guide to Silta

Start with a workspace and one task from [Getting started](getting-started.md).
The commands below use the Acme workspace. Replace the names and refs with the
ones Silta shows you.

## See what needs you

Ask your agent “What needs me?” It can read your inbox and relay the items in one
message. To read it yourself, use your own terminal outside the agent's shell.

```sh
silta --ws acme inbox --for me
silta --ws acme inbox --for me --all
```

- **Proposals** are suggested tasks or document revisions for you to review.
- **Questions** are addressed to you. An agent can write a question for `@me`
  on a task when you are away. The inbox also shows answers to your questions
  that are waiting for you to accept them.
- **Blocked work** returns when a follow-up is due, a prerequisite is complete,
  or a dropped prerequisite calls for a new plan. Ask the agent to inspect the
  task and follow up with the named person, unblock ready work, or re-plan.
- **Promoted tasks** point to an external tracker. Follow the named tracker
  for its current status.

The default view shows up to 12 items and recent proposals. Use `--all` to see
the rest, including task proposals older than 14 days. Reading the inbox leaves
its items in place. Check it when you return to a workspace.

## Decide on proposals

Open each proposal before deciding. Accepting a task adds it to the available
backlog. Dropping one closes the proposal. You can decide on several in one
command. For example, after reading tasks `AC-4` and `AC-7`:

```sh
silta --ws acme task show AC-4
silta --ws acme task show AC-7
silta --ws acme task triage --accept AC-4 --drop AC-7
```

For a document, read the proposed revision and its diff. Use the full ref with
its revision number when accepting or rejecting. For example:

```sh
silta --ws acme doc show doc:deploy@2
silta --ws acme doc show doc:deploy@2 --diff
silta --ws acme doc triage --accept doc:deploy@2
```

Some workspaces use the `proposals: ask` policy. In those workspaces the agent
asks in chat before creating unsolicited work.

## Answer a question

In chat, give the agent your answer and ask it to record it on the question.
In your terminal, reply to the question's exact ref. Here `AC-1/2` is a question
on task `AC-1`.

```sh
silta --ws acme comment AC-1 --kind answer --reply-to AC-1/2 -m "Use the test API."
```

The asker can read and accept the recorded answer. The reply stays with the task.

## Approve a command

Commands marked **human-only** in help can be run directly from your own terminal.
When you want the agent to run one, have it name the exact command and refs in
chat. Reply to that message in the same chat with your approval. For example,
after the agent names `silta --ws acme task triage --accept AC-4`, you can reply
“Accept AC-4.” The agent passes your exact words to that command with
`--approved`.

A written answer in Silta belongs to its task thread. Command approval comes
from your reply in the chat where the agent named the command. Keep the approval
to the commands and refs you intend to authorize. If you are away, the agent can
leave a question for `@me` as a reminder to discuss the approval.

## Glossary

- **Proposal** means a suggested task or a proposed document revision waiting for a decision.
- **Triage** means accepting or dropping task proposals, or accepting or rejecting document revisions.
- **Claim** assigns an active task to one agent session so another session can see who is working on it.
- **Handoff** records the task's state, open questions and next step. A handoff by the session holding the claim releases it for the next session.
