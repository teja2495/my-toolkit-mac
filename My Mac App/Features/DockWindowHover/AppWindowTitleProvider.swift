import CoreGraphics
import Foundation

final class AppWindowTitleProvider {
    func windowTitles(for processIdentifier: pid_t) -> [String] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windowInfoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        var titles: [String] = []
        var seenTitles = Set<String>()

        for windowInfo in windowInfoList {
            guard let windowOwnerPID = windowInfo[kCGWindowOwnerPID as String] as? Int else {
                continue
            }

            guard pid_t(windowOwnerPID) == processIdentifier else {
                continue
            }

            let windowLayer = windowInfo[kCGWindowLayer as String] as? Int ?? 0
            guard windowLayer == 0 else { continue }

            let alpha = windowInfo[kCGWindowAlpha as String] as? Double ?? 1
            guard alpha > 0 else { continue }

            let rawTitle = windowInfo[kCGWindowName as String] as? String ?? ""
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty, !seenTitles.contains(title) else { continue }

            seenTitles.insert(title)
            titles.append(title)
        }

        return titles
    }
}
