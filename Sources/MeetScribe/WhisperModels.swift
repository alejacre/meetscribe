import Foundation

struct WhisperModel: Identifiable, Equatable, Sendable {
    let id: String
    let revision: String

    var displayName: String {
        id.replacingOccurrences(of: "mlx-community/", with: "")
    }
}

enum WhisperModels {
    static let all = [
        WhisperModel(
            id: "mlx-community/whisper-large-v3-turbo",
            revision: "a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb"),
        WhisperModel(
            id: "mlx-community/whisper-large-v3-mlx",
            revision: "49e6aa286ad60c14352c404340ded53710378a11"),
        WhisperModel(
            id: "mlx-community/whisper-medium-mlx",
            revision: "7fc08c4eac4c316526498f147dfdee6f6303f975"),
        WhisperModel(
            id: "mlx-community/whisper-small-mlx",
            revision: "45f3915923c7a79a5a5b5a7d909d39aeb0e5630e"),
    ]

    static let mlxWhisperVersion = "0.4.3"

    static func model(id: String) -> WhisperModel? {
        all.first { $0.id == id }
    }

    static func snapshotURL(for model: WhisperModel, cacheRoot: URL? = nil) -> URL {
        let root = cacheRoot ?? URL(fileURLWithPath: NSHomeDirectory() + "/.cache/huggingface/hub")
        let directory = "models--" + model.id.replacingOccurrences(of: "/", with: "--")
        return root.appendingPathComponent(directory, isDirectory: true)
            .appendingPathComponent("snapshots", isDirectory: true)
            .appendingPathComponent(model.revision, isDirectory: true)
    }

    static func isCached(_ id: String, cacheRoot: URL? = nil) -> Bool {
        guard let model = model(id: id) else { return false }
        let snapshot = snapshotURL(for: model, cacheRoot: cacheRoot)
        return ["config.json", "weights.safetensors"].allSatisfy { name in
            let path = snapshot.appendingPathComponent(name).path
            guard FileManager.default.fileExists(atPath: path),
                  let size = try? FileManager.default.attributesOfItem(atPath: path)[.size] as? NSNumber
            else { return false }
            return size.int64Value > 0
        }
    }

    static func resolvedPath(for id: String) -> String? {
        guard let model = model(id: id), isCached(id) else { return nil }
        return snapshotURL(for: model).path
    }

    static func verifyPublishedRevision(for model: WhisperModel) async throws {
        guard let encoded = model.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://huggingface.co/api/models/\(encoded)")
        else { throw ModelError.invalidIdentifier }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              publishedRevision(in: data) == model.revision
        else { throw ModelError.revisionMismatch }
    }

    static func publishedRevision(in data: Data) -> String? {
        (try? JSONDecoder().decode(ModelResponse.self, from: data))?.sha
    }

    private struct ModelResponse: Decodable { let sha: String }

    enum ModelError: Error, LocalizedError {
        case invalidIdentifier
        case revisionMismatch

        var errorDescription: String? {
            switch self {
            case .invalidIdentifier:
                "The selected model identifier is invalid."
            case .revisionMismatch:
                "The published model revision changed. Update MeetScribe before downloading it."
            }
        }
    }
}
