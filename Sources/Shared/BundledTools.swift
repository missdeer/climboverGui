import Foundation

enum BundledTools {
    static func executable(_ name: String, helper: URL) -> URL {
        helper.deletingLastPathComponent().appendingPathComponent(name)
    }

    static func plugin(_ value: String, root: URL, helper: URL) -> URL {
        if URL(fileURLWithPath: value).lastPathComponent == "obfs-local" {
            return executable("obfs-local", helper: helper)
        }
        return value.hasPrefix("/") ? URL(fileURLWithPath: value) : root.appendingPathComponent(value)
    }
}
