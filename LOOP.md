# Loop: openai2otel
tier: guarded
gate: just check
ci-required: ci-success
grafana-stack: robknight
tracker: github
landing: pr

Public repository: no hostname, account, organisation, project or key id, tenant id, email or internal
identifier in any tracked file or loop artifact. The design and the work plan are
`docs/architecture.md`; each work package (WP) there is one issue, and its acceptance criteria are the
issue's.

Run `just` with stdin from `/dev/null`.

## Queue

- The queue is `just tracker queue`: open issues at Status Ready on the rknightion user Project #7. The
  Project holds other repositories' issues too, and `queue` returns at most 100 items, so it can omit
  this repository's: a charter selects with `gh issue list -R rknightion/openai2otel --state open` and
  checks Status per issue. Every issue title ends with its work package, `(WPn)`, as in
  `docs/architecture.md`.
- A charter selects work by labels and Project fields (Status, Lane, Priority, Effort); a
  `needs-triage` or `needs-owner` issue is never queued.
- Only the root, or the interactive main thread outside a loop, writes issues and the Project, and
  always through `just tracker`. A lane returns the status change and the ticks it wants.
- A queue row names the issue as `#N`. There is no board and no legacy id map.

Maintainers: the working model is `/Users/rob/repos/agent-docs/docs/github-tracker.md` (private).

## Credentials

- The OpenAI Admin key (read-only use) and the probe project key are read from the maintainer's local
  credentials tree, never copied into the repository, a log, argv or a fixture.
- The Admin key is used only for GET requests. The probe project key is used only by
  `just probe-traffic`, which spends money: only the root or the owner runs it, never a lane.
- Grafana Cloud reads and test pushes use the stored credentials for the `robknight` stack. Only the
  root or the owner reads live Mimir or Loki, deploys to the reference host, or claims `live` evidence.
- Lanes use the fake Admin API (`internal/openai/openaitest`) and committed testdata only.

## Traps

- OpenAI's docs are incomplete and sometimes wrong: `docs/openai-api-gotchas.md` holds the
  live-verified facts. Never "correct" working code to match a doc.
- No back-dated metric samples; logs only within 160 hours (Loki's limit is about 7 days).
- A new counter series must export 0 before its first value (no zero injection in Mimir).
- A re-sent log record must be byte-identical (Loki deduplicates identical records only).
- A work package marked *maintainer* in `docs/architecture.md` (WP1, WP14b, WP25, and running
  `probe-traffic`) is never routed to a lane. A pull request that changes `.github/workflows/` carries
  `Task: none, <reason>`, and the owner closes its issue after merge.
- Usage testdata for WP17 to WP19 is captured by the maintainer with `liveproof capture-usage` before
  the issue goes Ready.
- graph2otel and polylens2otel are AGPL until their relicence to Apache-2.0 lands: never copy code from
  them before that; follow their patterns or port from cf2otel or tailscale2otel.

## Mutexes

- One owner each, per the file ownership table in `docs/architecture.md`: `go.mod`/`go.sum` (WP2, then
  additive `require` lines with `go mod tidy`), `justfile` (WP2, then named recipes only),
  `cmd/openai2otel/collectors_import.go` (one line per collector WP), the frozen seams (`internal/model`,
  `internal/semconv`, `internal/secret`, the `types.go` files, `spec/signal-catalog.json`: WP4, then the
  maintainer), `internal/collector/commit.go` (WP10), `internal/collectors/usage/` layout (WP17).
- One live-API caller at a time, and one Grafana sync at a time.
