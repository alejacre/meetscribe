import Darwin

enum SensitiveFilePermissions {
    private static let installed: Void = {
        umask(0o077)
    }()

    static func install() {
        _ = installed
    }
}
