import CoreImage
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
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var pool: CVPixelBufferPool?

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
              let info = attachments.first,
              let rawStatus = info[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete, let encoder else { return }
        encoder.encode(filled(pixelBuffer, info: info), at: sampleBuffer.presentationTimeStamp)
    }

    private func filled(_ pixelBuffer: CVPixelBuffer, info: [SCStreamFrameInfo: Any]) -> CVPixelBuffer {
        guard let dictionary = info[.contentRect] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return pixelBuffer }
        let scale = info[.scaleFactor] as? CGFloat ?? 1
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        var content = CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale)
            .integral.intersection(bounds)
        guard !content.isNull, content.width >= 16, content.height >= 16 else { return pixelBuffer }
        let visible = (content.width * height / width).rounded()
        if visible < content.height {
            content = CGRect(x: content.minX, y: content.maxY - visible, width: content.width, height: visible)
        }
        guard width - content.width > 2 || height - content.height > 2,
              let output = makeBuffer(like: pixelBuffer) else { return pixelBuffer }

        let source = CGRect(x: content.minX, y: height - content.maxY, width: content.width, height: content.height)
        let fit = min(width / content.width, height / content.height)
        let target = CGRect(
            x: ((width - content.width * fit) / 2).rounded(), y: ((height - content.height * fit) / 2).rounded(),
            width: content.width * fit, height: content.height * fit
        )
        let transform = CGAffineTransform(translationX: -source.minX, y: -source.minY)
            .concatenating(CGAffineTransform(scaleX: fit, y: fit))
            .concatenating(CGAffineTransform(translationX: target.minX, y: target.minY))
        let image = CIImage(cvPixelBuffer: pixelBuffer)
            .cropped(to: source)
            .clampedToExtent()
            .transformed(by: transform)
            .cropped(to: target)
            .composited(over: CIImage(color: .black).cropped(to: bounds))
        CVBufferPropagateAttachments(pixelBuffer, output)
        context.render(image, to: output, bounds: bounds, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return output
    }

    private func makeBuffer(like pixelBuffer: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        if let pool, let attributes = CVPixelBufferPoolGetPixelBufferAttributes(pool) as? [String: Any],
           attributes[kCVPixelBufferWidthKey as String] as? Int != width
            || attributes[kCVPixelBufferHeightKey as String] as? Int != height
            || attributes[kCVPixelBufferPixelFormatTypeKey as String] as? OSType != format
        {
            self.pool = nil
        }
        if pool == nil {
            let attributes: [String: Any] = [
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferPixelFormatTypeKey as String: format,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
            ]
            CVPixelBufferPoolCreate(nil, nil, attributes as CFDictionary, &pool)
        }
        guard let pool else { return nil }
        var output: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &output)
        return output
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.stream === stream else { return }
            self.stream = nil
            self.onStop?(error)
        }
    }
}
