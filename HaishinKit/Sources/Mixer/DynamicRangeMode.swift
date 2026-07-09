import AVFoundation
import CoreImage

/// Defines the dynamic range mode used for rendering or video processing.
///
/// - Note: Live streaming is **not yet supported** when using HDR mode.
public enum DynamicRangeMode: Sendable {
    private static let colorSpaceITUR709 = CGColorSpace(name: CGColorSpace.itur_709)
    private static let colorSpaceITUR2100 = CGColorSpace(name: CGColorSpace.itur_2100_HLG)

    /// Standard Dynamic Range (SDR) mode.
    /// Uses the sRGB color space and standard luminance range.
    case sdr

    /// High Dynamic Range (HDR) mode.
    /// Uses the ITU-R BT.2100 HLG color space for wide color gamut and extended brightness.
    case hdr

    var videoFormat: OSType {
        switch self {
        case .sdr:
            return kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        case .hdr:
            return kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        }
    }

    var colorSpace: CGColorSpace? {
        switch self {
        case .sdr:
            return DynamicRangeMode.colorSpaceITUR709
        case .hdr:
            return DynamicRangeMode.colorSpaceITUR2100
        }
    }

    private var contextOptions: [CIContextOption: Any]? {
        guard let colorSpace else {
            return nil
        }
        // senderogo patch: composite SDR in 8-bit instead of half-float. The
        // sources are all 8-bit (NV12 camera frames, 8-bit overlays), so RGBAh
        // working buffers only doubled the compositor's memory traffic — at 4K
        // that's ~66 MB/frame of float16 vs ~33 MB of RGBA8, a real share of
        // the pipeline load that keeps 4K@25 short of realtime on device. HDR
        // keeps RGBAh: 10-bit content genuinely needs the headroom.
        let workingFormat: CIFormat
        switch self {
        case .sdr:
            workingFormat = .RGBA8
        case .hdr:
            workingFormat = .RGBAh
        }
        return [
            .workingFormat: workingFormat.rawValue,
            .workingColorSpace: colorSpace,
            .outputColorSpace: colorSpace
        ]
    }

    private var pixelFormat: OSType {
        switch self {
        case .sdr:
            return kCVPixelFormatType_32ARGB
        case .hdr:
            return kCVPixelFormatType_64RGBAHalf
        }
    }

    func attach(_ pixelBuffer: CVPixelBuffer) {
        switch self {
        case .sdr:
            break
        case .hdr:
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferColorPrimariesKey,
                kCVImageBufferColorPrimaries_ITU_R_2020,
                .shouldPropagate
            )
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferTransferFunctionKey,
                kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                .shouldPropagate
            )
            CVBufferSetAttachment(
                pixelBuffer,
                kCVImageBufferYCbCrMatrixKey,
                kCVImageBufferYCbCrMatrix_ITU_R_2020,
                .shouldPropagate
            )
        }
    }

    func makeCIContext() -> CIContext {
        guard let device = MTLCreateSystemDefaultDevice() else {
            return CIContext(options: contextOptions)
        }
        return CIContext(mtlDevice: device, options: contextOptions)
    }

    func makePixelBufferAttributes(_ size: CGSize) -> CFDictionary {
        switch self {
        case .sdr:
            return [
                kCVPixelBufferPixelFormatTypeKey: NSNumber(value: pixelFormat),
                kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue,
                kCVPixelBufferWidthKey: NSNumber(value: Int(size.width)),
                kCVPixelBufferHeightKey: NSNumber(value: Int(size.height))
            ] as CFDictionary
        case .hdr:
            return [
                kCVPixelBufferPixelFormatTypeKey: NSNumber(value: videoFormat),
                kCVPixelBufferMetalCompatibilityKey: kCFBooleanTrue,
                kCVPixelBufferWidthKey: NSNumber(value: Int(size.width)),
                kCVPixelBufferHeightKey: NSNumber(value: Int(size.height))
            ] as CFDictionary
        }
    }
}
