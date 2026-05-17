# Anonymous Usage Telemetry

Ping Island can optionally send a small amount of anonymous product telemetry to
Alibaba Cloud Simple Log Service (SLS). Telemetry is not uploaded until the user
confirms consent during first-run onboarding or later in Settings. The
"匿名使用统计" switch in Settings can disable it at any time.

## SLS Configuration

Source builds keep telemetry disabled unless a complete SLS target is provided.
Release builds should inject the SLS target from GitHub Actions secrets:

- `PING_ISLAND_TELEMETRY_SLS_HOST`
- `PING_ISLAND_TELEMETRY_SLS_PROJECT`
- `PING_ISLAND_TELEMETRY_SLS_LOGSTORE`

For local release testing, set the same three values in
`Config/LocalSecrets.xcconfig`:

```xcconfig
PING_ISLAND_TELEMETRY_SLS_HOST = ap-southeast-1.log.aliyuncs.com
PING_ISLAND_TELEMETRY_SLS_PROJECT = ping-island-global
PING_ISLAND_TELEMETRY_SLS_LOGSTORE = ping-island
```

Use the endpoint for the region where the `ping-island` project was created.
The console URL contains the project and logstore names, but not the region
endpoint.

Topic and source remain non-secret build defaults:

- Topic: `product-telemetry`
- Source: `ping-island-macos`

The app writes with SLS WebTracking batch upload:

```text
POST https://<project>.<region>.log.aliyuncs.com/logstores/<logstore>/track
```

The target Logstore must have WebTracking enabled before client uploads are
accepted.

## Cost Controls

- Telemetry requires user consent and is disabled when the SLS host is empty.
- The app aggregates product metrics locally and uploads at most one usage
  snapshot per device for each local calendar day.
- Daily snapshots are uploaded after the day is complete, usually the next time
  the app is active or the background telemetry loop runs after midnight.
- The default daily cap remains a safety backstop, but normal telemetry volume
  is one event per active device per day.
- Only allowlisted fields are serialized; unknown fields are dropped.
- Values are truncated to 160 characters and restricted to a conservative
  ASCII-safe character set.

## Event Allowlist

The upload surface is intentionally small. Current uploaded event names:

- `daily_usage_snapshot`

Current fields describe only coarse product usage:

- app version, build, distribution channel, macOS major version, architecture,
  language bucket, surface mode, and anonymous device ID.
- `report_date` and `active_device`, which let SLS count daily active devices.
- Daily session counts grouped by client and provider, for example whether
  Codex or Claude sessions are more common.
- Daily tmux session count.
- Daily setting-toggle adjustment counts by setting key.

The app still uses internal telemetry method names for call-site compatibility,
but those calls only update the local daily aggregate. They do not upload
separate open/close, approval, install, or per-session events.

## Explicitly Not Collected

Telemetry must not include:

- Prompts, responses, message previews, code, diffs, or terminal output.
- Project paths, file paths, repository names, usernames, hostnames, SSH
  targets, IP addresses, tmux identifiers, or terminal identifiers.
- Raw hook payloads, diagnostics contents, secrets, tokens, or API keys.
