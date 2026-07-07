import CoreImage
import CoreMedia
import Foundation
import ScreenCaptureKit

/// Where on which display to capture, precomputed on the main actor so the
/// engine never has to touch NSScreen.
struct CaptureGeometry {
    let displayID: CGDirectDisplayID
    /// Panel rect in display-local coordinates (points, top-left origin), as
    /// expected by SCStreamConfiguration.sourceRect.
    let sourceRect: CGRect
    let pixelWidth: Int
    let pixelHeight: Int
}

enum CaptureError: LocalizedError {
    case panelFrameUnavailable
    case displayNotFound

    var errorDescription: String? {
        switch self {
        case .panelFrameUnavailable:
            return "The overlay position could not be determined."
        case .displayNotFound:
            return "The display under the overlay is not available for capture."
        }
    }
}

/// Owns the SCStream lifecycle. Emits cropped frames as CGImages on a
/// background queue via `onFrame`, and asynchronous failures via `onError`.
final class CaptureEngine: NSObject {
    var onFrame: ((CGImage) -> Void)?
    var onError: ((String) -> Void)?

    private var stream: SCStream?
    private var isStopping = false
    private let sampleQueue = DispatchQueue(label: "OverlayLens.capture.frames", qos: .userInitiated)
    private let ciContext = CIContext()

    func start(_ geometry: CaptureGeometry) async throws {
        await stop()

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == geometry.displayID }) else {
            throw CaptureError.displayNotFound
        }

        // Exclude our own windows so the lens doesn't capture itself.
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == getpid() }
        let filter = SCContentFilter(display: display, excludingWindows: ownWindows)

        let configuration = SCStreamConfiguration()
        configuration.sourceRect = geometry.sourceRect
        configuration.width = geometry.pixelWidth
        configuration.height = geometry.pixelHeight
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1) // ~1 fps
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        isStopping = true
        try? await stream.stopCapture()
        isStopping = false
    }
}

extension CaptureEngine: SCStreamOutput {
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let statusValue = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: statusValue) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }

        let image = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(image, from: image.extent) else { return }
        onFrame?(cgImage)
    }
}

extension CaptureEngine: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        guard !isStopping else { return }
        self.stream = nil
        onError?("Screen capture stopped: \(error.localizedDescription)")
    }
}
