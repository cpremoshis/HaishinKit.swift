import Foundation
import Logboard

// senderogo patch: let the host app capture HaishinKit's own log lines. The library logs
// through Logboard's console appender — `print`, which only an attached debugger sees — so
// every warn/error it raises mid-session (encoder failures, SRT socket errors, audio
// interruptions, format changes, the audio-discontinuity re-anchor) was invisible on a
// device running unattached for hours. The app installs a sink once at launch and files the
// lines in its own persistent diagnostics log next to its capture events.
public enum HaishinKitLog {
    /// Receives one formatted line per event: "[Warn] [AudioRingBuffer.swift:138] message".
    /// Timestamps are the sink's business. Setting nil restores console output.
    nonisolated(unsafe) public static var sink: (@Sendable (String) -> Void)? {
        didSet {
            logger.appender = sink == nil ? ConsoleAppender() : SinkAppender()
        }
    }
}

private final class SinkAppender: LBLoggerAppender {
    func append(_ logboard: LBLogger, level: LBLogger.Level, message: [Any], file: StaticString, function: StaticString, line: Int) {
        emit(level, file, line, message.map { String(describing: $0) }.joined())
    }

    func append(_ logboard: LBLogger, level: LBLogger.Level, format: String, arguments: any CVarArg, file: StaticString, function: StaticString, line: Int) {
        emit(level, file, line, String(format: format, arguments))
    }

    private func emit(_ level: LBLogger.Level, _ file: StaticString, _ line: Int, _ text: String) {
        let name = file.description.components(separatedBy: "/").last ?? file.description
        HaishinKitLog.sink?("[\(level)] [\(name):\(line)] \(text)")
    }
}
