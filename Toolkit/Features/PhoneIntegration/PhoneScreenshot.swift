import AppKit

enum PhoneScreenshot {
    private enum CaptureError: LocalizedError {
        case adbMissing
        case captureFailed
        case invalidImage

        var errorDescription: String? {
            switch self {
            case .adbMissing:
                return "ADB was not found. Install Android SDK Platform-Tools."
            case .captureFailed:
                return "ADB screen capture failed. Check that one Android device is connected and authorized."
            case .invalidImage:
                return "ADB did not return a valid PNG screenshot."
            }
        }
    }

    static func capture() async throws -> (png: Data, tiff: Data) {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try captureWithADB() })
            }
        }
    }

    private static func captureWithADB() throws -> (png: Data, tiff: Data) {
        guard let adb = adbExecutable() else { throw CaptureError.adbMissing }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = ["exec-out", "screencap", "-p"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()

        let timeout = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
        defer { timeout.cancel() }

        // Drain stdout before waiting for the process. A screenshot can exceed the pipe's capacity.
        let png = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw CaptureError.captureFailed
        }
        guard png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              let bitmap = NSBitmapImageRep(data: png),
              let tiff = bitmap.tiffRepresentation else {
            throw CaptureError.invalidImage
        }
        return (png, tiff)
    }

    private static func adbExecutable() -> String? {
        let environment = ProcessInfo.processInfo.environment
        let sdkPaths = [environment["ANDROID_HOME"], environment["ANDROID_SDK_ROOT"]]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .map { "\($0)/platform-tools/adb" }
        let pathExecutables = (environment["PATH"] ?? "")
            .split(separator: ":")
            .filter { $0.hasPrefix("/") }
            .map { "\($0)/adb" }
        let commonPaths = [
            "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb",
            "/opt/homebrew/bin/adb",
            "/usr/local/bin/adb"
        ]
        return (sdkPaths + pathExecutables + commonPaths).first {
            FileManager.default.isExecutableFile(atPath: $0)
        }
    }
}
