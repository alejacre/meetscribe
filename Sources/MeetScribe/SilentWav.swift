import Foundation

/// Builds a valid mono 16-bit PCM WAV of pure silence. Used to warm the model cache:
/// running mlx_whisper on this triggers the HuggingFace download without needing a
/// real recording. A hand-written RIFF header is far simpler than pulling in
/// AVFoundation for a fixed constant file. 16 kHz because whisper resamples to 16 kHz
/// anyway, keeping the file tiny (~32 KB for 1 s).
enum SilentWav {
    static func data(seconds: Int = 1, sampleRate: Int = 16000) -> Data {
        let channels = 1, bitsPerSample = 16
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8
        let dataBytes = seconds * byteRate
        var d = Data()
        func str(_ s: String) { d.append(contentsOf: s.utf8) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }

        str("RIFF")
        u32(UInt32(36 + dataBytes))       // chunk size = 36 + data
        str("WAVE")
        str("fmt ")
        u32(16)                           // PCM fmt chunk size
        u16(1)                            // audio format = PCM
        u16(UInt16(channels))
        u32(UInt32(sampleRate))
        u32(UInt32(byteRate))
        u16(UInt16(blockAlign))
        u16(UInt16(bitsPerSample))
        str("data")
        u32(UInt32(dataBytes))
        d.append(Data(count: dataBytes)) // zeros = silence
        return d
    }

    static func write(to url: URL, seconds: Int = 1) throws {
        try data(seconds: seconds).write(to: url)
    }
}
