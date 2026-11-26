import Foundation

/// Reads and empties the Trash through Finder so every volume's trash is covered
/// without needing Full Disk Access.
enum DockTrash {
    static func hasItems() -> Bool {
        // Fast path: the home-volume trash, readable when Toolkit has Full Disk Access.
        if let trashURL = FileManager.default.urls(for: .trashDirectory, in: .userDomainMask).first,
           let contents = try? FileManager.default.contentsOfDirectory(
               at: trashURL,
               includingPropertiesForKeys: nil,
               options: [.skipsHiddenFiles]
           ),
           !contents.isEmpty {
            return true
        }

        let source = """
        with timeout of 2 seconds
            tell application "Finder" to count items of trash
        end timeout
        """
        var error: NSDictionary?
        guard let result = NSAppleScript(source: source)?.executeAndReturnError(&error),
              error == nil
        else { return false }
        return result.int32Value > 0
    }

    static func empty() {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "tell application \"Finder\" to empty trash"]
            try? process.run()
        }
    }
}
