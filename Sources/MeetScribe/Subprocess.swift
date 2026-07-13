import Foundation

enum SubprocessError: Error { case nonZeroExit(Int32, stderr: String) }

enum Subprocess {
    @discardableResult
    static func run(_ executable: String, _ args: [String], stdin: String? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        // Apps launched from Finder get a minimal PATH; tools like mlx_whisper
        // shell out to ffmpeg and need Homebrew/user paths visible.
        var env = ProcessInfo.processInfo.environment
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", NSHomeDirectory() + "/.local/bin"]
        env["PATH"] = (extra + [(env["PATH"] ?? "/usr/bin:/bin")]).joined(separator: ":")
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        if let stdin {
            let inPipe = Pipe()
            p.standardInput = inPipe
            try p.run()
            inPipe.fileHandleForWriting.write(stdin.data(using: .utf8)!)
            inPipe.fileHandleForWriting.closeFile()
        } else {
            try p.run()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw SubprocessError.nonZeroExit(p.terminationStatus,
                stderr: String(data: errData, encoding: .utf8) ?? "")
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }
}
