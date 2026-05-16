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
PING_ISLAND_TELEMETRY_SLS_PROJECT = ping-island
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
- Events are batched, with a default flush interval of 60 seconds and batch
  size of 10.
- The default daily cap is 200 events per device.
- Startup and integration snapshots are throttled to avoid repeated uploads.
- Only allowlisted fields are serialized; unknown fields are dropped.
- Values are truncated to 160 characters and restricted to a conservative
  ASCII-safe character set.

## Event Allowlist

Current event names:

- `app_launched`
- `telemetry_preference_changed`
- `setting_changed`
- `hook_install_completed`
- `hook_reinstall_completed`
- `integration_status_snapshot`
- `island_opened`
- `island_closed`
- `attention_requested`
- `attention_resolved`
- `session_detected`
- `session_completed`

Current fields describe only product behavior, such as app version, build,
distribution channel, macOS major version, architecture, language bucket,
surface mode, client type, ingress type, install result, duration bucket, and
tool count bucket. Island interaction events include only coarse source,
presentation, and content-route buckets. Notification and approval events
include only attention type, resolution bucket, client/provider/ingress, and
response-duration bucket.

## Explicitly Not Collected

Telemetry must not include:

- Prompts, responses, message previews, code, diffs, or terminal output.
- Project paths, file paths, repository names, usernames, hostnames, SSH
  targets, IP addresses, tmux identifiers, or terminal identifiers.
- Raw hook payloads, diagnostics contents, secrets, tokens, or API keys.
