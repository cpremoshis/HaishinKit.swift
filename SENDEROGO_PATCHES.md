# SenderoGo patches on HaishinKit 2.2.5 — WORK IN PROGRESS

Fork of [HaishinKit.swift](https://github.com/HaishinKit/HaishinKit.swift) at 2.2.5 (`dc880cb5`),
consumed as a local sibling package by `senderogo-ios` (`App/project.yml` →
`path: ../../HaishinKit.swift`). All changes are marked `senderogo patch:` in-source and are
candidates for upstreaming, after which this fork goes away.

## Why

SRT publishing was capped at ~9 Mbps on device regardless of link capacity (device radio at ~1 Gbps
PHY / 0% error while libsrt's own stats showed an empty send buffer, 190 µs pacing, and a 39 Mbps
burst at stop-drain — the socket was being *starved by the framework*). Cause: the publish hot path
paid Swift-concurrency scheduling per SRT packet and per frame, and a saturated capture pipeline
(4K composite + dual encoders) stretches each cooperative-executor wakeup to 10+ ms. Full
investigation: `senderogo-ios/SRT_SEND_PATH_INVESTIGATION.md`.

## Changes

1. **`SRTHaishinKit/Sources/SRT/SRTSender.swift` (new)** — dedicated send thread
   (`.userInitiated` QoS, `NSCondition` queue). Callers enqueue whole mux blobs synchronously; the
   thread slices to 1316-byte payloads and calls `srt_sendmsg` inline. Immune to executor
   starvation; may block on socket backpressure without stalling anything else; unblocked by
   `srt_close`.
2. **`SRTSocket`** — `startRunning` creates the `SRTSender` (replacing the one-packet-per-wakeup
   AsyncStream consumer); `send()` forwards to it; `stopRunning` closes socket first, then sender.
3. **`SRTConnection.sender`** — exposes the socket's sender so the publish loop can enqueue with
   zero actor hops per frame.
4. **`SRTStream.publish`** — the `writer.output` drain loop enqueues directly onto the sender
   (resolved lazily once); the four pipeline loops run at `Task(priority: .high)`.
5. **`srt_bstats` telemetry** — 1 Hz `os_log` line from `makeNetworkTransportReport`
   (subsystem `com.senderogo.publisher`, category `srt-bstats`): send period, flight, cwnd, RTT,
   estimated bandwidth, send rate, retrans/loss/drops, buffer depth. Diagnostic aid; gate or strip
   before upstreaming.

## Device-verified results (iPad Air 5, iOS 26.5, Release build)

| Config | Stock 2.2.5 | This fork |
|---|---|---|
| SRT 1080p @ 25 Mbps | ~9 Mbps effective | realtime, 30 fps |
| SRT 4K @ 15 Mbps | ~47% of realtime | ~95%+ (realtime minus stop-drain) |
| SRT 4K @ 25 Mbps | ~35% of realtime | 77% (remaining deficit is capture-pipeline CPU/GPU, not the send path) |

Note: measure only with **Release** builds — Debug's unoptimized TS packetization is itself a
throughput ceiling.

## Status / TODO

- [ ] Upstream the `SRTSender` redesign (issue + PR against HaishinKit).
- [ ] Decide the fate of the bstats logging (feature-flag it or drop it from the PR).
- [ ] RTMP path untouched — same per-chunk pattern may exist there.
- [ ] Once upstreamed and released, restore the registry dependency in `senderogo-ios`.
