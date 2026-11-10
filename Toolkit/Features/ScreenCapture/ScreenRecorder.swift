import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

enum ScreenRecorderError: LocalizedError {
    case displayNotFound
    case applicationNotFound
    case emptyRecording

    var errorDescription: String? {
        switch self {
        case .displayNotFound: return "The display to record is no longer available."
        case .applicationNotFound: return "The app to record is no longer running."
        case .emptyRecording: return "The recording produced no video."
        }
    }
}

/// Records a display, a region of a display, or one app's windows to a .mov file using
/// ScreenCaptureKit's built-in file writer. Toolkit's own windows are never recorded.
@MainActor
final class ScreenRecorder: NSObject {
    private static let framesPerSecond: Int32 = 60
    private static let stopTimeout: TimeInterval = 5

    /// Called once per recording when the file is finished (by `stop()` or because the stream ended).
    var onFinished: ((Result<URL, Error>) -> Void)?

    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var outputURL: URL?
    private let sampleQueue = DispatchQueue(label: "toolkit.screen-recorder.samples")

    var isRecording: Bool { stream != nil }

    func start(target: RecordingTarget, outputURL: URL, capturesAudio: Bool) async throws {
        guard stream == nil else { return }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let toolkit = content.applications.filter { $0.processID == getpid() }

        let configuration = SCStreamConfiguration()
        configuration.showsCursor = true
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: Self.framesPerSecond)
        configuration.queueDepth = 6
        // System audio (everything playing on the Mac, minus Toolkit's own sounds).
        configuration.capturesAudio = capturesAudio
        if capturesAudio {
            configuration.excludesCurrentProcessAudio = true
            configuration.sampleRate = 48_000
            configuration.channelCount = 2
        }

        let filter: SCContentFilter
        switch target {
        case .area(let displayID, let rect):
            let display = try Self.display(displayID, in: content)
            filter = SCContentFilter(display: display, excludingApplications: toolkit, exceptingWindows: [])
            let scale = CGFloat(filter.pointPixelScale)
            configuration.sourceRect = rect
            configuration.width = Self.evenPixels(rect.width * scale)
            configuration.height = Self.evenPixels(rect.height * scale)

        case .display(let displayID):
            let display = try Self.display(displayID, in: content)
            filter = SCContentFilter(display: display, excludingApplications: toolkit, exceptingWindows: [])
            let scale = CGFloat(filter.pointPixelScale)
            configuration.width = Self.evenPixels(CGFloat(display.width) * scale)
            configuration.height = Self.evenPixels(CGFloat(display.height) * scale)

        case .application(let pid, let preferredDisplayID):
            guard let app = content.applications.first(where: { $0.processID == pid }) else {
                throw ScreenRecorderError.applicationNotFound
            }
            guard let display = Self.display(showingMostOf: pid, in: content)
                ?? content.displays.first(where: { $0.displayID == preferredDisplayID })
                ?? content.displays.first else {
                throw ScreenRecorderError.displayNotFound
            }
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
            let scale = CGFloat(filter.pointPixelScale)
            configuration.width = Self.evenPixels(CGFloat(display.width) * scale)
            configuration.height = Self.evenPixels(CGFloat(display.height) * scale)
        }

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        // The file writer does the work; a no-op screen output keeps the stream's video pipeline active.
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if capturesAudio {
            try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        }

        let outputConfiguration = SCRecordingOutputConfiguration()
        outputConfiguration.outputURL = outputURL
        outputConfiguration.outputFileType = .mov
        outputConfiguration.videoCodecType = .h264
        let recordingOutput = SCRecordingOutput(configuration: outputConfiguration, delegate: self)
        try stream.addRecordingOutput(recordingOutput)

        self.stream = stream
        self.recordingOutput = recordingOutput
        self.outputURL = outputURL

        do {
            try await stream.startCapture()
        } catch {
            reset()
            throw error
        }
    }

    func stop() {
        guard let stream, let url = outputURL else { return }
        Task { [weak self] in
            do {
                try await stream.stopCapture()
            } catch {
                guard self?.outputURL == url else { return }
                self?.finishFromFile(error: error)
                return
            }
            // Normally the recording output reports completion; don't hang if it never does.
            try? await Task.sleep(for: .seconds(Self.stopTimeout))
            guard self?.outputURL == url else { return }
            self?.finishFromFile(error: nil)
        }
    }

    // MARK: - Completion

    /// Treats a non-empty file as a usable recording even if the stream ended with an error
    /// (e.g. the user stopped it from the system's screen-sharing menu).
    private func finishFromFile(error: Error?) {
        guard let url = outputURL else { return }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size > 0 {
            finish(.success(url))
        } else {
            finish(.failure(error ?? ScreenRecorderError.emptyRecording))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard outputURL != nil else { return }
        reset()
        onFinished?(result)
    }

    private func reset() {
        stream = nil
        recordingOutput = nil
        outputURL = nil
    }

    // MARK: - Helpers

    private static func display(_ displayID: CGDirectDisplayID, in content: SCShareableContent) throws -> SCDisplay {
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
            throw ScreenRecorderError.displayNotFound
        }
        return display
    }

    /// The display that holds the center of the app's largest visible window.
    private static func display(showingMostOf pid: pid_t, in content: SCShareableContent) -> SCDisplay? {
        let windows = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.isOnScreen && $0.windowLayer == 0
        }
        guard let largest = windows.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
            return nil
        }
        let center = CGPoint(x: largest.frame.midX, y: largest.frame.midY)
        return content.displays.first { $0.frame.contains(center) }
    }

    /// H.264 needs even dimensions.
    private static func evenPixels(_ value: CGFloat) -> Int {
        max(2, Int(value.rounded(.down)) & ~1)
    }
}

extension ScreenRecorder: SCStreamDelegate, SCStreamOutput, SCRecordingOutputDelegate {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {}

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.finishFromFile(error: error)
        }
    }

    nonisolated func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        Task { @MainActor [weak self] in
            self?.finishFromFile(error: nil)
        }
    }

    nonisolated func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.finishFromFile(error: error)
        }
    }
}
