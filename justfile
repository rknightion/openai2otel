set shell := ["bash", "-euo", "pipefail", "-c"]

# PLACEHOLDERS: there is no code yet. The first implementation issue replaces setup, fmt, lint and
# test with the real toolchain steps and keeps the recipe names.

# show the task surface
default:
    @just --list

# prepare a clone (placeholder: no code yet)
setup:
    @echo "setup: no code yet"

# format the justfile in place (placeholder: add the language formatter with the first code)
[group('dev')]
fmt:
    just --fmt

# verify the justfile is formatted; never mutates (placeholder: add the language formatter check)
[group('check')]
fmt-check:
    just --fmt --check

# lint the code (placeholder: no code yet)
[group('check')]
lint:
    @echo "lint: no code yet"

# run the tests (placeholder: no code yet)
[group('check')]
test:
    @echo "test: no code yet"

# THE GATE: everything a pull request must pass
[group('check')]
check: fmt-check lint test

# GitHub issues and the rknightion Project; maintainers only (needs the tracker tools and credentials)
[group('tracker')]
[positional-arguments]
tracker *args:
    #!/usr/bin/env bash
    set -euo pipefail
    export TRACKER_REPO=rknightion/openai2otel TRACKER_PROJECT_OWNER=rknightion TRACKER_PROJECT=7
    export TRACKER_ISSUE_IDENTITY=app TRACKER_PROJECT_IDENTITY=user
    exec tracker-with-token "$@"
