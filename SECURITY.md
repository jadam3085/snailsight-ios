# Security notes

SnailSight is a personal tool for a self-hosted map server on a private network. Known trade-offs, reviewed
2026-10-15 before this repository went public:

| Area | Behaviour | Status |
|---|---|---|
| Transport | Plain HTTP to the map server (`NSAllowsArbitraryLoads = true`). The intended reach is a Tailscale tailnet (WireGuard-encrypted) or the home LAN. | Accepted: do not point the app at a server across the open internet without TLS in front. |
| Server auth | The `/v1` API has no app-level credentials; access control is the network (tailnet ACLs / LAN). The app stores no tokens, passwords or keys. | Accepted (server-side concern). |
| Defaults | No server address, hostname or credential is compiled in; defaults come from Info.plist keys set at build/sign time (README). | Done |
| File sharing | `UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace` expose `Documents/` (session logs, captures, saved places) to Files / a paired computer. Logs hold app events, poses, device model and server URL; captures hold camera images and depth of the scanned rooms. | Accepted: needed to pull logs and captures by cable; anyone with the unlocked phone could read them anyway. |
| Mesh mapping (10.2) | "Map mesh" spools LiDAR depth, small colour frames, sharp photos and ARKit mesh of the rooms walked to `Documents/meshmap/` until the map server acknowledges them (then deleted); no video, no audio. Off by default. | Accepted: same exposure as captures. |
| Agent identity | Random `phone-<8 hex>` id, device model and `UIDevice.name` (generic "iPhone" on iOS 16+) sent to the configured server only. | Accepted |
| URL schemes / web views / debug endpoints | None: no custom URL schemes, no WKWebView, no listening sockets. | n/a |
| CI | Workflow token is read-only (`permissions: contents: read`); no secrets are used; signing is disabled, the artifact is unsigned. | Done |

Report a problem by opening a GitHub issue (no secrets in issues, please).
