import Foundation
import os.log

extension OSLog {

    static var appDefault: OSLog {
        return log(category: "app_default")
    }

    private static func log(category: String) -> OSLog {
        let bundleId = Bundle.main.bundleIdentifier ?? ""
        return OSLog(subsystem: bundleId, category: category)
    }
}
