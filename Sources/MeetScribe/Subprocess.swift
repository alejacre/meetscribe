import Foundation

enum SubprocessError: Error { case nonZeroExit(Int32, stderr: String) }

enum Subprocess {
    @discardableResult
    static func run(_ executable: String, _ args: [String], stdin: String? = nil) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
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
