@preconcurrency import AVFoundation
import Combine
import Foundation
import HaishinKit
import libsrt

/// An actor that provides the interface to control a one-way channel over a SRTConnection.
public actor SRTStream {
    static let supportedAudioCodecs: [AudioCodecSettings.Format] = [.aac]
    static let supportedVideoCodecs: [VideoCodecSettings.Format] = VideoCodecSettings.Format.allCases

    /// The expected medias for transport stream.
    public var expectedMedias: Set<AVMediaType> {
        writer.expectedMedias
    }

    @Published public private(set) var readyState: StreamReadyState = .idle
    public private(set) var videoTrackId: UInt8? = UInt8.max
    public private(set) var audioTrackId: UInt8? = UInt8.max
    package var outputs: [any StreamOutput] = []
    package var bitRateStrategy: (any StreamBitRateStrategy)?
    private lazy var writer = TSWriter()
    private lazy var reader = TSReader()
    package lazy var incoming = IncomingStream(self)
    package lazy var outgoing = OutgoingStream()
    private weak var connection: SRTConnection?

    /// The error domain codes.
    public enum Error: Swift.Error {
        // An unsupported codec.
        case unsupportedCodec
    }

    /// Creates a new stream object.
    public init(connection: SRTConnection) {
        self.connection = connection
        Task { await connection.addStream(self) }
    }

    deinit {
        outputs.removeAll()
    }

    /// Sends streaming audio and video from client.
    ///
    /// - Warning: As a prerequisite, SRTConnection must be connected. In the future, an exception will be thrown.
    public func publish(_ name: String? = "") async {
        guard let connection, await connection.connected else {
            return
        }
        guard name != nil else {
            switch readyState {
            case .publishing:
                await close()
            default:
                break
            }
            return
        }
        readyState = .publishing
        outgoing.startRunning()
        if outgoing.videoInputFormat != nil {
            writer.expectedMedias.insert(.video)
        }
        if outgoing.audioInputFormat != nil {
            writer.expectedMedias.insert(.audio)
        }
        if writer.expectedMedias.isEmpty {
            logger.error("Please set expected media.")
        }
        // senderogo patch: the publish pipeline loops run at .high priority.
        // At default priority the 4K capture/composite/encode load starves
        // these per-frame hops on the cooperative executor (measured ~73% of
        // realtime through the actor mailboxes → delivery lags & backlogs).
        Task(priority: .high) {
            for await buffer in outgoing.videoOutputStream {
                append(buffer)
            }
        }
        Task(priority: .high) {
            for await buffer in outgoing.audioOutputStream {
                append(buffer.0, when: buffer.1)
            }
        }
        Task(priority: .high) {
            for await buffer in outgoing.videoInputStream {
                outgoing.append(video: buffer)
            }
        }
        Task(priority: .high) {
            // senderogo patch: enqueue straight onto the socket's send thread —
            // zero actor hops per frame. Awaiting connection.send per blob paid
            // one cooperative-executor wakeup per frame, which a loaded capture
            // pipeline stretches to 10+ ms each (~10 Mbps ceiling). The sender
            // is resolved lazily because the socket finishes startRunning
            // during connect.
            var sender: SRTSender?
            for await data in writer.output {
                if sender == nil {
                    sender = await connection.sender
                }
                if let sender {
                    sender.enqueue(data)
                } else {
                    await connection.send(data)
                }
            }
        }
    }

    /// Playback streaming audio and video from server.
    ///
    /// - Warning: As a prerequisite, SRTConnection must be connected. In the future, an exception will be thrown.
    public func play(_ name: String? = "") async {
        guard let connection, await connection.connected else {
            return
        }
        guard name != nil else {
            switch readyState {
            case .playing:
                await close()
            default:
                break
            }
            return
        }
        await connection.recv()
        Task {
            await incoming.startRunning()
            for await buffer in reader.output {
                await incoming.append(buffer.1)
            }
        }
        readyState = .playing
    }

    /// Stops playing or publishing and makes available other uses.
    public func close() async {
        guard readyState != .idle else {
            return
        }
        writer.clear()
        reader.clear()
        outgoing.stopRunning()
        Task { await incoming.stopRunning() }
        readyState = .idle
    }

    /// Sets the expected media.
    ///
    /// This sets whether the stream contains audio only, video only, or both. Normally, this is automatically set through the append method.
    /// If you cannot call the append method before publishing, please use this method to explicitly specify the contents of the stream.
    public func setExpectedMedias(_ expectedMedias: Set<AVMediaType>) {
        writer.expectedMedias = expectedMedias
    }

    func doInput(_ data: Data) {
        _ = reader.read(data)
    }
}

extension SRTStream: _Stream {
    public func setAudioSettings(_ audioSettings: AudioCodecSettings) throws {
        guard Self.supportedAudioCodecs.contains(audioSettings.format) else {
            throw Error.unsupportedCodec
        }
        outgoing.audioSettings = audioSettings
    }

    public func setVideoSettings(_ videoSettings: VideoCodecSettings) throws {
        guard Self.supportedVideoCodecs.contains(videoSettings.format) else {
            throw Error.unsupportedCodec
        }
        outgoing.videoSettings = videoSettings
    }

    public func append(_ sampleBuffer: CMSampleBuffer) {
        switch sampleBuffer.formatDescription?.mediaType {
        case .video:
            if sampleBuffer.formatDescription?.isCompressed == true {
                writer.videoFormat = sampleBuffer.formatDescription
                writer.append(sampleBuffer)
            } else {
                outgoing.append(sampleBuffer)
                outputs.forEach { $0.stream(self, didOutput: sampleBuffer) }
            }
        default:
            break
        }
    }

    public func append(_ audioBuffer: AVAudioBuffer, when: AVAudioTime) {
        switch audioBuffer {
        case let audioBuffer as AVAudioPCMBuffer:
            outgoing.append(audioBuffer, when: when)
            outputs.forEach { $0.stream(self, didOutput: audioBuffer, when: when) }
        case let audioBuffer as AVAudioCompressedBuffer:
            writer.audioFormat = audioBuffer.format
            writer.append(audioBuffer, when: when)
        default:
            break
        }
    }

    public func dispatch(_ event: NetworkMonitorEvent) async {
        await bitRateStrategy?.adjustBitrate(event, stream: self)
    }
}

extension SRTStream: MediaMixerOutput {
    // MARK: MediaMixerOutput
    public func selectTrack(_ id: UInt8?, mediaType: CMFormatDescription.MediaType) {
        switch mediaType {
        case .audio:
            audioTrackId = id
        case .video:
            videoTrackId = id
        default:
            break
        }
    }

    nonisolated public func mixer(_ mixer: MediaMixer, didOutput sampleBuffer: CMSampleBuffer) {
        Task { await append(sampleBuffer) }
    }

    nonisolated public func mixer(_ mixer: MediaMixer, didOutput buffer: AVAudioPCMBuffer, when: AVAudioTime) {
        Task { await append(buffer, when: when) }
    }
}
