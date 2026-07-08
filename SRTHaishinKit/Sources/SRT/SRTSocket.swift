import Foundation
import HaishinKit
import libsrt
import Logboard
import os

// senderogo patch: libsrt sender-side counters, once per second while live.
private let srtBstatsLog = os.Logger(subsystem: "com.senderogo.publisher", category: "srt-bstats")

final actor SRTSocket {
    static let payloadSize: Int = 1316

    enum Error: Swift.Error {
        case notConnected
        case rejected(_ reason: SRTRejectReason)
        case illegalState(_ message: String)
    }

    enum Status: Int, CustomDebugStringConvertible {
        case unknown
        case `init`
        case opened
        case listening
        case connecting
        case connected
        case broken
        case closing
        case closed
        case nonexist

        var debugDescription: String {
            switch self {
            case .unknown:
                return "unknown"
            case .`init`:
                return "init"
            case .opened:
                return "opened"
            case .listening:
                return "listening"
            case .connecting:
                return "connecting"
            case .connected:
                return "connected"
            case .broken:
                return "broken"
            case .closing:
                return "closing"
            case .closed:
                return "closed"
            case .nonexist:
                return "nonexist"
            }
        }

        init?(_ status: SRT_SOCKSTATUS) {
            self.init(rawValue: Int(status.rawValue))
            defer {
                logger.trace(debugDescription)
            }
        }
    }

    var inputs: AsyncStream<Data> {
        AsyncStream<Data> { continuation in
            // If Task.detached is not used, closing will result in a deadlock.
            Task.detached {
                while await self.connected {
                    let result = await self.recvmsg()
                    if 0 <= result {
                        continuation.yield(await self.incomingBuffer.subdata(in: 0..<Data.Index(result)))
                    } else {
                        await self.stopRunning()
                        continuation.finish()
                    }
                }
            }
        }
    }

    var performanceData: SRTPerformanceData {
        .init(mon: perf)
    }

    var status: Status {
        .init(srt_getsockstate(socket)) ?? .unknown
    }

    private(set) var isRunning = false
    // senderogo patch: dedicated send thread; replaces the outputs AsyncStream.
    private(set) var sender: SRTSender?
    private var perf: CBytePerfMon = .init()
    private var socket: SRTSOCKET = SRT_INVALID_SOCK
    private var connected: Bool {
        status == .connected
    }
    private var windowSizeC: Int32 = 1024 * 4
    private lazy var incomingBuffer: Data = .init(count: Int(windowSizeC))

    init() {
        socket = srt_create_socket()
    }

    init(socket: SRTSOCKET, options: [SRTSocketOption]) async throws {
        self.socket = socket
        guard configure(options, restriction: .post) else {
            throw makeSocketError()
        }
        if incomingBuffer.count < windowSizeC {
            incomingBuffer = .init(count: Int(windowSizeC))
        }
    }

    func getSocketOption(_ name: SRTSocketOption.Name) throws -> SRTSocketOption {
        return try SRTSocketOption(name: name, socket: socket)
    }

    func setSocketOption(_ option: SRTSocketOption) throws {
        try option.setSockflag(socket)
    }

    func open(_ url: SRTSocketURL) async throws {
        if socket == SRT_INVALID_SOCK {
            throw makeSocketError()
        }
        guard configure(url.options, restriction: .pre) else {
            throw makeSocketError()
        }
        let status: Int32 = try {
            switch url.mode {
            case .caller:
                guard var remote = url.remote else {
                    return SRT_ERROR
                }
                var remoteaddr = remote.makeSockaddr()
                return srt_connect(socket, &remoteaddr, Int32(remote.size))
            case .listener:
                guard var local = url.local else {
                    return SRT_ERROR
                }
                var localaddr = local.makeSockaddr()
                let status = srt_bind(socket, &localaddr, Int32(local.size))
                guard status != SRT_ERROR else {
                    throw makeSocketError()
                }
                return srt_listen(socket, 1)
            case .rendezvous:
                guard var remote = url.remote, var local = url.local else {
                    return SRT_ERROR
                }
                var remoteaddr = remote.makeSockaddr()
                var localaddr = local.makeSockaddr()
                return srt_rendezvous(socket, &remoteaddr, Int32(remote.size), &localaddr, Int32(local.size))
            }
        }()
        guard status != SRT_ERROR else {
            let reason = SRTRejectReason(socket: socket) ?? .unknown
            throw Error.rejected(reason)
        }
        switch url.mode {
        case .listener:
            break
        default:
            guard configure(url.options, restriction: .post) else {
                throw makeSocketError()
            }
            if incomingBuffer.count < windowSizeC {
                incomingBuffer = .init(count: Int(windowSizeC))
            }
        }
        await startRunning()
    }

    func accept(_ options: [SRTSocketOption]) async throws -> SRTSocket {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SRTSocket, Swift.Error>) in
            Task.detached { [self] in
                do {
                    let accept = srt_accept(await socket, nil, nil)
                    guard -1 < accept else {
                        throw await makeSocketError()
                    }
                    let socket = try await SRTSocket(socket: accept, options: options)
                    await socket.startRunning()
                    continuation.resume(returning: socket)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// senderogo patch: the publish hot path is SRTSender (dedicated thread,
    /// see its header). This actor method remains for compatibility but only
    /// forwards to the sender.
    func send(_ data: Data) throws {
        guard connected else {
            throw Error.notConnected
        }
        sender?.enqueue(data)
    }

    private func configure(_ options: [SRTSocketOption], restriction: SRTSocketOption.Restriction) -> Bool {
        var failures: [String] = []
        for option in options where option.name.restriction == restriction {
            do {
                try option.setSockflag(socket)
            } catch {
                failures.append(option.name.rawValue)
            }
        }
        guard failures.isEmpty else {
            logger.error(failures)
            return false
        }
        return true
    }

    private func bstats() -> Int32 {
        guard socket != SRT_INVALID_SOCK else {
            return SRT_ERROR
        }
        return srt_bstats(socket, &perf, 1)
    }

    private func makeSocketError() -> Error {
        let error_message = String(cString: srt_getlasterror_str())
        defer {
            logger.error(error_message)
        }
        if socket != SRT_INVALID_SOCK {
            srt_close(socket)
            socket = SRT_INVALID_SOCK
        }
        return .illegalState(error_message)
    }

    @inline(__always)
    private func sendmsg(_ data: Data) -> Int32 {
        return data.withUnsafeBytes { pointer in
            guard let buffer = pointer.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                return SRT_ERROR
            }
            return srt_sendmsg(socket, buffer, Int32(data.count), -1, 0)
        }
    }

    @inline(__always)
    private func recvmsg() -> Int32 {
        return incomingBuffer.withUnsafeMutableBytes { pointer in
            guard let buffer = pointer.baseAddress?.assumingMemoryBound(to: CChar.self) else {
                return SRT_ERROR
            }
            return srt_recvmsg(socket, buffer, windowSizeC)
        }
    }
}

extension SRTSocket: AsyncRunner {
    // MARK: AsyncRunner
    func startRunning() async {
        guard !isRunning else {
            return
        }
        // senderogo patch: publish data is drained by a dedicated thread —
        // never by a Task on the shared cooperative executor, which a busy
        // capture pipeline can starve to ~75 wakeups/s.
        sender = SRTSender(socket: socket) { [weak self] in
            Task { await self?.stopRunning() }
        }
        isRunning = true
    }

    func stopRunning() async {
        guard isRunning else {
            return
        }
        // srt_close first: it unblocks a send thread waiting inside srt_sendmsg.
        srt_close(socket)
        socket = SRT_INVALID_SOCK
        sender?.close()
        sender = nil
        isRunning = false
    }
}

extension SRTSocket: NetworkTransportReporter {
    // MARK: NetworkTransportReporter
    func makeNetworkTransportReport() -> NetworkTransportReport {
        _ = bstats()
        let performanceData = self.performanceData
        // senderogo patch: surface libsrt's own per-interval counters to the
        // unified log (1 Hz — this is called by NetworkMonitor's tick). The
        // interesting field is usPktSndPeriod: the inter-packet pacing interval
        // the congestion controller is enforcing on the send queue.
        let line = String(
            format: "sndPeriod=%.1fus flight=%d cwnd=%d rtt=%.1fms estBW=%.2fMbps sendRate=%.2fMbps sent=%d retrans=%d sndLoss=%d sndDrop=%d sndBufPkts=%d sndBufMs=%d",
            perf.usPktSndPeriod, perf.pktFlightSize, perf.pktCongestionWindow,
            perf.msRTT, perf.mbpsBandwidth, perf.mbpsSendRate,
            perf.pktSent, perf.pktRetrans, perf.pktSndLoss, perf.pktSndDrop,
            perf.pktSndBuf, perf.msSndBuf)
        srtBstatsLog.notice("\(line, privacy: .public)")
        return .init(
            queueBytesOut: Int(performanceData.byteSndBuf),
            totalBytesIn: Int(performanceData.byteRecvTotal),
            totalBytesOut: Int(performanceData.byteSentTotal)
        )
    }

    func makeNetworkMonitor() -> NetworkMonitor {
        return .init(self)
    }
}
