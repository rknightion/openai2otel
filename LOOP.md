# Loop: openai2otel
tier: guarded
gate: just check
ci-required: ci-success
tracker: github
landing: pr
grafana-stack: none

No exporter is wired yet, so `grafana-stack` is `none`. Ask the owner which stack before wiring an
exporter or minting a credential, then set the key to that stack's slug.

Run `just` with stdin from `/dev/null`. The recipes other than `tracker` are placeholders until the
first implementation issue replaces them.

## Queue

- The queue is `just tracker queue`: open issues at Status Ready on the rknightion user Project #7.
- A charter selects work by labels and Project fields (Status, Lane, Priority, Effort); a
  `needs-triage` or `needs-owner` issue is never queued.
- Only the root, or the interactive main thread outside a loop, writes issues and the Project, and
  always through `just tracker`. A lane returns the status change and the ticks it wants.
- A queue row names the issue as `#N`. There is no board and no legacy id map.

Maintainers: the working model is `/Users/rob/repos/agent-docs/docs/github-tracker.md` (private).
