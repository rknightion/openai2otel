# openai2otel

An OpenTelemetry exporter for OpenAI organisation usage and cost data, in the same family as the
owner's other `*2otel` exporters. It is a new repository with no code yet. The language, the data it
reads, the signals it emits and how it is deployed are to be settled by the first planning issue;
until then treat every specific in this file as provisional.

## Tracking work

- Work is tracked in GitHub issues in this repository and on the owner's GitHub Project. There is no
  Backlog.md board and there never will be one: do not create `backlog/`, a markdown task list or a
  TODO file to hold work.
- An issue's body is its contract: the outcome, then an `Acceptance criteria` heading with one
  `- [ ] AC1 ...`, `- [ ] AC2 ...` line per criterion, numbered without gaps.
- A new plan is written as issues in that shape. The maintainer's agent creates them through
  `just tracker create`; contributors never need the Project or the tracker tool.
- A pull request that completes an issue says `Closes #N` on a line of its own and fills the
  `Acceptance evidence` table in the pull request template, one row per criterion, copied word for
  word. A change that closes no issue says `Task: none, <reason>` on a line of its own.
- A pull request that changes `.github/workflows/` or `.github/actions/` carries no closing keyword:
  write `Task: none, <reason>` (a plain `Refs #N` beside it is fine).

## Task interface

`just` is the only task surface: never add a `Makefile` or a `scripts/*.sh` runner. The gate is
`just check` (run it with stdin from `/dev/null`); `just setup` prepares a clone. The recipes are
placeholders until the first implementation issue replaces them.
