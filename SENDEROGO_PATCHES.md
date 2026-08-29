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
6. **`DynamicRangeMode.contextOptions`** — SDR composites in `RGBA8` working format instead of
   `RGBAh` (HDR keeps `RGBAh`). All SDR sources are 8-bit, so half-float working buffers only
   doubled the offscreen compositor's memory traffic (~66 → ~33 MB/frame at 4K) — a share of the
   pipeline load behind the 4K@25 realtime deficit. **A/B result (2026-07-08): no measurable
   throughput change at 4K@25 (~78% vs 77% baseline) — the working format is NOT where the deficit
   lives. Kept anyway: no visible quality regression (user-checked for banding) and halved
   compositor memory traffic is free thermal headroom on weaker devices.**
> **Status note (2026-07-08 night):** patches 7–9 below were implemented, device-verified, and then
> **reverted from the working tree** by decision — patch 6 (RGBA8) is the last code change kept.
> The full diff of 7–9 (plus the diagnostic stage-rate counters and the bstats `appQ=` field) is
> preserved at the repo root in `reverted-2026-07-08-round-two.patch` for reimplementation.

7. **`StreamRecorderWorker` (new) + `StreamRecorder` rewire** — all `AVAssetWriter` ingest
   (`startWriting`, `startSession`, `input.append`) moves from the `StreamRecorder` actor onto a
   dedicated thread with a bounded condition-guarded FIFO; `stopRecording` drains it before
   finalizing. Why: `AVAssetWriterInput.append` blocks the calling thread with real ingest work —
   from an actor that means occupying cooperative-pool threads ~77×/s, which starved the live
   pipeline's actors (xctrace-profiled on device: live leg service fell 30 → ~20 fps whenever the
   recorder ran, CPU/GPU/thermals all idle; delivery 78% at 4K@25 record+stream vs 97% stream-only,
   scaling with bitrate 97%/87%/78% at 15/20/25). Same pattern as `SRTSender`. Also suspected of
   curing the live-audio-leg death under record+stream load (AAC path starvation → CoreMedia error
   burst → audio stops mid-session while local recording stays perfect). **A/B result: no
   measurable delivery change on its own (80.6% vs 78%) — kept as correct-by-construction (never
   block the cooperative pool), but the dominant mechanism was elsewhere (patches 8–9).**
8. **`MediaMixerOutput` track ids → nonisolated synchronous reads** (protocol + all conformers:
   `SRTStream`, `StreamRecorder`, `MTHKView`, `PiPHKView`, `RTMPStream`, `RTCStream`; lock-backed
   storage). They were `get async`, so MediaMixer's per-buffer delivery loops paid an actor hop per
   output per buffer (~100+/s) — including MainActor hops via the attached preview view — just to
   re-read a constant. 1 Hz stage counters showed audio ingestion at ~30 of 46.9 buffers/s with the
   old reads, and full rate (48/s) after this patch.
9. **`TSMuxWorker` (new) + `TSWriter.onOutput` + `SRTStream.publish` rewire** — the whole TS mux
   moves to a dedicated thread. Packetization ran as SRTStream actor turns (one per encoded frame,
   AAC buffer, and mux blob); under load every consumer loop pegged at the same ~27 turns/s (CPU
   idle) — the actor's turn rate was the pipeline's currency, and fixing patch 8 made it worse by
   spending more turns on ingestion (4K@25 fell to 56%). Now: detached consumer loops enqueue
   encoded buffers to the worker (O(µs)), the worker owns the TSWriter, and mux output goes
   synchronously into `SRTSender.enqueue` — encoder to wire with zero actor turns. `close()` drains
   the worker before clearing the writer. **A/B result (cooled device): 4K@25 record+stream went
   56% → 97.6% of wall time with full-length audio; mux thread runs at full input rate
   (27 video + 48 audio items/s), wire sustains 25–27 Mbps, all queues empty. SOLVED.**

10. **`AudioRingBuffer` discontinuity re-anchor** (+ `AudioMixerTrack`, `AudioCodec` opt in) —
   a forward input-timestamp jump above `defaultDiscontinuityThreshold` (1 s) resets the ring and
   re-anchors on the new timeline; `append` returns `true` so the owner restarts its `AudioTime`
   output clock too. Upstream fills every gap with silence to keep the output contiguous, and
   never resets across a detach/re-attach of the same-format input. The app releases the mic at
   every stop, so the next session's first buffer arrived minutes ahead of the ring's clock and
   the whole idle gap was synthesized as silent 1024-frame buffers in one synchronous burst
   (~14× realtime) to every output — recorder, SRT session, level meter. Field case (2026-08-28,
   iPhone 12 mini / iOS 26.6.1): 282 s idle → a 36 s recording saved as 4:56 with 258.6 s of
   −91 dB AAC and a matching empty edit on the video track; the receiver's file of the same
   session carried the same 256 s prefix; the meter sat dead ~20 s. Idle gaps under ~24 s never
   showed (the burst finished before the recorder was armed). Backward jumps keep upstream
   behavior; `AudioMixerByMultiTrack`'s per-track rings and `AudioMonitor` stay opted out.

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
