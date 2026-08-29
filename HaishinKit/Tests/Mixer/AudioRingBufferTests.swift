import AVFoundation
import Foundation
import Testing

@testable import HaishinKit

@Suite struct AudioRingBufferTests {
    @Test func monoAppendSampleBuffer_920() throws {
        try appendSampleBuffer(920, channels: 1)
    }

    @Test func monoAppendSampleBuffer_1024() throws {
        try appendSampleBuffer(1024, channels: 1)
    }

    @Test func monoAppendSampleBuffer_overrun() throws {
        let numSamples = 1024 * 4
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 44100,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: 0xc,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        let format = AVAudioFormat(streamDescription: &asbd)
        let buffer = AudioRingBuffer(format!, bufferCounts: 3) // 1024 * 3
        guard
            let readBuffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(streamDescription: &asbd)!, frameCapacity: AVAudioFrameCount(1024)),
            let sinWave = CMAudioSampleBufferFactory.makeSinWave(44100, numSamples: numSamples, channels: 1) else {
            return
        }
        buffer?.append(sinWave)
        #expect(buffer?.isDataAvailable(1024) == true)
        #expect(buffer?.render(UInt32(1024), ioData: readBuffer.mutableAudioBufferList) == noErr)
        #expect(buffer?.isDataAvailable(1024) == true)
        #expect(buffer?.render(UInt32(1024), ioData: readBuffer.mutableAudioBufferList) == noErr)
        #expect(buffer?.isDataAvailable(1024) == true)
        #expect(buffer?.render(UInt32(1024), ioData: readBuffer.mutableAudioBufferList) == noErr)
        #expect(buffer?.isDataAvailable(1024) == true)
        #expect(buffer?.render(UInt32(1024), ioData: readBuffer.mutableAudioBufferList) == noErr)
        #expect(buffer?.isDataAvailable(1024) == false)
        #expect(buffer?.render(UInt32(1024), ioData: readBuffer.mutableAudioBufferList) != noErr)
    }

    @Test func stereoAppendSampleBuffer_920() throws {
        try appendSampleBuffer(920, channels: 2)
    }

    @Test func stereoAppendSampleBuffer_1024() throws {
        try appendSampleBuffer(1024, channels: 2)
    }

    // senderogo patch: a forward timestamp jump over `discontinuityThreshold` re-anchors the ring
    // on the new timeline (no synthesized silence) and `append` reports it; smaller gaps keep
    // upstream's silence fill.
    @Test func discontinuityReanchorsInsteadOfFillingSilence() throws {
        let sampleRate = 48000.0
        guard let sinWave = AVAudioPCMBufferFactory.makeSinWave(sampleRate, numSamples: 1024, channels: 1),
              let ring = AudioRingBuffer(sinWave.format, bufferCounts: 3),
              let readBuffer = AVAudioPCMBuffer(pcmFormat: sinWave.format, frameCapacity: 1024) else {
            Issue.record("fixture"); return
        }
        ring.discontinuityThreshold = 1.0
        readBuffer.frameLength = 1024
        let expected = Data(bytes: sinWave.int16ChannelData![0], count: 1024 * 2)
        func rendered() -> Data {
            let list = UnsafeMutableAudioBufferListPointer(readBuffer.mutableAudioBufferList)
            list[0].mData?.assumingMemoryBound(to: Int16.self).update(repeating: 0x7777, count: 1024)
            #expect(ring.render(1024, ioData: readBuffer.mutableAudioBufferList) == noErr)
            return Data(bytes: list[0].mData!, count: 1024 * 2)
        }

        var t: AVAudioFramePosition = 48000
        #expect(ring.append(sinWave, when: AVAudioTime(sampleTime: t, atRate: sampleRate)) == false)
        #expect(ring.counts == 1024)
        #expect(rendered() == expected)

        // 10 ms dropout: below the threshold, filled with silence as before.
        t += 1024 + 480
        #expect(ring.append(sinWave, when: AVAudioTime(sampleTime: t, atRate: sampleRate)) == false)
        #expect(ring.counts == 480 + 1024)
        #expect(rendered() != expected) // leading 480 frames are the fill
        let list = UnsafeMutableAudioBufferListPointer(readBuffer.mutableAudioBufferList)
        #expect(Data(bytes: list[0].mData!, count: 480 * 2) == Data(count: 480 * 2))
        #expect(ring.render(480, ioData: readBuffer.mutableAudioBufferList) == noErr) // rest of the sine
        #expect(ring.counts == 0)

        // Two minutes detached: a discontinuity — re-anchor, nothing synthesized, data flows now.
        t += 1024 + AVAudioFramePosition(sampleRate) * 120
        #expect(ring.append(sinWave, when: AVAudioTime(sampleTime: t, atRate: sampleRate)) == true)
        #expect(ring.counts == 1024)
        #expect(rendered() == expected)

        // And the new timeline is contiguous from there.
        t += 1024
        #expect(ring.append(sinWave, when: AVAudioTime(sampleTime: t, atRate: sampleRate)) == false)
        #expect(ring.counts == 1024)
        #expect(rendered() == expected)
    }

    @Test func discontinuitySampleBufferPath() throws {
        let sampleRate = 48000.0
        guard let first = CMAudioSampleBufferFactory.makeSilence(sampleRate, numSamples: 1024, channels: 1, presentaionTimeStamp: CMTime(value: 48000, timescale: 48000)),
              let formatDescription = first.formatDescription,
              let ring = AudioRingBuffer(AVAudioFormat(cmAudioFormatDescription: formatDescription), bufferCounts: 3) else {
            Issue.record("fixture"); return
        }
        ring.discontinuityThreshold = AudioRingBuffer.defaultDiscontinuityThreshold
        #expect(ring.append(first) == false)
        #expect(ring.counts == 1024)
        let later = CMTime(value: 48000 + 1024 + 48000 * 120, timescale: 48000)
        guard let jump = CMAudioSampleBufferFactory.makeSilence(sampleRate, numSamples: 1024, channels: 1, presentaionTimeStamp: later) else {
            Issue.record("fixture"); return
        }
        #expect(ring.append(jump) == true)
        #expect(ring.counts == 1024) // the unread first buffer is dropped by the reset; only the new one is pending
    }

    @Test func discontinuityDisabledKeepsUpstreamFill() throws {
        let sampleRate = 48000.0
        guard let sinWave = AVAudioPCMBufferFactory.makeSinWave(sampleRate, numSamples: 1024, channels: 1),
              let ring = AudioRingBuffer(sinWave.format, bufferCounts: 3) else {
            Issue.record("fixture"); return
        }
        #expect(ring.discontinuityThreshold == nil)
        #expect(ring.append(sinWave, when: AVAudioTime(sampleTime: 48000, atRate: sampleRate)) == false)
        let gap = AVAudioFramePosition(sampleRate) * 120
        #expect(ring.append(sinWave, when: AVAudioTime(sampleTime: 48000 + 1024 + gap, atRate: sampleRate)) == false)
        #expect(ring.counts == 1024 * 2 + Int(gap)) // upstream: the whole gap is pending as silence
    }

    private func appendSampleBuffer(_ numSamples: Int, channels: UInt32) throws {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: 44100,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: 0xc,
            mBytesPerPacket: 2 * channels,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2 * channels,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        let format = AVAudioFormat(streamDescription: &asbd)
        let buffer = AudioRingBuffer(format!, bufferCounts: 3)
        guard
            let readBuffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(streamDescription: &asbd)!, frameCapacity: AVAudioFrameCount(numSamples)),
            let sinWave = CMAudioSampleBufferFactory.makeSinWave(44100, numSamples: numSamples, channels: channels) else {
            return
        }
        let bufferList = UnsafeMutableAudioBufferListPointer(readBuffer.mutableAudioBufferList)
        readBuffer.frameLength = AVAudioFrameCount(numSamples)
        for _ in 0..<30 {
            buffer?.append(sinWave)
            readBuffer.int16ChannelData?[0].update(repeating: 0, count: numSamples)
            #expect(buffer?.render(UInt32(numSamples), ioData: readBuffer.mutableAudioBufferList) == noErr)
            #expect(try sinWave.dataBuffer?.dataBytes().bytes == Data(bytes: bufferList[0].mData!, count: numSamples * Int(channels) * 2).bytes)
        }
    }
}
