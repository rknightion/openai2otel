# openai2otel architecture

*   **Author:** rknightion
*   **Status:** Approved for implementation (revision 3, after the five-stage design review and the readiness re-audit)
*   **Date:** 2026-11-10

--------------------------------------------------------------------------------

## Overview

openai2otel is a Go exporter in the `*2otel` family. It reads the OpenAI Administration API with one
Admin API key per OpenAI organisation, for a configured list of organisations, and sends
OpenTelemetry metrics and logs to Grafana Cloud over OTLP.

v1 covers costs, ten usage endpoints, audit logs, a trimmed admin inventory and spend limits. Its main
difference from existing tools is how it handles OpenAI revising figures after the fact:

*   **Re-reading.** On every poll it re-reads a trailing window (the last 6 days).
*   **Counting.** It stores the last value it saw for each bucket, and adds any increase to a counter and
    any decrease to a matching corrections counter.
*   **Durable totals.** The running totals live in a state file, and metrics are reported from that file.
    So a restart neither loses nor double-counts, and no metric sample is ever back-dated.
*   **Lateness.** It measures how late OpenAI revises each kind of data, so the window length rests on
    evidence.

Counters converge on OpenAI's figures only for revisions inside the window. A month-to-date cost gauge,
recomputed on every poll, also reflects revisions older than that.

It ships as a container image with a Docker compose reference deployment, one generated Grafana
dashboard, five generated alert rules, and a scheduled check that compares the latest OpenAI OpenAPI
spec with the operations the exporter uses. v1 emits no traces.

## The Problem

An OpenAI API platform admin who wants usage, cost and admin activity in Grafana Cloud has no complete
option today:

*   **No push.** OpenAI pushes no telemetry for API platform organisations; everything has to be polled.
*   **Narrow tools.** The one open-source OTLP exporter reads two endpoints. Others expose Prometheus
    only, and none ships audit logs as OTLP logs.
*   **Undercounting.** Every existing exporter reads each usage or cost bucket once. OpenAI keeps revising
    buckets after they close (usage for hours; cost publication was delayed for days in October 2026), so
    every existing tool undercounts and none can say by how much.
*   **Restarts.** Most tools keep state in memory, so a restart recounts or skips data.
*   **Thin docs.** Live probing found fields and endpoints the older docs omit, and cost rows that carry
    user emails ([evidence](openai-api-gotchas.md)).

The solution is a poller whose counting is correct under revision, restart and outage, with every
OpenAI field placed deliberately on a metric, a log, or nowhere.

## Glossary

| Term | Meaning |
| --- | --- |
| Bucket | One time slot of OpenAI data: 1 hour for usage, 1 UTC day for costs. OpenAI floors buckets to UTC hour or day boundaries whatever start time is requested, so a bucket's start time identifies it. |
| Series | One metric plus one set of label values, for example cost for project p1 and line item "gpt-5, input". |
| Window | The buckets re-read on every poll: the last 6 daily cost buckets including today, and the last 144 hourly usage buckets including the current hour. |
| Revision | A change to a bucket's value after openai2otel first saw it. |
| Gross, corrections, net | Gross is the sum of every increase seen. Corrections is the sum of every decrease. Net is gross minus corrections, and every panel and alert uses net. |
| Baseline | Recording current values as already seen, without adding them to totals. It is used on first start and when saved state can no longer be trusted. |
| Zero-priming | A new counter series reports 0 until one metric export containing it has succeeded, because Grafana Cloud's metric store ignores the first value of a new series in `increase()` and `rate()`. |
| Delivered digest | A hash of a log row's content, saved once Loki has acknowledged that row. A row whose digest differs from the delivered one is sent again. |
| Line item | OpenAI's cost category, for example a model plus token kind. |
| Probe project | A spend-limited OpenAI project used only to generate small, known traffic for live checks. |
| Reference host | The maintainer's machine that runs the compose deployment for live verification. |
| `codex/` | A machine-local agent working directory, ignored by git. It is unrelated to OpenAI's Codex product. |

Repository and contribution terms (`Task: none`, closing keywords, the privacy sweep) are defined in
[CONTRIBUTING.md](../CONTRIBUTING.md). `ci-success` is the CI job that passes only when every required
check passes; it is the one required status check on pull requests.

## Goals

*   **G1 Costs.** Cost per org, project and line item:
    *   a gross counter and corrections counter for rates and alerts;
    *   a month-to-date gauge recomputed every poll;
    *   one log record per closed daily bucket change, for per-day figures.
*   **G2 Usage.** Ten usage endpoints, each proved live with probe traffic: completions, embeddings,
    moderations, images, audio speeches, audio transcriptions, vector stores, code interpreter sessions,
    file search calls and web search calls. Additive fields become counter pairs; vector store bytes
    become a gauge.
*   **G3 Audit.** Every audit event appears exactly once in Loki, at its real time.
*   **G4 Inventory (trimmed).** Counts of projects, users by role, service accounts, and admin and
    project API keys; the soonest key and certificate expiry; spend limits.
*   **G5 Correct counting.** A restart or crash at any point neither loses nor double-counts a counted
    increase, and no counted series loses its first increment.
*   **G6 Multi-org.** One process watches a list of orgs. Each is isolated, with its own key, state, rate
    limiter and failure status.
*   **G7 Bounded labels.** Metric labels are fixed. Per-user, per-key and other ids go to logs only.
*   **G8 Operable.** Self-telemetry, a `check` preflight, strict config, a healthcheck, one dashboard,
    five alerts, and the compose deployment.
*   **G9 Drift detection.** A scheduled job fetches the latest `openai/openai-openapi` `main` spec and
    reports changes to what openai2otel consumes.
*   **G10 Revision evidence.** The exporter measures how late revisions arrive, including revisions
    beyond the window, so the window default can be tuned.

Success measures (owner-approved):

1.  Month-to-date cost per org and project (gauge) equals the costs endpoint's month-to-date sum, to the
    cent.
2.  Per-day cost from the latest bucket log per day equals the costs endpoint, to the cent, once the day
    stops changing within the window.
3.  Every audit event in the probe org appears exactly once in Loki.
4.  Crash-point tests prove that a restart at any step of the commit sequence neither loses nor
    double-counts a counted increase, and that every new series is zero-primed.

Freshness is a dashboard panel, not a pass or fail measure.

## Non-Goals

*   **Traces.** The Admin API has no per-request feed, and the portal's request list
    (`GET /v1/responses`) accepts only a browser session key (live-confirmed). openai2otel never creates
    spans from data it does not have. Real per-request traces come from client-side instrumentation,
    documented as a companion setup. The exporter's own poll spans are deferred.
*   **Out of scope:**
    *   Hosted Agents API traces and ChatGPT Compliance Logs: documented as unsupported.
    *   Proxying or instrumenting inference traffic.
    *   A shared Go module across sibling exporters.
*   **Later phases, not v1:**
    *   **Project-key sources:** stored Chat Completions, batches, fine-tuning jobs, files and vector
        store inventory, together with the content-capture switch.
    *   **Inventory and limits:** rate-limit gauges and headroom; the full inventory; inventory logs per
        entity.
    *   **Deployment:** the Helm chart.
    *   **Audit:** the `tenant_only` audit stream, for orgs inside an enterprise tenant.
    *   **Usage:** the `decisions` usage endpoint, whose meaning is unknown and which returns no data.
    *   **Cardinality:** a hard series cap. v1 has fixed labels, a live series gauge and a config lever
        instead.
*   **Never:**
    *   Back-dated metric samples, because Grafana Cloud's metric store accepts samples at most about 2
        hours out of order.
    *   A date-range backfill mode.

## Open Questions

*   **Q1 Revision lateness.** How late does OpenAI revise usage and cost buckets? It is measured in
    production by G10. The 6-day window is the starting value.
*   **Q2 Admin rate limits.** Undocumented, and admin routes send no `x-ratelimit-*` headers. The
    defaults are conservative and are tuned from `openai2otel.api.requests` by class.
*   **Q3 Audit publication lateness.** How long after `effective_at` an event becomes readable. It is
    measured by `openai2otel.audit.lateness`, and the 1-hour overlap is tuned from it.
*   **Q4 Cost amounts.** Whether negative amounts or currencies other than USD occur. Both are handled
    generically: a negative increase is a correction, and currency is a label. Observed in production.

Answered during design, with evidence in [openai-api-gotchas.md](openai-api-gotchas.md):

*   **Bucket alignment.** Buckets are floored to UTC boundaries.
*   **Default page sizes.** Hourly usage returns only 24 buckets without an explicit `limit`.
*   **Grafana zero injection.** Grafana Cloud's metric store does not insert a zero at the OTLP start
    time.
*   **Loki duplicates.** Loki stores byte-identical re-sent records once.
*   **Org identity.** Cost rows carry `organization_id`.
*   **Spend limit units.** Amounts are in cents.
*   **No spend limit.** With none set, the endpoint returns 404.
*   **Tenant stream.** It returns `tenant_not_found` for orgs outside a tenant.

## Critical User Journeys (CUJs)

### CUJ 1: First install against one org

*   **Given**: an Admin key in a file, Grafana Cloud OTLP credentials, a writable state directory.
*   **When**: the operator runs `openai2otel check`, then starts the compose deployment.
*   **Then**:
    *   **Preflight:** `check` prints one line per endpoint family, either OK or a one-line fix.
    *   **First start:** the exporter baselines the window, so no spend spike appears. It sends one log per
        closed bucket in the window, so per-day history is visible at once.
    *   **Data:** cost, usage and audit data reach Grafana within one poll cycle.

### CUJ 2: OpenAI revises a cost

*   **Given**: the exporter has seen a daily cost bucket at $10.00.
*   **When**: OpenAI revises it to $12.00, then to $11.00, within the window.
*   **Then**:
    *   **Counters:** gross rises by 2.00 and corrections by 1.00, so net is 11.00.
    *   **Logs:** each closed-bucket change produces one log record, carrying the value and the time it was
        observed.
    *   **Lateness:** the revision lateness histogram records both revisions.
    *   **Gauge:** the month-to-date gauge shows the new total on the next poll.

### CUJ 3: Crash and restart

*   **Given**: the exporter is mid-poll for two orgs.
*   **When**: the process is killed at any point and restarted, including a container recreate.
*   **Then**:
    *   **Counters:** totals resume from the state file under the same series identity, so no counted
        increase is lost or doubled and Grafana sees no counter reset.
    *   **Logs:** any unacknowledged log rows are re-sent byte for byte, and Loki keeps one copy.

### CUJ 4: Add a second org

*   **Given**: a running exporter for one org.
*   **When**: the operator adds a second `orgs[]` entry and restarts.
*   **Then**:
    *   **New org:** it gets its own state and baseline, and the first org is unchanged.
    *   **Duplicate key:** if the new key turns out to belong to an org already listed, the later entry is
        disabled with an error log and capability 0. The process keeps running.

### CUJ 5: Investigate a high-risk admin action

*   **Given**: audit logging is on.
*   **When**: someone creates an API key or deletes a user.
*   **Then**: within one poll interval a log record appears in Loki at the event's real time, exactly once,
    and the high-risk audit alert fires. This works even for the first event of that type ever seen.

### CUJ 6: OpenAI changes its API

*   **Given**: the scheduled drift job runs against the latest spec.
*   **When**: OpenAI adds, removes or retypes a field or parameter that openai2otel consumes.
*   **Then**: the job opens or updates one issue naming the operation and change. `just check` never
    fetches the OpenAI spec.

## Technical Plan (Architecture)

### Shape of the system

```text
 one process, N orgs (each org fully isolated)
 +--------------------------------------------------------------------------+
 | per org, per collector:                                                  |
 |   scheduler -> collector (costs | usage | audit | inventory)             |
 |                  |  openai client: GET only, explicit page limits,       |
 |                  |  retry with Retry-After, per-org token bucket          |
 |                  v                                                       |
 |               bucketstate.Reconcile (pure)  -> new state                 |
 |                  v                                                       |
 |   commit:  1. save state file (atomic)        state/<org>/<name>.json    |
 |            2. producer sees new totals   ------------> OTLP metrics      |
 |            3. export pending log rows    ------------> OTLP logs         |
 |            4. on ack: mark rows delivered, save state again              |
 +--------------------------------------------------------------------------+
   every 60s the metric reader pulls totals from the producer (zero-primed)
```

Counters are read from saved state, not added up in memory. A poll computes the new totals and saves
them, and the metric exporter reports whatever is saved. Log rows are delivered separately: a row stays
pending in the state file until Loki acknowledges it.

### Lineage and reuse

openai2otel is a fresh Go module (`github.com/rknightion/openai2otel`, Go 1.27, OTel Go 1.47). It ports
named files with a `derived from <repo>@<commit>` header. Nothing is shared as a module.

**Licensing.** openai2otel, cf2otel and tailscale2otel are Apache-2.0. graph2otel and polylens2otel are
currently AGPL-3.0, and their owner is relicensing both to Apache-2.0, tracked in each repository.
Until that lands, nothing is copied from them: the graph2otel rows below are patterns to follow, and a
lane writes them fresh, or ports the equivalent from cf2otel or tailscale2otel.

| From | What |
| --- | --- |
| [graph2otel](https://github.com/rknightion/graph2otel) | Composition root (`run(ctx, args, stdout, stderr) int`); the collector registry with typed interfaces; the Emitter facade with an org decorator (graph2otel's `WithTenant` stamps a tenant attribute on every signal); strict koanf config with a redacting `Secret` type; the startup write probe of the state directory; two OTLP resources (metrics carry no `service.version`, so a deploy does not start new series). |
| [cf2otel](https://github.com/rknightion/cf2otel) | TTL snapshot gauges: a gauge reported only while its last snapshot is younger than 3 poll intervals, so a stopped collector shows "unknown", not "healthy". |
| [tailscale2otel](https://github.com/rknightion/tailscale2otel) | `internal/httpretry` (Retry-After parsing, jittered backoff, token bucket); `internal/telemetry/export_ack.go` (a per-batch export result classed permanent or transient, including OTLP partial success); `internal/collector/atomicfile.go` (temp file, fsync, rename, directory fsync); the `flock` lock from `internal/ingresswal/platform_unix.go`; the `tailnets[]` config shape for `orgs[]`; the `internal/oas` approach for the drift tool. |
| [polylens2otel](https://github.com/rknightion/polylens2otel) | `internal/configdoc`: `config.example.yaml` and `docs/env-vars.md` generated from struct tags. |

### Packages

| Package | Job |
| --- | --- |
| `cmd/openai2otel` | Composition root and subcommands: `run` (default), `check`, `once`, `healthcheck`, `version`. |
| `internal/model` | Shared types used across packages (frozen first; see "Frozen seams"). |
| `internal/semconv` | Every metric, log event and attribute name, unit and description; the usage field table. |
| `internal/secret` | The redacting `Secret` type. |
| `internal/config` | Config load (defaults, YAML, env), strict validation, `orgs[]`. |
| `internal/openai` | Read-only Admin API client: request building, pagination, error classes, retry, rate limit, exact money decoding. |
| `internal/openai/openaitest` | A shared fake Admin API server for tests, with scripted bucket timelines. |
| `internal/bucketstate` | Pure counting core: reconcile, baseline, zero-priming state, delivered digests. No I/O. |
| `internal/statestore` | State files: atomic write, single-writer lock, schema version, write probe, process identity. |
| `internal/telemetry` | OTLP providers, the state-backed metric producer, the acknowledged log sender, Emitter, horizon guard, snapshot gauges, self-telemetry. |
| `internal/collector` | Registry, per-org scheduler, the commit sequence (`commit.go`). |
| `internal/collectors/{costs,usage,audit,inventory}` | One package per data family. |
| `tools/probetraffic` | Makes small real API calls on the probe project (spends money, maintainer only). |
| `tools/liveproof` | Read-only checks of success measures 1 to 3 against OpenAI, Mimir and Loki. |
| `tools/apidrift` | The scheduled drift check. |

### Frozen seams

WP4 creates these types and compile-only stubs, so parallel lanes code against stable interfaces. The
signatures below are Go and form the contract. After WP4 merges, changing them needs the maintainer.
The package import order is `model` <- `openai` <- `bucketstate` <- `telemetry` <- `collector`. No
package imports a later one.

```go
// internal/model
type OrgID string     // config slug, [a-z0-9-]{1,32}
type SeriesKey string // metric + "{" + sorted k=strconv.Quote(v) pairs joined by "," + "}"
func NewSeriesKey(metric string, labels map[string]string) SeriesKey
func (k SeriesKey) Parse() (metric string, labels map[string]string, err error) // exact inverse
type BucketStart int64 // UTC Unix seconds of the bucket start; never a time.Time map key
type Window struct{ From, To BucketStart } // From = oldest bucket start in window; To = end of current bucket
type Point struct{ Series SeriesKey; Bucket BucketStart; Value decimal.Decimal }
type LogRow struct {
    Key   string            // stable identity: "<name>|<series>|<bucket>" or "audit|<event id>"
    Time  time.Time         // record timestamp: bucket start, or audit effective_at (UTC)
    Event string            // log event name from semconv
    Attrs map[string]string // every attribute, already formatted; no "now" values
    Body  string
}

// internal/openai (WP4 declares types and method signatures; method bodies return ErrNotImplemented until WP5)
type Client struct{ /* WP5 */ }
type UsageQuery struct{ Start, End BucketStart; GroupByModel bool } // bucket width fixed per call site
type UsageBucket struct{ Start, End BucketStart; Results []UsageResult }
type UsageResult struct{ ProjectID, Model *string; Fields map[string]decimal.Decimal } // every numeric field by JSON name
type CostBucket struct{ Start, End BucketStart; Results []CostResult }
type CostResult struct{ ProjectID, ProjectName, LineItem, OrganizationID, QuantityUnit *string; Amount Amount; Quantity *decimal.Decimal }
type Amount struct{ Value decimal.Decimal; Currency string } // currency lower-cased on decode
type AuditEvent struct{ ID, Type string; EffectiveAt int64; ProjectID *string; Actor, Payload json.RawMessage }
type Project struct{ ID, Name, Status string }
type User struct{ ID, Role string }
type APIKey struct{ ID string; ExpiresAt, LastUsedAt *int64 }
type Certificate struct{ ID string; ExpiresAt *int64 } // from certificate_details.expires_at
type SpendLimit struct{ Dollars decimal.Decimal; Currency string } // threshold_amount cents / 100, currency lower-cased
func (c *Client) Usage(ctx context.Context, endpoint string, width string, q UsageQuery) (b []UsageBucket, complete bool, err error)
func (c *Client) Costs(ctx context.Context, start, end BucketStart) ([]CostBucket, bool, error)
func (c *Client) AuditLogs(ctx context.Context, since time.Time, until *time.Time) ([]AuditEvent, bool, error)
func (c *Client) Projects(ctx context.Context) ([]Project, bool, error)
func (c *Client) Users(ctx context.Context) ([]User, bool, error)
func (c *Client) AdminAPIKeys(ctx context.Context) ([]APIKey, bool, error)
func (c *Client) ProjectAPIKeys(ctx context.Context, projectID string) ([]APIKey, bool, error)
func (c *Client) ProjectServiceAccounts(ctx context.Context, projectID string) (count int, complete bool, err error)
func (c *Client) Certificates(ctx context.Context) ([]Certificate, bool, error)
func (c *Client) OrgSpendLimit(ctx context.Context) (*SpendLimit, error)                    // nil, nil on 404
func (c *Client) ProjectSpendLimit(ctx context.Context, projectID string) (*SpendLimit, error) // nil, nil on 404
var ErrNotImplemented = errors.New("not implemented")
func ClassOf(err error) string // closed set: timeout, rate_limited, quota, unauthorised, not_found, server, invalid, other

// internal/bucketstate
type Totals struct{ Gross, Corrections decimal.Decimal; Start, FirstSeen time.Time; Primed, CorrPrimed bool }
type Pending struct{ Row model.LogRow; Digest string; ObservedAt time.Time }
type Delivered struct{ Digest string; Time time.Time } // Time = Row.Time, used for pruning
type State struct {
    Schema         int
    Org            model.OrgID
    Name           string // costs | usage-<endpoint> | audit | lookback-usage
    Fingerprint    string
    OrganizationID string
    Watermark      time.Time // audit only
    Buckets        map[model.SeriesKey]map[model.BucketStart]decimal.Decimal
    Totals         map[model.SeriesKey]*Totals
    Pending        map[string]Pending   // by LogRow.Key
    Delivered      map[string]Delivered // by LogRow.Key
    Lookback       map[string]string    // beyond-window row key -> digest
}
const (ReasonFirstStart = "first_start"; ReasonFingerprint = "fingerprint"; ReasonCorrupt = "corrupt"; ReasonOrgChanged = "org_changed")
type LateObs struct{ Endpoint, Direction string; Age time.Duration; BeyondWindow bool }
type Stats struct{ Increases, Decreases int; Late []LateObs; Rebaselined string }
func Reconcile(prev *State, w model.Window, pts []model.Point, rows []model.LogRow, complete bool, now time.Time) (*State, Stats)
func Baseline(prev *State, reason, fingerprint string, w model.Window, pts []model.Point, rows []model.LogRow, now time.Time) (*State, Stats) // prev nil on first start
func CountEvents(prev *State, events []model.LogRow, seriesOf func(model.LogRow) model.SeriesKey, now time.Time) (*State, Stats)
func Prune(s *State, w model.Window, horizon, overlap time.Duration, now time.Time)
func Digest(r model.LogRow) string // SHA-256 over Event, Time, Attrs (sorted), Body, computed BEFORE observed_at is added

// internal/telemetry
type GaugePoint struct{ Value float64; Attrs map[string]string }
type Emitter interface {
    Count(name string, v float64, attrs map[string]string)                   // self-telemetry counters
    Record(name string, v float64, attrs map[string]string)                  // self-telemetry histograms
    Gauge(name string, v float64, attrs map[string]string)                   // self-telemetry gauges
    GaugeSnapshot(name string, ttl time.Duration, points []GaugePoint)       // replaces the whole series set; cf2otel snapshot.go shape
    Log(ctx context.Context, row model.LogRow)                               // non-durable logs only (startup, rebaselined, revision.late)
}
type PrimeLedger interface {
    MarkPrimed(org model.OrgID, name string, keys []model.SeriesKey, corrections bool)
    Primed(org model.OrgID, name string, key model.SeriesKey) (primed, corrPrimed bool)
} // mutex-guarded; written by the metric exporter wrapper, read by commit and the producer
type TotalsSource interface{ Publish(s *bucketstate.State) } // the producer keeps an immutable copy per (org, name)
type LogSender interface {
    Send(ctx context.Context, org model.OrgID, rows []bucketstate.Pending) (acked, permanent []string, err error)
}

// internal/collector
type CheckResult struct{ Endpoint string; OK bool; Fix string }
type Collector interface {
    Name() string
    Interval() time.Duration
    Check(ctx context.Context, d OrgDeps) []CheckResult
    Poll(ctx context.Context, d OrgDeps) error
}
type StateStore interface {
    Load(org model.OrgID, name string) (*bucketstate.State, error) // ErrNotFound, ErrCorrupt, ErrNewerSchema
    Save(s *bucketstate.State) error
}
type Committer interface {
    Last(org model.OrgID, name string) *bucketstate.State // last published copy; disk only on first load
    Commit(ctx context.Context, prev, next *bucketstate.State, st bucketstate.Stats) error
}
type OrgIdentity interface{ Report(org model.OrgID, organizationID string) } // registry disables a later duplicate
type OrgDeps struct {
    Org      model.OrgID
    Client   *openai.Client
    Store    StateStore
    Commit   Committer
    Emit     telemetry.Emitter
    Identity OrgIdentity
    Now      func() time.Time
}
```

`Reconcile`, `Baseline` and `CountEvents` never mutate `prev`. Each returns a deep copy, because the
state is made of maps. WP4 also commits `internal/seams_test.go`, a compile-only assertion file that
references every symbol above (`var _ = bucketstate.Reconcile`, and so on).

### The counting core (`bucketstate`)

**Reconcile, per poll and per endpoint:**

1.  **Read.** The collector reads every page for the window, then:
    *   sums raw rows into points (series and bucket);
    *   builds a log row per (series, bucket);
    *   passes `complete=false` if any page failed, in which case `Reconcile` returns a copy of `prev`
        unchanged.
2.  **Delta.** For each (series, bucket) in the window, `delta = new - last`. A series missing from a
    bucket counts as 0 only when `complete` is true.
    *   `delta > 0` adds to `Gross`.
    *   `delta < 0` adds `-delta` to `Corrections`.
    *   The bucket memory becomes `new`.
    *   A new series gets a `Totals` entry with `Start = FirstSeen = now` and both primed flags false.
3.  **Eviction.** Buckets older than `w.From` leave `Buckets`. Totals are never deleted.
4.  **Log rows.** For each log row whose bucket is closed (bucket end at or before `now`):
    *   `Digest(row)` is computed on the row as built, before `observed_at` is added.
    *   If the digest differs from `Delivered[key].Digest` and from any `Pending[key].Digest`, the row is
        stored in `Pending` with `ObservedAt = now`.
    *   Its `Attrs["observed_at"]` is then set once to that time (RFC 3339 UTC). A re-send is
        byte-identical, and Loki keeps one copy.
5.  **Lateness.** Each change appends a `LateObs` (age = `now - bucket end`, direction `increase` or
    `decrease`).
6.  **Pruning.** `Prune` removes `Delivered` entries whose `Time` is older than `w.From` minus the
    160-hour horizon, and for audit, older than `Watermark - overlap`. It also removes `Lookback` keys
    from before the current UTC month.
7.  **Money** is `shopspring/decimal`. `amount.value` is decoded from a JSON number or a JSON string.

Net is exact for any sequence of values. For example, 10, then 12, then 11 gives gross 12,
corrections 1 and net 11.

**Counting events (audit).** `CountEvents` adds 1 to `Gross` of `seriesOf(row)` for each event whose key
is in neither `Delivered` nor `Pending`, puts the row in `Pending`, and never records corrections.

**Zero-priming.**
*   **Export.** The metric producer exports a series' total only when its `Primed` flag is set, either
    in saved state or in the `PrimeLedger`. Otherwise it exports 0. Corrections use `CorrPrimed` the
    same way.
*   **Marking primed.** The metric exporter wrapper calls `PrimeLedger.MarkPrimed` for every series in a
    batch that exported successfully.
*   **Saving.** Step 1 of each commit copies the ledger's flags into `next` before saving, so the flags
    persist.
*   **Restarts.** A restart before that save simply primes again. The cost is up to one 60-second export
    interval of delay.

**Baseline.** These cases call `Baseline` instead of `Reconcile`. `Stats.Rebaselined` carries the reason.

| Case (reason) | Bucket memory | Totals | Log rows | What Grafana sees |
| --- | --- | --- | --- | --- |
| No state file (`first_start`, `prev` nil) | Seeded from the window | None yet | Every closed bucket in the window pending once | New series, zero-primed |
| Fingerprint changed (`fingerprint`): window, `group_by`, model label or field table version | Re-seeded | Copied from `prev`; unchanged series keys continue | Pending only where the digest differs from `prev.Delivered` | No reset |
| Corrupt file (`corrupt`, WP7 moves it aside as `<name>.corrupt-<unix>`, `prev` nil) | Seeded | Lost | Every closed bucket pending | A counter reset; `increase()` handles it, and the gap is not counted |
| `organization_id` differs (`org_changed`; WP7 archives every file of that org, `prev` nil) | Seeded | Started fresh | Every closed bucket pending | A counter reset |
| Newer schema (`ErrNewerSchema` from WP7) | none | none | none | `run` scans every state file at startup and exits 1 |

**Fingerprint.** A SHA-256 over the endpoint, bucket width, the `group_by` list, the window bucket
count, the model-label setting and the semconv field table version.

### State on disk (`statestore`)

*   **Layout.**
    *   `state/identity.json` holds `{"service_instance_id": "<uuid>", "created": "<rfc3339>"}` and is
        created once.
    *   `state/<org>/<name>.json` holds the `State` as JSON. Decimals are strings, times are RFC 3339 UTC,
        and `BucketStart` keys are decimal Unix seconds.
*   **Writes.** Each save writes a temp file, fsyncs it, renames it and fsyncs the directory. Files are
    mode 0600. This is ported from tailscale2otel `internal/collector/atomicfile.go`.
*   **Lock.** `state/.lock` is held for the process lifetime with `unix.Flock(LOCK_EX|LOCK_NB)`, as in
    tailscale2otel `internal/ingresswal/platform_unix.go`. The kernel releases it if the process dies, so
    a crash never blocks a restart. A second process exits 1 with "state directory in use".
*   **Startup probe.** A write-then-remove probe runs at startup; a failure exits 1.
*   **`Load` sentinel errors.** `ErrNotFound`, `ErrCorrupt` (after moving the file aside) and
    `ErrNewerSchema`.
*   **Size.** Usage is about 144 buckets times the active series per endpoint. `Delivered` adds about
    one entry per series per hour inside the horizon. Costs are about 6 buckets times the series.
    `openai2otel.state.bytes` reports the total.

### Commit sequence (`internal/collector/commit.go`)

The collector gets `prev` from `Committer.Last` (which reads the disk only on first load), builds
`next` with `Reconcile`, `Baseline` or `CountEvents`, and calls `Commit(ctx, prev, next, stats)`.

1.  **Persist.** Merge the `PrimeLedger` flags into `next`, call `Prune`, then `Save(next)`.
    *   If the save fails, the poll fails, `openai2otel.state.persist_errors` rises, and the published
        copy stays at `prev`, so metrics never run ahead of disk.
    *   Otherwise `stats` are recorded as self-telemetry: revisions, lateness and rebaselines.
2.  **Publish.** `TotalsSource.Publish(deep copy of next)`. Metrics report the new totals at the next
    60-second collection.
3.  **Send logs.** Pending rows go to `LogSender.Send` in batches of up to 500.
    *   Acknowledged rows move to `Delivered`.
    *   Permanently rejected rows move to `Delivered` and increase
        `openai2otel.logs.dropped{reason="rejected"}`.
    *   Transient failures leave rows pending, to be retried at the next poll.
4.  **Horizon.** Pending rows whose `Time` is older than 160 hours move to `Delivered`, with
    `logs.dropped{reason="horizon"}`.
5.  **Re-save.** If anything moved, save and publish again.

**Crash safety.** A crash between steps 1 and 5 re-sends the pending rows byte for byte after restart,
and Loki keeps one copy. Counters were committed in step 1, so a log outage never stalls metrics.

**Isolation.** Each org runs its own commit sequence. There is no process-wide lock, and the producer
and ledger use their own mutexes, so commits never block each other.

**Audit watermark.** The audit collector advances `next.Watermark` only to the newest event that is
already in `Delivered`, and never after an incomplete read.

### Metric export from saved state (`telemetry`)

*   **Producer.** A `metric.Producer` on a 60-second periodic reader turns each published copy into
    cumulative sums. The value is `Gross`, or `Corrections` for the `.corrections` twin, or 0 while the
    series is not yet primed. The start time is the series' saved `Start`.
*   **Resource.** The metrics resource and the logs resource are identical:
    `service.name="openai2otel"`, `service.namespace` (config, default `openai2otel`) and the persisted
    `service.instance.id`. Neither carries `service.version`, so a re-sent log stays byte-identical across
    an upgrade and a deploy does not start new metric series. The version lives on
    `openai2otel.build.info`.
*   **Exporter wrapper.** It wraps the OTLP metric exporter, and on a successful export calls
    `PrimeLedger.MarkPrimed`.
*   **Other metrics.** Self-telemetry and snapshot gauges use ordinary SDK instruments on the same
    provider.

**Log sender.** It ports `permanentHTTPStatus`, `permanentExportRejection`, `classifyExportResult`,
`sdkPartialSuccessLeaf` and `validatingACKTransport` from tailscale2otel
`internal/telemetry/export_ack.go`. It adapts them, leaving out the TLS and `safefile` helpers that file
also uses.

| Result | Class | Effect |
| --- | --- | --- |
| HTTP 2xx, no partial success | acknowledged | Rows move to `Delivered` |
| HTTP 400, 404, 413 or any other 4xx except 401, 403, 408 and 429 | permanent | Dropped (`rejected`) |
| OTLP partial success with rejected records | transient | Retried, matching the sibling's fail-closed rule; the horizon eventually drops it |
| 401, 403 | transient | Retried; `openai2otel.export.errors{class="unauthenticated"}` |
| 408, 429, 5xx, timeout, connection error | transient | Retried next poll |

**Records** are built through a `LoggerProvider` whose only processor is a synchronous capture
processor. It clones each record, so the record carries the resource and scope. The sender then calls
the OTLP log exporter's `Export` directly with the captured records, and so gets one result per batch.
Each record's `ObservedTimestamp` is `Pending.ObservedAt`.

### Data families

**Costs** (`/organization/costs`, every 5 minutes)

*   **Read.** One read per poll: `bucket_width=1d`, `group_by=project_id&group_by=line_item`, `limit=31`.
    It runs from the earlier of the UTC month start or the window start, up to now. The current day is
    included.
*   **Counters.** Rows inside the window feed `Reconcile`. The series is `openai.cost` with labels org,
    project, line item and currency (lower-cased).
*   **Month-to-date gauge.** All rows since the UTC month start set `openai.cost.month_to_date` (labels org,
    project, currency). It is recomputed each poll with no memory, so it reflects revisions older than
    the window.
*   **Beyond the window.** Rows from the month start up to the window start are digested into `Lookback`.
    A change emits an `openai2otel.revision.late` log, stamped at the observation time and carrying
    `bucket_start`, old and new value. It also records `openai2otel.revision.lateness{beyond_window="true"}`.
    These rows are never counted.
*   **Logs.** One `openai.cost.bucket` record per closed bucket change, stamped at the bucket start. It
    carries value, project id and name, line item, quantity, quantity unit, `observed_at` and
    `bucket_end`.
*   **Org identity.** The first cost row seen sets `OrganizationID`. A later different value triggers the
    `org_changed` baseline. Until a cost row exists, `OrganizationID` stays empty and is not checked.

**Usage** (ten endpoints, one table-driven collector, every 5 minutes)

*   **Read.** `bucket_width=1h`, `limit=168`, `group_by=project_id`.
    *   **Model grouping.** `group_by=model` is added when `collectors.usage.model_label` is true (the
        default) and the endpoint accepts it. Completions, embeddings, moderations, images, audio speeches,
        audio transcriptions and web search calls accept it. Vector stores, code interpreter sessions and
        file search calls do not.
    *   **Decoding.** Each endpoint is decoded with its own result shape, because the `object` value of
        some results (file search, web search) differs from the endpoint name.
*   **Logs.** Logs and metrics share this grain. Log rows carry every numeric field on the row, including
    the cache-write and modality token splits. They do not carry service tier, batch or API source,
    because those are `group_by` dimensions that are not requested.
*   **Field table.** The usage field table in `semconv` classifies each field:

| Endpoint | Field | Class | Metric |
| --- | --- | --- | --- |
| completions | `input_uncached_tokens` (else `input_tokens - input_cached_tokens - input_cache_write_tokens`, absent fields as 0) | additive | `openai.usage.tokens{openai.token.type="input_uncached"}` |
| completions | `input_cached_tokens` | additive | `openai.usage.tokens{openai.token.type="cached_input"}` |
| completions | `input_cache_write_tokens` (absent as 0) | additive | `openai.usage.tokens{openai.token.type="cache_write"}` |
| completions | `output_tokens` | additive | `openai.usage.tokens{openai.token.type="output"}` |
| completions | `num_model_requests` | additive | `openai.usage.requests` |
| completions | `input_tokens`, `input_cache_write_30m_tokens`, `input_cache_write_12h_tokens`, `input_text_tokens`, `input_audio_tokens`, `input_image_tokens`, `input_cached_text_tokens`, `input_cached_audio_tokens`, `input_cached_image_tokens`, `output_text_tokens`, `output_audio_tokens`, `output_image_tokens` | log only | none |
| embeddings, moderations | `input_tokens` | additive | `openai.usage.tokens{openai.token.type="input_uncached"}` |
| embeddings, moderations | `num_model_requests` | additive | `openai.usage.requests` |
| images | `images` | additive | `openai.usage.images` |
| images | `num_model_requests` | additive | `openai.usage.requests` |
| audio_speeches | `characters` | additive | `openai.usage.audio.characters` |
| audio_speeches, audio_transcriptions | `num_model_requests` | additive | `openai.usage.requests` |
| audio_transcriptions | `seconds` | additive | `openai.usage.audio.seconds` |
| vector_stores | `usage_bytes` | level | `openai.usage.vector_store.bytes` (gauge, latest bucket) |
| code_interpreter_sessions | `num_sessions` | additive | `openai.usage.sessions` |
| file_search_calls, web_search_calls | `num_requests` | additive | `openai.usage.tool_calls` |
| web_search_calls | `num_model_requests` | log only | none |

*   **Token types.** The four token types partition input and output, so their sum equals
    `input_tokens + output_tokens`. The spec's `input_tokens` includes cached and cache-write tokens.
*   **Unverified field names.** Fields for endpoints that had no data at design time are taken from the
    spec. A contract test fails if a live capture or the spec shows a numeric field the table does not
    classify.
*   **Diagnostic lookback.** It is temporary, controlled by `diagnostics.revision_lookback`, which defaults
    to true in v1. Every 6 hours, for each usage endpoint, it reads 31 days of `bucket_width=1d` with the
    same `group_by`. It digests rows into a `lookback-usage` state and emits `openai2otel.revision.late` and
    lateness observations for changes. It never counts. It is removed once Q1 is settled.

**Audit** (`/organization/audit_logs`, every 2 minutes)

*   **Read.** `effective_at[gte] = watermark - overlap` (1 hour), paged with `after` within the poll only,
    `limit=100`. Cursors are never saved.
    *   **Capped reads.** If the 50-page cap is hit, the read continues with `effective_at[lt]` set to the
        oldest event seen.
    *   **Incomplete reads.** An incomplete read never moves the watermark.
    *   **Counting.** New events go through `CountEvents`.
*   **Rows.** Each event becomes a log row keyed by event id: `openai.audit.event`, stamped at
    `effective_at`.
    *   Attributes: `openai.audit.id`, `openai.audit.type`, actor type, id, email, IP and user agent,
        project id and resource id, plus the event payload as JSON capped at 8 KiB.
    *   No "now" values, so a re-send is byte-identical. Ids already in `Delivered` are skipped.
*   **Watermark.** It advances to the newest acknowledged event's `effective_at`, and only after step 3 of
    the commit sequence acknowledges every event up to it.
*   **Counter.** `openai.audit.events{openai.audit.type}` is a durable state-backed counter.
    *   **Pre-created series.** At baseline these high-risk types are created at 0 and primed, so their
        first event is visible to `increase()`: `api_key.created`, `service_account.created`, `user.added`,
        `user.deleted`, `role.assignment.created`, `organization.updated`, `project.deleted`,
        `certificate.deleted`, `ip_allowlist.config.deactivated`, `scim.disabled`.
    *   **First start.** It reads back 6 days. Those events are logged, but the counter is baselined
        rather than incremented, so install does not fire the alert.
*   **Lateness.** `openai2otel.audit.lateness` records `observed - effective_at` for Q3.
*   **Tenant stream.** The `tenant_only=true` stream is deferred. It is a later phase, for orgs inside an
    enterprise tenant.

**Inventory** (hourly; snapshot gauges with a TTL of 3 intervals)

| Gauge | Source |
| --- | --- |
| `openai.org.projects{status}` | `GET /organization/projects?include_archived=true` |
| `openai.org.users{role}` | `GET /organization/users` |
| `openai.org.service_accounts` | `GET /organization/projects/{id}/service_accounts`, summed |
| `openai.org.api_keys{kind}` | `GET /organization/admin_api_keys` (admin); `GET /organization/projects/{id}/api_keys` (project), summed |
| `openai.api_keys.expiring` | Count of keys with `expires_at` within 30 days |
| `openai.admin_key.expiry` | Seconds until the soonest admin key expiry; absent if none expire |
| `openai.certificates.expiry` | Seconds until the soonest `certificate_details.expires_at` (`GET /organization/certificates`); absent if none |
| `openai.spend_limit{scope, project, currency}` | `GET /organization/spend_limit` and per project. `threshold_amount` is cents, divided by 100; currency is lower-cased. A 404 means no limit. |
| `openai.spend_limit.configured{scope, project}` | 1 or 0 |
| `openai.project.info{project, project_name}` | Value 1, joined in dashboards for names |

### Org identity and isolation

*   **Org id.** Each `orgs[]` entry has an operator-chosen `id` (`[a-z0-9-]{1,32}`). It is stamped on every
    signal as `openai.org` and it keys state. Rotating a key changes nothing.
*   **Duplicates.** Two entries whose saved `OrganizationID` match: the later entry in config order is
    disabled, with an error log and `openai2otel.capability{collector="*"} 0`. The process keeps running.
    No startup network check can stop the process.
*   **Isolation.** Each org has its own scheduler goroutines, token bucket, retry budget, state directory
    and commit sequence. One org's 401 sets that org's capability to 0 and backs off for 1 hour. The
    process stays healthy.

### Client behaviour (`internal/openai`)

*   **GET only.** The transport refuses other methods, and a test proves it.
*   **Pagination.** `page`/`next_page` for usage and costs; `after`/`has_more` for lists and audit. There is
    a 50-page cap per read and a repeated-cursor guard. Every read returns `complete`.
*   **Retries:**
    *   A 429 with `insufficient_quota` is class `quota` and is not retried.
    *   Other 429s and 5xx are retried up to 4 times. They honour `Retry-After` (capped at 300 seconds),
        otherwise jittered backoff from 1 second to 60 seconds.
    *   401 and 403 are `unauthorised`. 404 is `not_found` (a spend limit maps it to "none").
*   **Rate limit.** A default token bucket of 2 requests per second, burst 5, per org.
*   **Error classes** form a closed set: timeout, rate_limited, quota, unauthorised, not_found, server,
    invalid, other. Request logs never include the key.

### Config

```yaml
orgs:
  - id: main
    admin_key_file: /run/secrets/openai_main      # or env OPENAI2OTEL_ORG_MAIN_ADMIN_KEY
otlp:
  endpoint: https://otlp-gateway-<region>.grafana.net/otlp
  grafana_cloud: { instance_id: "<id>", token_file: /run/secrets/grafana }
state: { dir: /var/lib/openai2otel }
health: { listen: "127.0.0.1:9471" }
collectors:
  costs:     { enabled: true, interval: 5m }
  usage:     { enabled: true, interval: 5m, model_label: true, endpoints: [all ten] }
  audit:     { enabled: true, interval: 2m, overlap: 1h }
  inventory: { enabled: true, interval: 1h }
diagnostics: { revision_lookback: true }
```

*   **Window.** The 6-day window is not configurable in v1. A change to it is a code change, because it
    is bounded by the 160-hour log horizon.
*   **Config path.** `--config <path>`, else env `OPENAI2OTEL_CONFIG`, else
    `/etc/openai2otel/config.yaml`.
*   **Env.**
    *   **Prefix.** The env prefix is `OPENAI2OTEL_` with `__` for nesting.
    *   **Org keys.** An org key's env name is `OPENAI2OTEL_ORG_<ID>_ADMIN_KEY`, where the id is
        upper-cased and `-` becomes `_`. These variables are read and removed from the environment before
        the generic provider runs, so strict mode does not see them.
    *   **Exclusivity.** The file form and the env form of a key are mutually exclusive.
*   **Strictness.**
    *   Unknown keys are refused, with a "did you mean" suggestion.
    *   An admin key without the `sk-admin-` prefix is refused. The error names the entry, never the value.
*   **Generated docs.** `config.example.yaml` and `docs/env-vars.md` are generated and drift-checked.

### Signal contract

All names live in `internal/semconv`. A Go generator (`internal/signalcatalog`) writes them to
`spec/signal-catalog.json`, which the Grafana builders and `docs/signals.md` read. Prometheus names
follow Grafana's OTLP translation:

*   dots become underscores;
*   counters gain `_total`;
*   unit `s` adds `_seconds` and unit `By` adds `_bytes`;
*   curly-brace units add nothing.

No metric uses unit `1`.

**Attribute keys and values** (every value a string):

| Key | Values |
| --- | --- |
| `openai.org` | config org id. It is on every signal except `openai2otel.build.info`. |
| `openai.project.id`, `openai.project.name` | from OpenAI; the name appears only on logs and `openai.project.info` |
| `gen_ai.request.model` | model name from usage rows |
| `openai.operation` | `completions`, `embeddings`, `moderations`, `images`, `audio_speeches`, `audio_transcriptions`, `vector_stores`, `code_interpreter_sessions`, `file_search_calls`, `web_search_calls` |
| `openai.token.type` | `input_uncached`, `cached_input`, `cache_write`, `output` |
| `openai.line_item` | from OpenAI cost rows |
| `openai.currency` | lower-case ISO code |
| `openai.audit.type`, `openai.audit.id` | from audit events |
| `openai.project.status` | `active`, `archived` |
| `openai.user.role` | from OpenAI (`owner`, `reader` and others) |
| `openai.api_key.kind` | `admin`, `project` |
| `openai.spend_limit.scope` | `organization`, `project` |
| Self-telemetry labels | `collector`, `endpoint` (an `openai.operation` value, or `costs`, `audit`, `inventory`), `class` (client error class), `direction` (`increase`, `decrease`), `beyond_window` (`true`, `false`), `reason`, `signal` (`metrics`, `logs`), `metric`, `version`, `commit` |

**Metrics:**

| Signal | Kind | Unit | Labels beyond `openai.org` | Prometheus name |
| --- | --- | --- | --- | --- |
| `openai.cost`, `openai.cost.corrections` | counter (state) | `{cost}` | project.id, line_item, currency | `openai_cost_total`, `openai_cost_corrections_total` |
| `openai.cost.month_to_date` | gauge | `{cost}` | project.id, currency | `openai_cost_month_to_date` |
| `openai.usage.tokens` (+ `.corrections`) | counter (state) | `{token}` | project.id, gen_ai.request.model, operation, token.type | `openai_usage_tokens_total` |
| `openai.usage.requests` (+) | counter (state) | `{request}` | project.id, model, operation | `openai_usage_requests_total` |
| `openai.usage.images` (+) | counter (state) | `{image}` | project.id, model, operation | `openai_usage_images_total` |
| `openai.usage.audio.seconds` (+) | counter (state) | `s` | project.id, model, operation | `openai_usage_audio_seconds_total` |
| `openai.usage.audio.characters` (+) | counter (state) | `{character}` | project.id, model, operation | `openai_usage_audio_characters_total` |
| `openai.usage.sessions` (+) | counter (state) | `{session}` | project.id, operation | `openai_usage_sessions_total` |
| `openai.usage.tool_calls` (+) | counter (state) | `{call}` | project.id, model (web search only), operation | `openai_usage_tool_calls_total` |
| `openai.usage.vector_store.bytes` | gauge | `By` | project.id | `openai_usage_vector_store_bytes` |
| `openai.audit.events` | counter (state, no corrections) | `{event}` | audit.type | `openai_audit_events_total` |
| `openai.org.projects` | snapshot gauge | `{project}` | project.status | `openai_org_projects` |
| `openai.org.users` | snapshot gauge | `{user}` | user.role | `openai_org_users` |
| `openai.org.service_accounts` | snapshot gauge | `{account}` | none | `openai_org_service_accounts` |
| `openai.org.api_keys` | snapshot gauge | `{key}` | api_key.kind | `openai_org_api_keys` |
| `openai.api_keys.expiring` | snapshot gauge | `{key}` | api_key.kind | `openai_api_keys_expiring` |
| `openai.admin_key.expiry` | snapshot gauge | `s` | none | `openai_admin_key_expiry_seconds` |
| `openai.certificates.expiry` | snapshot gauge | `s` | none | `openai_certificates_expiry_seconds` |
| `openai.spend_limit` | snapshot gauge | `{cost}` | spend_limit.scope, project.id, currency | `openai_spend_limit` |
| `openai.spend_limit.configured` | snapshot gauge | `{limit}` | spend_limit.scope, project.id | `openai_spend_limit_configured` |
| `openai.project.info` | snapshot gauge (value 1) | `{project}` | project.id, project.name | `openai_project_info` |
| `openai2otel.scrape.success`, `.errors` | counter | `{poll}` | collector | `openai2otel_scrape_success_total`, `openai2otel_scrape_errors_total` |
| `openai2otel.scrape.duration` | histogram | `s` | collector | `openai2otel_scrape_duration_seconds` |
| `openai2otel.scrape.last_success` | gauge (Unix time) | `s` | collector | `openai2otel_scrape_last_success_seconds` |
| `openai2otel.api.requests` | counter | `{request}` | endpoint, class (`ok` on success) | `openai2otel_api_requests_total` |
| `openai2otel.api.retries` | counter | `{retry}` | endpoint | `openai2otel_api_retries_total` |
| `openai2otel.state.persist_errors` | counter | `{error}` | collector | `openai2otel_state_persist_errors_total` |
| `openai2otel.state.rebaselined` | counter | `{event}` | collector, reason | `openai2otel_state_rebaselined_total` |
| `openai2otel.state.bytes` | gauge | `By` | collector | `openai2otel_state_bytes` |
| `openai2otel.revisions` | counter | `{revision}` | endpoint, direction | `openai2otel_revisions_total` |
| `openai2otel.revision.lateness` | histogram, buckets 1h 3h 6h 12h 1d 2d 3d 5d 7d 14d 31d | `s` | endpoint, direction, beyond_window | `openai2otel_revision_lateness_seconds` |
| `openai2otel.audit.lateness` | histogram, buckets 1m 5m 15m 1h 3h 12h 1d | `s` | none | `openai2otel_audit_lateness_seconds` |
| `openai2otel.freshness` | gauge | `s` | endpoint | `openai2otel_freshness_seconds` |
| `openai2otel.capability` | gauge (1 or 0) | `{flag}` | collector, endpoint | `openai2otel_capability` |
| `openai2otel.logs.pending` | gauge | `{record}` | collector | `openai2otel_logs_pending` |
| `openai2otel.logs.dropped` | counter | `{record}` | collector, reason (`rejected`, `horizon`) | `openai2otel_logs_dropped_total` |
| `openai2otel.export.errors` | counter | `{error}` | signal, class | `openai2otel_export_errors_total` |
| `openai2otel.series.active` | gauge | `{series}` | metric | `openai2otel_series_active` |
| `openai2otel.build.info` | gauge (value 1) | `{build}` | version, commit (no `openai.org`) | `openai2otel_build_info` |

**Log events.** Every attribute is a string, and none holds a "now" value except `observed_at`, which is
set once.

| Event | Durable | Timestamp | Attributes | Body |
| --- | --- | --- | --- | --- |
| `openai.cost.bucket` | yes | bucket start | openai.org, project.id, project.name, line_item, currency, `openai.cost.value`, `openai.cost.quantity`, `openai.cost.quantity_unit`, `openai.bucket.start`, `openai.bucket.end`, `observed_at` | `cost <line_item> project <id> <YYYY-MM-DD> = <value> <currency>` |
| `openai.usage.bucket` | yes | bucket start | openai.org, project.id, gen_ai.request.model, operation, `openai.bucket.start`, `openai.bucket.end`, `observed_at`, and `openai.usage.<field>` for every numeric field on the row | `usage <operation> project <id> model <model> <bucket start>` |
| `openai.audit.event` | yes | effective_at | openai.org, audit.id, audit.type, project.id, `openai.audit.actor.type`, `.actor.id`, `.actor.email`, `.actor.ip`, `.actor.user_agent`, `openai.audit.resource.id`, `openai.audit.payload` (JSON, capped at 8 KiB) | `<type> by <actor type>` |
| `openai2otel.revision.late` | no (Emitter) | observation time | openai.org, endpoint, series, `openai.bucket.start`, old_value, new_value | `late revision <endpoint> <bucket start>` |
| `openai2otel.state.rebaselined` | no | observation time | openai.org, collector, reason | `rebaselined <collector>: <reason>` |
| `openai2otel.startup` | no | start time | version, commit, orgs, config_fingerprint | `openai2otel <version> started` |

*   **Queries.** OTLP log attributes become Loki structured metadata, so queries take the form
    `{service_name="openai2otel"} | event_name="openai.cost.bucket"`.
*   **Cardinality per org** is about `projects x models x (4 token types + 3) x 2 + projects x line items x 2 + audit types`.
    The README publishes this. `openai2otel.series.active` shows the live count, and
    `collectors.usage.model_label: false` drops the model dimension.

### Dashboard and alerts

*   **Dashboard** (`dashboards/openai2otel.json`):
    *   **Cost:** net rate `sum(rate(openai_cost_total[1h])) - sum(rate(openai_cost_corrections_total[1h]))`,
        month-to-date by project, and a per-UTC-day table from `openai.cost.bucket` logs.
    *   **Usage:** tokens and requests by model and project.
    *   **Audit:** the event stream and counts by type.
    *   **Inventory:** counts and expiries.
    *   **Exporter health:** freshness, capability, errors, pending logs, and a revision lateness heatmap.
*   **Alerts.** Grafana-managed alert rule provisioning YAML (`apiVersion: 1`, `groups`) in
    `alerts/openai2otel.yaml`:
    1.  **Collector stale:** `time() - openai2otel_scrape_last_success_seconds > 900` for 10m (3 x the 5-minute interval).
    2.  **Export or log delivery failing:** `sum(increase(openai2otel_export_errors_total[15m])) + sum(increase(openai2otel_logs_dropped_total[15m])) > 0`.
    3.  **State persist errors:** `sum(increase(openai2otel_state_persist_errors_total[15m])) > 0`.
    4.  **Admin key expiring:** `min(openai_admin_key_expiry_seconds) < 14 * 86400`.
    5.  **High-risk audit event:** `sum by (openai_org, openai_audit_type) (increase(openai_audit_events_total{openai_audit_type=~"api_key.created|service_account.created|user.added|user.deleted|role.assignment.created|organization.updated|project.deleted|certificate.deleted|ip_allowlist.config.deactivated|scim.disabled"}[10m])) > 0`.

### Drift job

*   **Contract.** `spec/openai/consumed.json`:
    `{spec_commit, operations: [{method, path, params: [{name, in, type, enum: []}], response_fields: [{path, type, nullable, enum: []}]}]}`.
*   **Tool.** `tools/apidrift` parses the YAML spec with `go.yaml.in/yaml/v3`, using a resolver modelled
    on tailscale2otel's `internal/oas`.
    *   **`anyOf`:** one schema plus `{type: "null"}` becomes that schema with `nullable: true`.
    *   **`oneOf`:** resolved per member `$ref`.
    *   **Comparison:** each consumed operation's params and fields are compared on presence, type,
        nullability and enum values.
    *   **Exit codes:** 3 on drift, 2 on tool failure, 0 when clean.
*   **Workflow.** A daily workflow builds the binary, fetches the latest `main` spec and runs it. On exit 3
    it opens, or updates, the single open issue labelled `api-drift`, using `GITHUB_TOKEN` with
    `issues: write`.

### Risks and mitigations

| Risk | Mitigation |
| --- | --- |
| A revision arrives after the 6-day window | The month-to-date gauge reflects it; `openai2otel.revision.late` logs and lateness metrics quantify it; the window is retuned from evidence |
| Series explosion in a large org | `series.active` gauge, a published formula, and the `model_label` lever; a hard cap is a later phase |
| Admin rate limits unknown | A conservative token bucket, `Retry-After`, and the request class metric to tune |
| Loki outage | Counters keep committing; logs stay pending and are retried; only the 160-hour horizon drops them, and the drop is alerted |
| State volume lost | Baseline, with no double count; the gap is lost and logged |
| A zero-prime export never succeeds before the first increment | The series stays at 0 until an export succeeds; the increment then shows on the next one |
| OpenAI changes a consumed field | The daily drift job, plus a contract test on the field table |
| Personal data in Loki (audit actor email, IP and user agent; project names) | Documented in `docs/security.md`; it is sent by design, not by accident |

## Alternatives Considered

The full pre-review list (21 entries) and the review reports are kept with the project's design
records. The decisions that shape v1:

*   **Read each bucket once.** This is every existing exporter's approach. It was rejected by the owner,
    because it undercounts every revision.
*   **Values stamped at bucket time.** Rejected because Grafana Cloud's metric store accepts samples at
    most about 2 hours out of order.
*   **Only send settled buckets.** Rejected by the owner, because it would mean no fast spend alerting.
*   **Logs only for usage and cost.** Rejected by the owner, because PromQL alerting is lost. Logs remain
    the per-day record.
*   **In-memory SDK counters** (the sibling pattern). Rejected, because a crash loses or doubles increases.
*   **Observable instruments for durable totals.** Rejected, because a series' start time and priming
    cannot be controlled. A `metric.Producer` is used instead.
*   **Highest-value memory.** Rejected, because net goes wrong under oscillation. Last-value memory is used.
*   **Per-series prefix sums.** Rejected, because individual revisions would be invisible in corrections.
*   **Log flush before save, with a three-strike drop** (the first draft). Rejected in review: a routine
    Loki outage would lose logs and skip audit events. Per-row delivered digests replace it.
*   **A revision counter on log records.** Dropped, because records need `observed_at` set once to stay
    byte-identical on re-send.
*   **A baseline floor time.** Dropped as redundant: baseline seeds every bucket in the window, and a series
    that later appears in an old bucket is real late data that should be counted.
*   **A sticky admission series budget with an `other` fold.** Deferred by the owner, because its state
    rules are the most complex part of the design.
*   **A startup duplicate-org network check that exits.** Rejected, because one org's failure must not
    stop the others.
*   **A separate revision-watcher tool.** Rejected by the owner. Lateness is measured in the exporter,
    from its first deployment.
*   **One-minute buckets, a range backfill mode, delta temporality, or a generated client from the full
    spec.** Rejected in review.
*   **Per-request traces from the portal's request list.** Rejected: it needs a browser session key
    (live-confirmed 401 for both admin and project keys).
*   **Synthetic spans from usage buckets.** Rejected by the owner: "no point faking data we don't have".

## Non-Functional Requirements

*   **Security and privacy.**
    *   **Keys:** admin keys are read from files or env into a `Secret` and never logged. The client cannot
        write.
    *   **Least privilege:** `docs/security.md` recommends an Admin key with read-only permissions, and lists
        every personal-data field sent to Loki: audit actor email, IP, user agent and geolocation, and cost
        row project names.
    *   **Repository hygiene:** fixtures pass the privacy sweep, extended with OpenAI identifier shapes.
*   **Load.**
    *   **Per org per 5-minute cycle:** about 11 GETs for usage and costs, plus audit pages.
    *   **Per org per hour:** inventory is about 6 GETs plus 3 per project.
    *   **Every 6 hours:** the diagnostic lookback adds 10 GETs.
*   **Rollout.**
    *   **Releases:** published by release-please.
    *   **State:** carries a schema version, and an older binary refuses a newer state.
    *   **Published contract:** config keys, metric names, log event names and attribute names. A rename
        needs a migration note.

### Future Improvements

*   **Project-key phase:**
    *   stored Chat Completions as one span plus one log per real request, behind the content switch
        (on by default);
    *   batches, fine-tuning jobs, files, vector store inventory.
*   **Cardinality:** a hard series cap or sticky admission.
*   **Deployment:** a Helm chart with persistence on by default.
*   **Limits:** rate-limit gauges, and headroom from a separate 1-minute usage read.
*   **Audit:** the `tenant_only` audit stream.
*   **Traces:** the exporter's own poll spans.
*   **Usage:** per-user and per-API-key daily reads, logs only.
*   **Cost alerts:** spend budget and anomaly alerts on the month-to-date gauge.
*   **Diagnostics:** remove the diagnostic lookback once revision lateness is known.

--------------------------------------------------------------------------------

## Detailed Implementation Plan

Each work package (WP) below is one GitHub issue. Its acceptance criteria are written to be copied word
for word into the issue.

*   **Ordering.** "Depends" lists the issues that must be merged first. No WP depends on a later one.
*   **Workflow changes.** A pull request that changes `.github/workflows/` carries `Task: none, <reason>`,
    and the maintainer closes its issue after merge.
*   **Who runs what.** WPs marked *maintainer* need live credentials, spend money, or change a host, so
    the maintainer or the loop root runs them, not a lane.
*   **First slice** (queued first): WP1 to WP14b.
*   **Licensing.** graph2otel and polylens2otel are being relicensed from AGPL to Apache-2.0 by their
    owner. A WP that ports from them waits for that relicence. Until it lands, take the equivalent from
    cf2otel or tailscale2otel, or write the code fresh.

### File ownership

| File or area | Owner |
| --- | --- |
| `go.mod`, `go.sum` | WP2 creates them. A later WP adds `require` lines only for its own imports, and runs `go mod tidy` to resolve conflicts. |
| `justfile` | WP2. A later WP adds only the recipes it names. |
| `.golangci.yml` | WP2 |
| `cmd/openai2otel/collectors_import.go` | WP10 creates it. Each collector WP adds one import line. |
| `internal/model`, `internal/semconv`, `internal/secret`, every `types.go` named in Frozen seams, `internal/signalcatalog`, `spec/signal-catalog.json` | WP4. A later change to these needs the maintainer. |
| `internal/openai/client.go` and `internal/bucketstate/types.go` stubs | WP4 creates the signatures. WP5 (client) and WP6 (bucketstate) replace the bodies without changing any signature. |
| `internal/collector/commit.go` | WP10 |
| `internal/collectors/usage/` | WP17 creates the layout: one file per endpoint group and `TestGoldens/<endpoint>` subtests. WP18 and WP19 add files and subtests only. |
| `.github/workflows/*` | WP3, WP13 and WP24 only |
| `docs/architecture.md`, `docs/openai-api-gotchas.md` | WP1, then the maintainer |

### WP1 Repository readiness (maintainer; run by the interactive main thread)

*   **Depends:** none.
*   **Files:**
    *   `.gitignore`: confirm `codex/` is present; add `.tools/` and `dist/`.
    *   `LOOP.md`: set `grafana-stack: robknight`, and add `## Credentials`, `## Traps` and `## Mutexes`
        (the ownership table above).
    *   `AGENTS.md` (outside the vended block): Go, the package table, the rule that a generated
        artifact changes in the same commit as its source, the traps, and pointers to this doc and the
        gotchas doc.
    *   `CONTRIBUTING.md`: the repo-facts region.
    *   `.github/privacy/patterns.txt`: OpenAI shapes `sk-admin-`, `sk-svcacct-`, `org-`, `proj_`,
        `user-` and `key_`. `sk-proj-` is already in the default set and must not be added again.
    *   `docs/architecture.md`, `docs/openai-api-gotchas.md`.
*   **Acceptance criteria:**
    *   AC1 `git ls-files -z | xargs -0 python3 .github/privacy/sweep --files` exits 0.
    *   AC2 A scratch file holding one sample of each shape (`sk-admin-`, `sk-svcacct-`, `sk-proj-`, `org-`, `proj_`, `user-`, `key_`) gives exactly seven findings from `python3 .github/privacy/sweep --files <file>`.
    *   AC3 `just check </dev/null` exits 0.
    *   AC4 `docs/openai-api-gotchas.md` records UTC bucket alignment, default page sizes, no zero injection, Loki identical-record dedupe, spend-limit cents and 404, and `tenant_not_found`, each with a `[live ...]` tag.

### WP2 Go module and task surface

*   **Depends:** WP1.
*   **Files:**
    *   `go.mod` (`module github.com/rknightion/openai2otel`, `go 1.27.3`) and `go.sum`.
    *   `cmd/openai2otel/main.go`: `run(ctx, args, stdout, stderr) int`, with `version` only.
    *   `internal/version/version.go`.
    *   `.golangci.yml`: copied from cf2otel, with the gosec G101 exclusion path widened to
        `internal/semconv/.*\.go`.
    *   `renovate.json`: OTel modules grouped and never automerged, plus a regex manager for `# renovate:`
        pins in the justfile.
    *   `justfile`, groups in brackets:
        *   a private `_tools` recipe installs any missing pinned tool (golangci-lint v2, govulncheck) into
            `.tools/`, as in `graph2otel/justfile`;
        *   `setup` [dev] runs `_tools`;
        *   `fmt` [dev]: `golangci-lint fmt` and `just --fmt`;
        *   `fmt-check` [check]: `golangci-lint fmt --diff` and `just --fmt --check`;
        *   `lint` [check] and `vuln` [check] depend on `_tools`;
        *   `vet` [check];
        *   `test` [check]: `go test -race ./...`;
        *   `fuzz-short` [check]: each `Fuzz*` target named in the recipe, for 30 seconds; empty until WP6;
        *   `tidy-check` [check], `build` [check];
        *   `gen` [dev] and `gen-check` [check]: empty until WP4;
        *   `check`: `fmt-check lint vet test fuzz-short tidy-check vuln build gen-check`;
        *   `tracker`: unchanged.
*   **Acceptance criteria:**
    *   AC1 With `.tools/` absent, `just check </dev/null` exits 0, so the existing CI job passes before WP3.
    *   AC2 `go run ./cmd/openai2otel version` prints the version and commit.
    *   AC3 An unformatted Go file makes `just fmt-check` exit non-zero.

### WP3 CI runs the Go gate (workflow change, `Task: none`)

*   **Depends:** WP2.
*   **Files:** `.github/workflows/ci.yml`:
    *   add `actions/setup-go`, pinned by SHA, with `go-version-file: go.mod`;
    *   set `enforce-all-prs: false`, because the repository is public, and correct the "Private
        repository" comment;
    *   add the `privacy-sweep` and `actionlint` reusable callers from `rknightion/.github`, pinned to its
        latest release SHA, with privacy-sweep gated `if: github.event_name == 'pull_request'`;
    *   add both to `ci-success`, which accepts `skipped` only for PR-only jobs on push.
*   **Acceptance criteria** (verified by the maintainer after merge):
    *   AC1 A pull request run shows `just check`, `privacy-sweep`, `actionlint`, `zizmor` and `ac-evidence` green and `ci-success` green.
    *   AC2 A push to `main` shows `ci-success` green with `ac-evidence` and `privacy-sweep` skipped.

### WP4 Frozen seams (senior lane)

*   **Depends:** WP2.
*   **Files:**
    *   **Packages:** `internal/model/`, `internal/secret/`.
    *   **Signal contract:** `internal/semconv/names.go`, holding everything in "Signal contract", and
        `internal/semconv/usagefields.go`, holding the field table with a version constant.
    *   **Stubs:**
        *   `internal/openai/types.go` and `internal/openai/client.go`, with types and method signatures
            whose bodies return `ErrNotImplemented`;
        *   `internal/bucketstate/types.go` with function stubs;
        *   `internal/telemetry/types.go`, `internal/collector/types.go`.
    *   **Compile-only assertions:** `internal/seams_test.go`.
    *   **Spec subset:** `internal/semconv/testdata/usage-results.json`, the `properties` blocks of the ten
        `Usage*Result` schemas from `openai/openai-openapi` commit `cd82ad68f3841d43d695e895fc25d31faa8eb0ec`.
    *   **Signal catalog:** `internal/signalcatalog/` (a generator), and `spec/signal-catalog.json` from it,
        wired into `just gen` and `just gen-check`.
    *   **State format:** `docs/state-format.md`, with the JSON format and one example per state kind.
*   **Acceptance criteria:**
    *   AC1 `go vet ./...` and `go test ./internal -run TestSeamsCompile` pass; `internal/seams_test.go` references every symbol in "Frozen seams".
    *   AC2 `go test ./internal/model -run TestSeriesKeyRoundTrip` passes, proving label order does not change the key and `Parse` inverts `NewSeriesKey` for values containing `,`, `"`, `=` and `}`.
    *   AC3 `go test ./internal/secret` passes, proving `fmt` verbs, JSON and slog render a `Secret` as `[redacted]`.
    *   AC4 `go test ./internal/semconv -run TestUsageTableComplete` passes, proving every numeric property in `testdata/usage-results.json` is classified.
    *   AC5 `just gen-check` exits 0, and exits non-zero after a semconv name changes without `just gen`.
    *   AC6 `docs/state-format.md` has worked examples for `costs`, `usage-completions` and `audit`.

### WP5 Admin API client and fake server

*   **Depends:** WP4.
*   **Files:**
    *   `internal/openai/{client,retry,pagination,errors,money,usage,costs,audit,inventory}.go`. Retry is
        adapted from tailscale2otel `internal/httpretry` (its waiter has burst 1 and no retry loop, so the
        loop and burst are added here).
    *   `internal/openai/openaitest/server.go`: a fake Admin API with scripted bucket timelines, page
        splitting, injected 429, 5xx, 401, 403 and 404 errors and `insufficient_quota`, and string amounts.
    *   Tests.
*   **Behaviour:**
    *   per-request timeout 30 seconds;
    *   retries up to 4 times, honouring `Retry-After` capped at 300 seconds, otherwise jittered backoff
        from 1 second to 60 seconds;
    *   a token bucket of 2 requests per second, burst 5, per client;
    *   a 50-page cap per read;
    *   `limit=168` for 1h usage, `limit=31` for costs, `limit=100` for lists and audit.
*   **Acceptance criteria:**
    *   AC1 `go test ./internal/openai -run TestGetOnly` passes, proving a non-GET request is refused before it leaves the process.
    *   AC2 `go test ./internal/openai -run TestPagination` passes, covering `next_page`, `after`/`has_more`, the 50-page cap returning `complete=false`, and a repeated cursor.
    *   AC3 `go test ./internal/openai -run TestRetryClasses` passes, covering `Retry-After` seconds and HTTP-date, the 300-second cap, `insufficient_quota` not retried, and the 401, 403, 404 and 5xx classes.
    *   AC4 `go test ./internal/openai -run TestAmount` passes for number, string and negative amounts with exact decimals.
    *   AC5 `go test ./internal/openai -run TestLimits` passes, proving the request `limit` values above.
    *   AC6 `go test ./internal/openai -run TestSpendLimitNotFound` passes, proving a 404 returns `nil, nil`.

### WP6 Counting core

*   **Depends:** WP4.
*   **Files:** `internal/bucketstate/{reconcile,baseline,events,prune,digest}.go` and tests.
*   **Acceptance criteria:**
    *   AC1 `go test ./internal/bucketstate -run TestWorkedExample` passes: 10, then 12, then 11 gives gross 12, corrections 1, net 11.
    *   AC2 `go test ./internal/bucketstate -run TestIncompleteReadNoChange` passes.
    *   AC3 `go test ./internal/bucketstate -run TestBaselineRows` passes for the `first_start`, `fingerprint` and `org_changed` rows of the Baseline table.
    *   AC4 `go test ./internal/bucketstate -run TestPendingDeterministic` passes, proving a rebuilt pending row is byte-identical, its digest excludes `observed_at`, and `observed_at` is fixed at first sighting.
    *   AC5 `go test ./internal/bucketstate -run TestNewSeriesUnprimed` passes.
    *   AC6 `go test ./internal/bucketstate -run TestCountEvents` passes, proving each new event id adds 1 exactly once across repeated overlapping reads.
    *   AC7 `go test ./internal/bucketstate -run TestPrune` passes, covering bucket `Delivered` entries beyond the horizon, audit entries before `Watermark - overlap`, and previous-month `Lookback`.
    *   AC8 `go test ./internal/bucketstate -fuzz FuzzNetEqualsLatest -fuzztime 60s` finds no failure. For random revision timelines, net per series equals the sum of the latest values of every bucket that was in the window. `just fuzz-short` runs this target.

### WP7 State store

*   **Depends:** WP4.
*   **Files:** `internal/statestore/{store,lock,identity}.go`, with the atomic write from tailscale2otel
    `internal/collector/atomicfile.go` and the lock from `internal/ingresswal/platform_unix.go`; tests.
*   **Acceptance criteria:**
    *   AC1 `go test ./internal/statestore -run TestAtomicSave` passes, proving a simulated failure mid-write leaves the previous file intact.
    *   AC2 `go test ./internal/statestore -run TestLock` passes, proving a second lock fails and the lock is released when the holder process exits.
    *   AC3 `go test ./internal/statestore -run TestVerify` passes, proving an unwritable directory is refused.
    *   AC4 `go test ./internal/statestore -run TestLoadErrors` passes, proving a corrupt file is moved to `<name>.corrupt-<unix>` and returns `ErrCorrupt`, and a newer schema returns `ErrNewerSchema`, covering Baseline table rows 3 and 5.
    *   AC5 `go test ./internal/statestore -run TestArchiveOrg` passes, proving every file of one org moves to `state/<org>/archive-<unix>/`.
    *   AC6 `go test ./internal/statestore -run TestIdentityStable` passes.

### WP8 Config

*   **Depends:** WP4.
*   **Files:** `internal/config/{config,load,validate}.go`; `internal/configdoc/` (written fresh, or ported
    from polylens2otel once it is relicensed); `config.example.yaml` and `docs/env-vars.md`, both
    generated; tests.
*   **Behaviour:**
    *   **Config path:** `--config <path>`, else env `OPENAI2OTEL_CONFIG`, else
        `/etc/openai2otel/config.yaml`.
    *   **Org key variables:** `OPENAI2OTEL_ORG_<ID>_ADMIN_KEY` variables are read and removed from the
        environment before the generic `OPENAI2OTEL_` provider runs. The generic provider uses `__` for
        nesting.
    *   **`orgs[]` docs:** documented in a fixed, hand-written section of `docs/env-vars.md`.
*   **Acceptance criteria:**
    *   AC1 `go test ./internal/config -run TestPrecedence` passes for defaults, then YAML, then env, and for the config path order.
    *   AC2 `go test ./internal/config -run TestRefusals` passes for an unknown key (with suggestion), key file plus env key together, a missing `sk-admin-` prefix, a duplicate or invalid org id, and errors that never contain a key value.
    *   AC3 `go test ./internal/config -run TestOrgKeyEnvNotStrictError` passes, proving an org key variable is not reported as an unknown key.
    *   AC4 `just gen-check` exits 0, and exits non-zero after a config struct tag changes without `just gen`.

### WP9 Telemetry runtime

*   **Depends:** WP6, WP7.
*   **Files:** `internal/telemetry/` (each item is described under "Metric export from saved state"):
    *   `provider.go`: OTLP http/protobuf, Grafana Cloud basic auth, https enforced when credentials are
        present, one shared resource, 60-second reader;
    *   `producer.go`, `primeledger.go`, `primewrap.go`;
    *   `logsender.go` with the capture processor;
    *   `emitter.go`, `horizon.go`, `snapshot.go` (derived from cf2otel `snapshot.go`), `selfobs.go`;
    *   tests.
*   **Acceptance criteria:**
    *   AC1 `go test ./internal/telemetry -run TestProducerStartTime` passes, proving cumulative points carry each series' saved start time through the SDK reader to an in-memory exporter.
    *   AC2 `go test ./internal/telemetry -run TestZeroPrime` passes, proving an unprimed series exports 0, then its total after one successful export.
    *   AC3 `go test ./internal/telemetry -run TestLogAckClasses` passes for every row of the log sender class table, against a fake OTLP server.
    *   AC4 `go test ./internal/telemetry -run TestCapturedRecordHasResource` passes, proving exported log records carry `service.name` and `service.instance.id`, and `ObservedTimestamp` equals `Pending.ObservedAt`.
    *   AC5 `go test ./internal/telemetry -run TestNoVersionOnResources` passes for both the metrics and logs resources.
    *   AC6 `go test -race ./internal/telemetry -run TestLedgerConcurrent` passes.

### WP10 Scheduler, commit sequence and CLI

*   **Depends:** WP5, WP8, WP9.
*   **Files:**
    *   `internal/collector/{registry,scheduler,commit,identity}.go`;
    *   `cmd/openai2otel/{run,check,once,healthcheck}.go`, and an empty `collectors_import.go`;
    *   `internal/health/` (derived from cf2otel `internal/health/health.go`): `/healthz` returns 200 while
        the process is running and its scheduler has started;
    *   tests.
*   **Behaviour:**
    *   **Exit codes:** 0 OK, 1 runtime failure, 2 config or usage error. `check` exits 3 when any
        `CheckResult` is not OK.
    *   **`once`:** one poll per org against a state store that never writes, with stdout OTLP JSON
        exporters.
    *   **`healthcheck`:** GETs `/healthz` on `health.listen` (default `127.0.0.1:9471`).
    *   **Duplicate orgs:** `OrgIdentity.Report` compares `organization_id` across orgs after every report,
        and at startup from saved state. It disables the later entry in config order: an error log, and
        `openai2otel.capability{collector="*"}` set to 0.
*   **Acceptance criteria:**
    *   AC1 `go test ./internal/collector -run TestCommitCrashPoints` passes. With a crash injected after each commit step and a restart, no counted increase is lost or doubled and every unacknowledged row is re-sent byte-identical. This is success measure 4.
    *   AC2 `go test ./internal/collector -run TestPrimedPersists` passes. After one successful export and the next commit, the saved file has `primed: true`, and the series never exports 0 again.
    *   AC3 `go test ./internal/collector -run TestOrgIsolation` passes, proving a 401 or a slow commit in one org does not delay another.
    *   AC4 `go test ./internal/collector -run TestDuplicateOrg` passes for both the startup case and the case first reported at poll time.
    *   AC5 `go test ./cmd/openai2otel -run TestOnceNeverWrites` passes.
    *   AC6 `go test ./cmd/openai2otel -run TestCheck` passes with a stub collector returning OK and a not-OK result with a fix line.

### WP11 Costs collector

*   **Depends:** WP10.
*   **Files:** `internal/collectors/costs/` and one import line.
*   **Acceptance criteria:**
    *   AC1 `go test ./internal/collectors/costs -run TestRevisionTimeline` passes, proving scripted revisions give the expected gross, corrections, logs and lateness observations.
    *   AC2 `go test ./internal/collectors/costs -run TestMonthToDate` passes, including a revision older than the window.
    *   AC3 `go test ./internal/collectors/costs -run TestBeyondWindowLate` passes, proving an `openai2otel.revision.late` log and nothing counted.
    *   AC4 `go test ./internal/collectors/costs -run TestOrgIdentityReported` passes, proving the first cost row's `organization_id` is reported and a changed value triggers `org_changed`.
    *   AC5 `go test ./internal/collectors/costs -run TestWindowWithinHorizon` passes, proving the oldest bucket start is under 160 hours old at every hour of the day.
    *   AC6 `go test ./internal/collectors/costs -run TestCheck` passes for OK and for a 403.

### WP12 Container image and compose

*   **Depends:** WP10.
*   **Files:**
    *   `Dockerfile`: a digest-pinned Go builder, `CGO_ENABLED=0 -trimpath`,
        `distroless/static-debian13:nonroot`, the state directory owned by 65532,
        `HEALTHCHECK CMD ["/openai2otel","healthcheck"]`.
    *   `.dockerignore`.
    *   `deploy/docker-compose.yaml`:
        *   `image: ghcr.io/rknightion/openai2otel:main`;
        *   config mounted read-only at `/etc/openai2otel/config.yaml`;
        *   named volume at `/var/lib/openai2otel`;
        *   key files as Docker secrets;
        *   read-only root, `cap_drop: [ALL]`, `no-new-privileges`, `restart: unless-stopped`.
    *   A `smoke` justfile recipe.
*   **Acceptance criteria:**
    *   AC1 `just smoke` exits 0, proving the image runs as uid 65532 with a read-only root and `version` succeeds.
    *   AC2 `docker compose -f deploy/docker-compose.yaml config` exits 0.

### WP13 Release and image publishing (workflow change, `Task: none`)

*   **Depends:** WP12.
*   **Files:**
    *   `release-please-config.json` and `.release-please-manifest.json` (`release-type: go`, no chart).
    *   `.github/workflows/release-please.yml`: from `cf2otel/.github/workflows/release-please.yml`, keeping
        the release-please and publish jobs and dropping binary assets. Auth uses the token broker role
        `release-please-openai2otel`, never a personal access token.
    *   `.github/workflows/publish.yml`: calls the `container-publish` reusable from `rknightion/.github` at
        its current release SHA, multi-arch, without `helm-chart-path`.
*   **Acceptance criteria** (verified by the maintainer after merge):
    *   AC1 A push to `main` publishes `ghcr.io/rknightion/openai2otel:main`.
    *   AC2 A `feat:` merge opens a release-please pull request.

### WP14a Live proof tool

*   **Depends:** WP11.
*   **Files:** `tools/liveproof/`. Subcommands, all read-only, with credentials from file paths:
    *   `mtd` compares `openai_cost_month_to_date` with the costs endpoint;
    *   `perday` compares the latest `openai.cost.bucket` per UTC day in Loki with the costs endpoint;
    *   `audit` checks each audit id appears once;
    *   `restart --since <time>` checks that, per project, the change in `openai_cost_total` minus
        `openai_cost_corrections_total` equals the change in the costs-endpoint window sum, to 0.01;
    *   `capture-usage --endpoint <e> --out <file>` writes a sanitised golden, with ids replaced by the
        prefix plus `x` padding.
*   **Acceptance criteria:**
    *   AC1 `go test ./tools/liveproof` passes against fake Mimir, Loki and Admin API servers, including a mismatch case that exits non-zero for each subcommand.
    *   AC2 `go test ./tools/liveproof -run TestCaptureSanitised` passes, proving the output passes the privacy sweep.

### WP14b First deployment and cost live proof (maintainer)

*   **Depends:** WP12, WP13, WP14a.
*   **Acceptance criteria:**
    *   AC1 (live) The compose deployment runs on the reference host and `openai2otel_build_info` shows the merged commit.
    *   AC2 (live) After 24 hours, `liveproof mtd` exits 0. This is success measure 1.
    *   AC3 (live) After a container kill mid-poll and a restart, `liveproof restart --since <kill time>` exits 0.

### WP15 Audit collector

*   **Depends:** WP10.
*   **Behaviour:**
    *   **Reads:** read from `Watermark - 1h` with `CountEvents`.
    *   **Watermark:** never moved after an incomplete read. After a capped read, keep reading with
        `effective_at[lt]` set to the oldest event seen.
    *   **`check`:** a 403 on audit logs gives the fix "enable audit logging (Data controls) or give the
        key Audit Logs Read".
*   **Acceptance criteria:**
    *   AC1 `go test ./internal/collectors/audit -run TestOverlapDedupe` passes.
    *   AC2 `go test ./internal/collectors/audit -run TestWatermarkOnlyAfterAck` passes, proving the watermark does not pass an unacknowledged event during a simulated log outage.
    *   AC3 `go test ./internal/collectors/audit -run TestIncompleteReadHoldsWatermark` passes.
    *   AC4 `go test ./internal/collectors/audit -run TestInstallNoAlert` passes, proving a first-start catch-up logs events without incrementing the counter, and the high-risk series exist at 0.
    *   AC5 `go test ./internal/collectors/audit -run TestDeliveredPruned` passes.
    *   AC6 `go test ./internal/collectors/audit -run TestByteIdenticalResend` passes.

### WP16 Probe traffic tool (tool by a lane; running it is maintainer only)

*   **Depends:** WP2.
*   **Files:** `tools/probetraffic/`, using raw `net/http`, with the probe project key read from
    `--key-file`. A constant table names each call, its model and its committed price estimate:
    *   chat completion `gpt-5-nano`;
    *   embedding `text-embedding-3-small`;
    *   moderation `omni-moderation-latest`;
    *   image `gpt-image-1-mini`, low quality, 1024px;
    *   speech `gpt-4o-mini-tts`, 20 characters;
    *   transcription `gpt-4o-mini-transcribe`, of the speech call's output;
    *   one Responses API call with `gpt-5-nano` for each of web search, file search (one tiny vector store
        and file) and code interpreter.

    Before calling, every model name is checked against `GET /v1/models`; a missing name stops the run.
    Every vector store, file and container it creates is deleted at the end. It refuses to run without
    `--yes`. The recipe is `probe-traffic` with `[confirm]`.
*   **Acceptance criteria:**
    *   AC1 `go test ./tools/probetraffic -run TestRefusesWithoutYes` passes.
    *   AC2 `go test ./tools/probetraffic -run TestDryRunPlan` passes, proving `--dry-run` prints every call and the price estimate total without network access.
    *   AC3 `go test ./tools/probetraffic -run TestCleanup` passes against a fake server, proving every created resource is deleted.

### WP17 Usage collector: completions, embeddings, moderations and the diagnostic lookback

*   **Depends:** WP11, WP14a. Before Ready, the maintainer commits `internal/collectors/usage/testdata/<endpoint>.json` for these three endpoints with `liveproof capture-usage`.
*   **Files:** `internal/collectors/usage/` with one file per endpoint group and `TestGoldens/<endpoint>`
    subtests; `lookback.go`.
*   **Acceptance criteria:**
    *   AC1 `go test ./internal/collectors/usage -run TestTokenPartition` passes, proving the four token types sum to `input_tokens + output_tokens` and the fallback rule matches when `input_uncached_tokens` is absent.
    *   AC2 `go test ./internal/collectors/usage -run TestModelLabelLever` passes.
    *   AC3 `go test ./internal/collectors/usage -run TestLookbackNeverCounts` passes.
    *   AC4 `go test ./internal/collectors/usage -run 'TestGoldens/(completions|embeddings|moderations)'` passes against the committed testdata.

### WP18 Usage: images, audio speeches, audio transcriptions

*   **Depends:** WP17, WP16. Before Ready, the maintainer runs `just probe-traffic`, then commits testdata for these three endpoints.
*   **Acceptance criteria:**
    *   AC1 `go test ./internal/collectors/usage -run 'TestGoldens/(images|audio_speeches|audio_transcriptions)'` passes.

### WP19 Usage: vector stores, code interpreter, file search, web search

*   **Depends:** WP18. Before Ready, the maintainer commits testdata for these four endpoints.
*   **Acceptance criteria:**
    *   AC1 `go test ./internal/collectors/usage -run TestVectorStoreGauge` passes, proving the level is a gauge read from the latest bucket.
    *   AC2 `go test ./internal/collectors/usage -run 'TestGoldens/(vector_stores|code_interpreter_sessions|file_search_calls|web_search_calls)'` passes.

### WP20 Inventory collector

*   **Depends:** WP10.
*   **Files:** `internal/collectors/inventory/` and one import line.
*   **Acceptance criteria:**
    *   AC1 `go test ./internal/collectors/inventory -run TestGauges` passes for every row of the inventory table against the fake server.
    *   AC2 `go test ./internal/collectors/inventory -run TestSpendLimitUnits` passes, proving cents become dollars, currency is lower-cased, and a 404 gives `configured=0`.
    *   AC3 `go test ./internal/collectors/inventory -run TestTTL` passes, proving a gauge disappears after 3 missed intervals.

### WP21 Dashboard and alerts

*   **Depends:** WP15, WP17, WP20.
*   **Files:**
    *   `grafana/build_dashboard.py` and `grafana/build_rules.py` (written fresh, or ported from graph2otel
        once it is relicensed), with `--check`, reading `spec/signal-catalog.json`;
    *   `grafana/waivers.json`, `grafana/tests/`;
    *   `dashboards/openai2otel.json` and `alerts/openai2otel.yaml`, both generated;
    *   `just gen` and `just gen-check` extended.
*   **Acceptance criteria:**
    *   AC1 `just gen-check` exits 0, and exits non-zero after a hand edit of a generated file.
    *   AC2 `python3 -m unittest discover grafana/tests` passes, proving every metric in `spec/signal-catalog.json` is on a panel or in `grafana/waivers.json`.
    *   AC3 `alerts/openai2otel.yaml` contains the five alert expressions in "Dashboard and alerts" verbatim.

### WP22 API drift tool

*   **Depends:** WP5.
*   **Files:** `tools/apidrift/`, `spec/openai/consumed.json` (schema in "Drift job", with every
    operation the client calls, at spec commit `cd82ad68f3841d43d695e895fc25d31faa8eb0ec`), and
    `testdata/apidrift/openapi-subset.yaml`: the consumed operations and every schema they reference,
    extracted from commit `cd82ad68f3841d43d695e895fc25d31faa8eb0ec`.
*   **Acceptance criteria:**
    *   AC1 `go test ./tools/apidrift` passes, covering an added field, a removed field, a type change, a nullability change and an added enum value (each exits 3), and an unchanged spec as negative control (exits 0).
    *   AC2 `go build -o /tmp/apidrift ./tools/apidrift && /tmp/apidrift --spec testdata/apidrift/openapi-subset.yaml --consumed spec/openai/consumed.json` exits 0.

### WP23 Documentation

*   **Depends:** WP21.
*   **Files:**
    *   `README.md`: what it is, a six-sentence "how numbers are counted" example, quick start, and the
        cardinality formula.
    *   `docs/configuration.md`, `docs/signals.md` (rendered from `spec/signal-catalog.json` by
        `internal/signalcatalog`), `docs/security.md`, `docs/companion-instrumentation.md`,
        `docs/comparison.md`, `docs/troubleshooting.md`.
    *   `docs.toml`, with its nav copied from `cf2otel/docs.toml`.
*   **Acceptance criteria:**
    *   AC1 `just gen-check` covers `docs/signals.md`.
    *   AC2 `docs/security.md` lists every personal-data field named in Non-Functional Requirements.
    *   AC3 `git ls-files -z docs README.md | xargs -0 python3 .github/privacy/sweep --files` exits 0.

### WP24 Drift and docs-sync workflows (workflow change, `Task: none`)

*   **Depends:** WP22, WP23.
*   **Files:**
    *   `.github/workflows/api-drift.yml`, based on `graph2otel/.github/workflows/graph-beta-drift.yml`;
    *   `.github/workflows/trigger-docs-sync.yml`, copied from cf2otel with token broker role
        `docs-sync-openai2otel`.
*   **Acceptance criteria** (verified by the maintainer after merge):
    *   AC1 A manual `workflow_dispatch` run of `api-drift` completes.
    *   AC2 A branch run with a deliberately edited `consumed.json` opens one `api-drift` issue, and a second run updates the same issue.
    *   AC3 A docs change on `main` triggers the docs sync.

### WP25 Live proofs for audit and usage (maintainer)

*   **Depends:** WP14b, WP15, WP19.
*   **Acceptance criteria:**
    *   AC1 (live) After `just probe-traffic`, every usage endpoint shows non-zero series in Mimir for the probe project.
    *   AC2 (live) After the maintainer creates and deletes one API key in the probe project, `liveproof audit` exits 0 and the high-risk alert fired once. This is success measure 3.
    *   AC3 (live) Seven days after the first deployment, `liveproof perday` exits 0 for every closed day. This is success measure 2.

### Verification Plan

*   **Gate:** `just check`, which covers format, lint, vet, race tests, short fuzz, tidy, vulnerability
    scan, build and generated-file drift. It runs in CI on every pull request.
*   **Image:** `just smoke`.
*   **Success measure 4:** `TestCommitCrashPoints` and `TestPrimedPersists` (WP10), with the
    `FuzzNetEqualsLatest` target (WP6).
*   **Success measures 1 to 3:** `tools/liveproof` (WP14b and WP25), run by the maintainer against the
    reference deployment.
*   **Revision evidence:** `openai2otel_revision_lateness_seconds` and `openai2otel.revision.late` on the
    dashboard, reviewed after 7 days of running.
