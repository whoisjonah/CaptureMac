import CoreMedia
import Foundation
import VideoToolbox

enum VideoCodec: String, Codable, CaseIterable, Identifiable {
    case h264
    case hevc

    var id: String { rawValue }

    var title: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        }
    }

    var codecType: CMVideoCodecType {
        switch self {
        case .h264: kCMVideoCodecType_H264
        case .hevc: kCMVideoCodecType_HEVC
        }
    }

    var profile: CFString {
        switch self {
        case .h264: kVTProfileLevel_H264_High_AutoLevel
        case .hevc: kVTProfileLevel_HEVC_Main_AutoLevel
        }
    }
}

struct EncoderError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "encoder wouldn't start (\(status)), maybe try a lower resolution" }
}

final class VideoEncoder {
    let width: Int
    let height: Int
    private(set) var usesConstantQuality = false
    private var session: VTCompressionSession?
    private let output: (CMSampleBuffer) -> Void

    init(width: Int, height: Int, codec: VideoCodec, bitrate: Int, quality: Double? = nil, frameRate: Int, output: @escaping (CMSampleBuffer) -> Void) throws {
        self.width = width
        self.height = height
        self.output = output

        let hardware: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
            kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
        ]
        var session: VTCompressionSession?
        var status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: codec.codecType,
            encoderSpecification: hardware as CFDictionary, imageBufferAttributes: nil,
            compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session
        )
        if status != noErr {
            status = VTCompressionSessionCreate(
                allocator: nil, width: Int32(width), height: Int32(height), codecType: codec.codecType,
                encoderSpecification: nil, imageBufferAttributes: nil,
                compressedDataAllocator: nil, outputCallback: nil, refcon: nil, compressionSessionOut: &session
            )
        }
        guard status == noErr, let session else { throw EncoderError(status: status) }

        let properties: [CFString: Any] = [
            kVTCompressionPropertyKey_RealTime: true,
            kVTCompressionPropertyKey_ProfileLevel: codec.profile,
            kVTCompressionPropertyKey_AllowFrameReordering: false,
            kVTCompressionPropertyKey_ExpectedFrameRate: frameRate,
            kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration: 1,
            kVTCompressionPropertyKey_MaxKeyFrameInterval: frameRate,
            kVTCompressionPropertyKey_ColorPrimaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            kVTCompressionPropertyKey_TransferFunction: kCVImageBufferTransferFunction_ITU_R_709_2,
            kVTCompressionPropertyKey_YCbCrMatrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2,
        ]
        for (key, value) in properties {
            VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        }

        if let quality, VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: quality as CFNumber) == noErr {
            usesConstantQuality = true
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: [bitrate / 8, 1] as CFArray)
        } else {
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: bitrate as CFNumber)
            VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: [bitrate * 2 / 8, 1] as CFArray)
        }
        VTCompressionSessionPrepareToEncodeFrames(session)
        self.session = session
    }

    deinit {
        invalidate()
    }

    func encode(_ pixelBuffer: CVPixelBuffer, at time: CMTime) {
        guard let session else { return }
        let output = self.output
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: time, duration: .invalid, frameProperties: nil, infoFlagsOut: nil) { status, _, sample in
            guard status == noErr, let sample else { return }
            output(sample)
        }
    }

    func invalidate() {
        guard let session else { return }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(session)
        self.session = nil
    }
}
