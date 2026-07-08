import Foundation
import libsrt

/// senderogo patch: dedicated send thread for the publish path.
///
/// Draining the mux output through Swift-concurrency actors costs a
/// cooperative-executor wakeup per hop, and on a saturated system (4K capture,
/// offscreen compositing, dual encoders) each wakeup can take 10+ ms — which
/// serializes the per-frame hand-off chain to ~10 Mbps regardless of link
/// capacity (libsrt's own stats show an empty send buffer at gigabit-estimated
/// bandwidth while the app trickles data in). A plain thread with a lock and
/// condition variable is immune to executor starvation, and `srt_sendmsg` may
/// block for socket backpressure here without stalling anything else.
final class SRTSender: @unchecked Sendable {
    static let payloadSize = 1316

    private let socket: SRTSOCKET
    private let onError: @Sendable () -> Void
    private let cond = NSCondition()
    private var queue: [Data] = []
    private var closed = false

    init(socket: SRTSOCKET, onError: @escaping @Sendable () -> Void) {
        self.socket = socket
        self.onError = onError
        let thread = Thread { [self] in run() }
        thread.name = "com.senderogo.srt-send"
        thread.qualityOfService = .userInitiated
        thread.stackSize = 1 << 16
        thread.start()
    }

    /// Hand one mux blob (any size) to the send thread. Synchronous, O(µs),
    /// never blocks on the network. Safe from any thread or actor.
    func enqueue(_ data: Data) {
        guard !data.isEmpty else { return }
        cond.lock()
        if !closed {
            queue.append(data)
            cond.signal()
        }
        cond.unlock()
    }

    /// Stop the thread once the queue is drained. Close the SRT socket first if
    /// the thread might be blocked inside `srt_sendmsg` — that unblocks it.
    func close() {
        cond.lock()
        closed = true
        cond.broadcast()
        cond.unlock()
    }

    private func run() {
        while true {
            cond.lock()
            while queue.isEmpty && !closed { cond.wait() }
            if queue.isEmpty && closed {
                cond.unlock()
                return
            }
            let batch = queue
            queue.removeAll()
            cond.unlock()

            for data in batch {
                var offset = 0
                while offset < data.count {
                    let end = Swift.min(offset + Self.payloadSize, data.count)
                    let result = data.subdata(in: offset..<end).withUnsafeBytes { ptr -> Int32 in
                        guard let base = ptr.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                            return SRT_ERROR
                        }
                        return srt_sendmsg(socket, base, Int32(end - offset), -1, 0)
                    }
                    if result == SRT_ERROR {
                        onError()
                        return
                    }
                    offset = end
                }
            }
        }
    }
}
