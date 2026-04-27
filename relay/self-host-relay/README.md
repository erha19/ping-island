# Ping Island Self-Hosted Relay

Minimal local relay for the companion skeleton. It keeps events in memory, exposes
SSE for iOS/watch clients, and accepts permission/question responses.

```sh
node relay/self-host-relay/server.js
```

Endpoints:

- `GET /v1/health`
- `POST /v1/events`
- `GET /v1/events` as `text/event-stream`
- `POST /v1/pair`
- `POST /v1/responses`
- `GET /v1/responses`

The macOS app defaults to `http://127.0.0.1:8787` in Settings -> Remote.
