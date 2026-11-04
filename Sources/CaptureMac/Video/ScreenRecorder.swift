import CoreMedia
import Foundation
import ScreenCaptureKit

struct VideoSettings: Equatable {
    var width: Int
    var height: Int
    var frameRate: Int
    var bitrate: Int
    var quality: Double?
    var codec: VideoCodec
    var showsCursor: Bool
}

final class ScreenRecorder: NSObject, SCStreamOutput, SCStreamDelegate {
    let ring: VideoRing
    var onStop: ((Error?) -> Void)?

    private var stream: SCStream?
    private var encoder: VideoEncoder?
    private let queue = DispatchQueue(label: "capturemac.video", qos: .userInteractive)

    init(ring: VideoRing) {
        self.ring = ring
    }

    func start(_ target: ResolvedTarget, settings: VideoSettings) async throws {
        await stop()

        let configuration = SCStreamConfiguration()
        configuration.width = settings.width
        configuration.height = settings.height
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(settings.frameRate))
        configuration.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        configuration.colorMatrix = CGDisplayStream.yCbCrMatrix_ITU_R_709_2
        configuration.colorSpaceName = CGColorSpace.sRGB
        configuration.queueDepth = settings.frameRate > 60 ? 8 : 6
        configuration.showsCursor = settings.showsCursor
        configuration.capturesAudio = false
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = true
        configuration.ignoreShadowsSingleWindow = true
        configuration.shouldBeOpaque = true

        let ring = self.ring
        let encoder = try VideoEncoder(
            width: settings.width, height: settings.height, codec: settings.codec,
            bitrate: settings.bitrate, quality: settings.quality, frameRate: settings.frameRate
        ) { sample in
            ring.append(sample)
        }

        let stream = SCStream(filter: target.filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        queue.sync { self.encoder = encoder }
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        if let stream {
            self.stream = nil
            try? await stream.stopCapture()
        }
        queue.sync {
            encoder?.invalidate()
            encoder = nil
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid, let pixelBuffer = sampleBuffer.imageBuffer else { return }
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete else { return }
        encoder?.encode(pixelBuffer, at: sampleBuffer.presentationTimeStamp)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stream = nil
            self.onStop?(error)
        }
    }
}
