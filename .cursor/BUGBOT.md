# OpenAI-to-OTel design review

This repository currently defines the design and task interface for an
OpenAI Admin API exporter. Review the architecture and API facts for
consistency. Distinguish proposed behavior from observed API behavior and
keep examples synthetic.

Preserve the read-only polling boundary and separation between credentials
and telemetry. Treat metric and label names as published contracts. Check
that design changes preserve zero initialization for new counters and
byte-identical log retries where the documented delivery model requires them.

Run `just check </dev/null` to verify the current task interface and run
`python3 .github/privacy/sweep --staged` for public changes. CI checks
formatting, acceptance evidence and workflow security. The lint and test
recipes are currently placeholders.
