import AVFoundation
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// An Android device reachable over ADB, with the details needed to match it to a paired bridge device.
nonisolated struct PhoneADBDevice: Equatable, Sendable {
    let serial: String
    /// Matches the Android app's `"${Build.MANUFACTURER.capitalized} ${Build.MODEL}"` device name.
    let name: String
    let ipAddresses: Set<String>
}

/// Reads phone data over ADB. All calls block, so run them off the main thread.
nonisolated enum PhoneADBClient {
    private static let thumbnailMaxPixelSize = 320
    private static let maxImageBytesForThumbnail: Int64 = 40 * 1024 * 1024
    private static let maxVideoBytesForThumbnail: Int64 = 80 * 1024 * 1024

    static var isAvailable: Bool { PhoneScreenshot.adbExecutable() != nil }

    // MARK: - Devices

    /// Serials of authorized devices. Returns nil when ADB is unavailable.
    static func connectedSerials() -> [String]? {
        guard let output = try? run(["devices"], timeout: 5).stringValue else { return nil }
        return output
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .compactMap { line -> String? in
                let parts = line.split(whereSeparator: \.isWhitespace)
                guard parts.count >= 2, parts[1] == "device" else { return nil }
                return String(parts[0])
            }
    }

    static func deviceDetails(serial: String) -> PhoneADBDevice? {
        let script = "getprop ro.product.manufacturer; getprop ro.product.model; ip -o addr 2>/dev/null"
        guard let output = try? shell(serial: serial, script, timeout: 5).stringValue else { return nil }
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        guard lines.count >= 2 else { return nil }
        let manufacturer = lines[0].trimmingCharacters(in: .whitespaces)
        let model = lines[1].trimmingCharacters(in: .whitespaces)
        let name = "\(manufacturer.prefix(1).uppercased())\(manufacturer.dropFirst()) \(model)"

        var addresses: Set<String> = []
        for line in lines.dropFirst(2) {
            let tokens = line.split(whereSeparator: \.isWhitespace)
            guard let index = tokens.firstIndex(where: { $0 == "inet" || $0 == "inet6" }),
                  index + 1 < tokens.count else { continue }
            let address = tokens[index + 1].split(separator: "/").first.map(String.init) ?? ""
            if !address.isEmpty { addresses.insert(normalizedIPAddress(address)) }
        }
        return PhoneADBDevice(serial: serial, name: name, ipAddresses: addresses)
    }

    static func normalizedIPAddress(_ address: String) -> String {
        (address.split(separator: "%").first.map(String.init) ?? address).lowercased()
    }

    // MARK: - Files

    static func listFiles(serial: String, category: PhoneFileCategory, limit: Int) throws -> [PhoneFileItem] {
        let collection: String
        let selection: String?
        switch category {
        case .photosVideos:
            collection = "content://media/external/file"
            selection = "media_type IN (1,3)"
        case .documents:
            collection = "content://media/external/downloads"
            selection = "mime_type IS NOT NULL"
        case .music:
            collection = "content://media/external/audio/media"
            selection = nil
        case .other:
            collection = "content://media/external/file"
            selection = "media_type = 0"
        }

        let keys = ["_id", "_display_name", "_size", "date_modified", "mime_type", "_data"]
        var command = "content query --uri \(collection) --projection \(keys.joined(separator: ":"))"
        if let selection { command += " --where \(shellQuoted(selection))" }
        command += " --sort \(shellQuoted("date_modified DESC")) | head -n \(max(1, limit))"

        let result = try shell(serial: serial, command, timeout: 15)
        guard result.status == 0, let output = result.stringValue else {
            throw PhoneBridgeControllerError.remoteFileTransferFailed("ADB could not list files on the phone.")
        }
        if output.contains("Error while accessing provider") {
            throw PhoneBridgeControllerError.remoteFileTransferFailed("ADB could not read the phone's media library.")
        }

        return output.split(whereSeparator: \.isNewline).compactMap { line in
            guard let fields = parseRow(String(line), keys: keys),
                  let id = fields["_id"], !id.isEmpty, id != "NULL",
                  let path = fields["_data"], path != "NULL" else { return nil }
            let displayName = fields["_display_name"].flatMap { $0 == "NULL" ? nil : $0 }
                ?? URL(fileURLWithPath: path).lastPathComponent
            let mimeType = fields["mime_type"].flatMap { $0 == "NULL" ? nil : $0 } ?? "application/octet-stream"
            return PhoneFileItem(
                id: id,
                filename: displayName,
                documentURI: "\(collection)/\(id)",
                size: Int64(fields["_size"] ?? "") ?? 0,
                modifiedDate: Date(timeIntervalSince1970: TimeInterval(fields["date_modified"] ?? "") ?? 0),
                mimeType: mimeType,
                isDirectory: false,
                thumbnailData: nil,
                adbPath: path
            )
        }
    }

    /// Parses `Row: N key=value, key=value, ...` using the known projection order so values may contain commas.
    private static func parseRow(_ line: String, keys: [String]) -> [String: String]? {
        guard line.hasPrefix("Row: "), let firstKeyRange = line.range(of: " \(keys[0])=") else { return nil }
        var fields: [String: String] = [:]
        var cursor = firstKeyRange.lowerBound
        for (index, key) in keys.enumerated() {
            let marker = index == 0 ? " \(key)=" : ", \(key)="
            guard let keyRange = line.range(of: marker, range: cursor..<line.endIndex) else { return nil }
            let valueStart = keyRange.upperBound
            let valueEnd: String.Index
            if index + 1 < keys.count,
               let next = line.range(of: ", \(keys[index + 1])=", range: valueStart..<line.endIndex) {
                valueEnd = next.lowerBound
            } else {
                valueEnd = line.endIndex
            }
            fields[key] = String(line[valueStart..<valueEnd])
            cursor = valueEnd
        }
        return fields
    }

    // MARK: - Transfers

    static func pull(serial: String, remotePath: String, to destination: URL) throws {
        let result = try run(["-s", serial, "pull", remotePath, destination.path], timeout: 600)
        guard result.status == 0, FileManager.default.fileExists(atPath: destination.path) else {
            throw PhoneBridgeControllerError.remoteFileTransferFailed("ADB could not copy the file from the phone.")
        }
    }

    static func thumbnail(serial: String, file: PhoneFileItem) -> Data? {
        guard let path = file.adbPath else { return nil }
        let isImage = file.mimeType.hasPrefix("image/")
        let isVideo = file.mimeType.hasPrefix("video/")
        guard isImage || isVideo else { return nil }

        // MediaStore keeps generated thumbnails here, named by media id.
        let cacheDirectory = isImage ? "Pictures" : "Movies"
        let cachedPath = "/storage/emulated/0/\(cacheDirectory)/.thumbnails/\(file.id).jpg"
        if let data = try? run(["-s", serial, "exec-out", "cat \(shellQuoted(cachedPath)) 2>/dev/null"], timeout: 10).data,
           let thumbnail = downsampledImageData(from: data) {
            return thumbnail
        }

        if isImage {
            guard file.size <= maxImageBytesForThumbnail,
                  let data = try? run(["-s", serial, "exec-out", "cat \(shellQuoted(path))"], timeout: 30).data else {
                return nil
            }
            return downsampledImageData(from: data)
        }

        guard file.size <= maxVideoBytesForThumbnail else { return nil }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ToolkitPhoneADBThumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = URL(fileURLWithPath: file.filename).pathExtension
        let localURL = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext.isEmpty ? "mp4" : ext)
        defer { try? FileManager.default.removeItem(at: localURL) }
        guard (try? pull(serial: serial, remotePath: path, to: localURL)) != nil else { return nil }
        return videoThumbnailData(for: localURL)
    }

    private static func downsampledImageData(from data: Data) -> Data? {
        guard !data.isEmpty, let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return jpegData(from: image)
    }

    private static func videoThumbnailData(for url: URL) -> Data? {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: thumbnailMaxPixelSize, height: thumbnailMaxPixelSize)
        let semaphore = DispatchSemaphore(value: 0)
        var result: CGImage?
        generator.generateCGImageAsynchronously(for: .zero) { image, _, _ in
            result = image
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 10)
        return result.flatMap(jpegData(from:))
    }

    private static func jpegData(from image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.75] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    // MARK: - Process

    private struct CommandResult {
        let status: Int32
        let data: Data
        var stringValue: String? { String(data: data, encoding: .utf8) }
    }

    private static func shell(serial: String, _ script: String, timeout: TimeInterval) throws -> CommandResult {
        try run(["-s", serial, "shell", script], timeout: timeout)
    }

    private static func run(_ arguments: [String], timeout: TimeInterval) throws -> CommandResult {
        guard let adb = PhoneScreenshot.adbExecutable() else {
            throw PhoneBridgeControllerError.remoteFileTransferFailed("ADB was not found.")
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: adb)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        try process.run()

        let timeoutWork = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutWork)
        defer { timeoutWork.cancel() }

        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let status = process.terminationReason == .exit ? process.terminationStatus : -1
        return CommandResult(status: status, data: data)
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
