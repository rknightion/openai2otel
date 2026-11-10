# OpenAI Admin API and Grafana Cloud: live-verified facts

These facts were measured against a real OpenAI organisation and a real Grafana Cloud stack. Where they
disagree with OpenAI's documentation, the live behaviour wins: never "correct" working code to match a
doc. Each fact carries its evidence tag: `[live YYYY-MM-DD]`, or `[spec]` for the OpenAPI spec on
`openai/openai-openapi` `main`. Add new findings with their own tag; never edit an old tag.

## Authentication and scope

*   **Admin keys.** An Admin key (`sk-admin-` prefix) reads every `/v1/organization/*` endpoint used
    here. Project keys cannot. `[live 2026-11-09]`
*   **No per-request list.** No API key can list individual requests. `GET /v1/responses` (a list, no
    id) returns 401 for both key types:
    *   an Admin key gets "Missing scopes: api.responses.read";
    *   a project key gets `missing_scope`: "must be made with a session key (that is, it can only be made
        from the browser)".

    The platform dashboard's request log uses a browser session only. `[live 2026-11-09]`
*   **No rate-limit headers.** Admin routes send no `x-ratelimit-*` headers, only
    `openai-processing-ms`. `[live 2026-11-09]`

## Usage and cost buckets

*   **UTC alignment.** Buckets are floored to UTC boundaries whatever `start_time` is requested. Hourly
    buckets start on the hour, and daily buckets (usage and costs) at 00:00 UTC. The first bucket
    returned contains the requested start. A bucket's start time therefore identifies it.
    `[live 2026-11-10]`
*   **Exact widths.** 3600 seconds for `1h` and 86400 for `1d`. `[live 2026-11-10]`
*   **Default page sizes.** They are small. Hourly usage with no `limit` returns 24 buckets plus
    `has_more: true` and a `next_page` cursor, whereas `limit=168` returns the whole week. Always set
    `limit` (168 for `1h`, 31 for costs `1d`) or follow `next_page`. `[live 2026-11-10]`
*   **Costs.** Costs accept only `bucket_width=1d`. `[spec]`
*   **Completions usage fields.** These include `input_uncached_tokens`, `input_cache_write_tokens`,
    `input_cache_write_30m_tokens`, `input_cache_write_12h_tokens`, and text, audio and image splits of
    input, cached input and output tokens, beyond what older docs list. `[live 2026-11-09]`
*   **Usage endpoints.** `file_search_calls`, `web_search_calls` and `decisions` exist and answer
    with an Admin key. `decisions` returned no rows and its meaning is undocumented. `[live 2026-11-09]`
*   **Cost rows.** Each cost row carries `organization_id`, `organization_name`, `project_id`,
    `project_name`, `user_email` and `user_id`, besides amount, line item and quantity. Names and emails
    are personal or identifying data: logs only, never metric labels. `[live 2026-11-09]`
*   **Cost amounts.** `amount.value` came back as a JSON number, with currency `usd` in lower case.
    Another exporter has seen it as a JSON string, so accept both. `[live 2026-11-09]`

## Limits and settings

*   **No spend limit.** `GET /organization/spend_limit` with no limit set returns 404 `not_found`, "No
    organization spend limit is configured". That means "no limit", not a failure. `[live 2026-11-09]`
*   **Project spend limit.** `GET /organization/projects/{id}/spend_limit` returns `threshold_amount` in
    **cents**, with `currency` in upper case (`USD`), plus `enforcement` and `interval`. Cost amounts are
    in dollars with a lower-case currency, so normalise both. `[live 2026-11-09]` `[spec]`
*   **Rate limits.** `GET /organization/projects/{id}/rate_limits` returns 100 or more model rows for one
    project. That is too many to be metric labels by default. `[live 2026-11-09]`

## Audit logs

*   **Enabling.** Audit logging must be enabled by an org owner, and cannot be turned off again without
    OpenAI support. `[spec]`
*   **Entry shape.** Each entry is `{id, type, effective_at, actor, object, <type>: payload}`.
    `[live 2026-11-09]`
*   **Tenant stream.** `tenant_only=true` returns 401 `tenant_not_found` ("organization does not belong
    to a tenant") for an org outside an enterprise tenant. That means "not applicable", not an auth
    failure. `[live 2026-11-09]`

## Grafana Cloud

*   **No zero injection.** The metric store does not insert a zero sample at an OTLP cumulative series'
    start time. A series pushed once with value 100 is stored as one sample of 100. So the first value of
    a new series is invisible to `increase()` and `rate()`. Report 0 for a new series before its real
    value. `[live 2026-11-10]`
*   **Loki deduplicates identical records.** Loki stores a byte-identical log record sent twice only
    once. A crash re-send is therefore harmless, provided the record is rebuilt identically, with no
    "now" values in its body or attributes. `[live 2026-11-10]`
*   **OTLP JSON.** The OTLP gateway accepts OTLP/HTTP JSON as well as protobuf. `[live 2026-11-10]`
