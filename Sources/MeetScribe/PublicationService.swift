import Foundation

struct PublicationResult: Sendable {
    let destinationID: String
    let errorDescription: String?

    var succeeded: Bool { errorDescription == nil }
}

enum PublicationService {
    static func configuredDestinations(
        _ configuration: DestinationConfiguration
    ) -> [any RecordingDestination] {
        var destinations: [any RecordingDestination] = []
        if configuration.git.enabled {
            destinations.append(GitRepositoryDestination(configuration: configuration.git))
        }
        if configuration.sftp.enabled {
            destinations.append(SFTPDestination(configuration: configuration.sftp))
        }
        return destinations
    }

    static func publish(
        session: RecordingSession,
        configuration: DestinationConfiguration
    ) -> [PublicationResult] {
        let destinations = configuredDestinations(configuration)
        guard !destinations.isEmpty else { return [] }

        do {
            try session.ensureManifest()
            try RecordingManifestStore.update(at: session.manifestURL) { manifest in
                manifest.publicationRequestedAt = manifest.publicationRequestedAt ?? Date()
                for destination in destinations {
                    if let index = manifest.destinations.firstIndex(where: {
                        $0.destinationID == destination.id
                    }) {
                        if manifest.destinations[index].configurationFingerprint
                            != destination.configurationFingerprint
                        {
                            manifest.destinations[index] = pendingPublication(for: destination)
                        }
                    } else {
                        manifest.destinations.append(pendingPublication(for: destination))
                    }
                }
            }
        } catch {
            return [PublicationResult(
                destinationID: "manifest",
                errorDescription: error.localizedDescription)]
        }

        return destinations.map { destination in
            do {
                try RecordingManifestStore.update(at: session.manifestURL) { manifest in
                    guard let index = manifest.destinations.firstIndex(where: {
                        $0.destinationID == destination.id
                    }) else {
                        return
                    }
                    manifest.destinations[index].phase = .publishing
                    manifest.destinations[index].attempts += 1
                    manifest.destinations[index].lastError = nil
                }
                let package = try RecordingExportPackage(
                    session: session,
                    includeAudio: destination.includeAudio)
                try destination.publish(package)
                try RecordingManifestStore.update(at: session.manifestURL) { manifest in
                    guard let index = manifest.destinations.firstIndex(where: {
                        $0.destinationID == destination.id
                    }) else {
                        return
                    }
                    manifest.destinations[index].phase = .succeeded
                    manifest.destinations[index].lastError = nil
                    manifest.destinations[index].publishedAt = Date()
                }
                return PublicationResult(destinationID: destination.id, errorDescription: nil)
            } catch {
                try? RecordingManifestStore.update(at: session.manifestURL) { manifest in
                    guard let index = manifest.destinations.firstIndex(where: {
                        $0.destinationID == destination.id
                    }) else {
                        return
                    }
                    manifest.destinations[index].phase = .failed
                    manifest.destinations[index].lastError = error.localizedDescription
                }
                return PublicationResult(
                    destinationID: destination.id,
                    errorDescription: error.localizedDescription)
            }
        }
    }

    static func needsResume(
        session: RecordingSession,
        configuration: DestinationConfiguration
    ) -> Bool {
        guard let manifest = RecordingManifestStore.loadIfPresent(from: session.manifestURL),
              manifest.publicationRequestedAt != nil
        else {
            return false
        }
        return configuredDestinations(configuration).contains { destination in
            guard let state = manifest.destinations.first(where: {
                $0.destinationID == destination.id
            }) else {
                return true
            }
            return state.phase != .succeeded
                || state.configurationFingerprint != destination.configurationFingerprint
        }
    }

    private static func pendingPublication(
        for destination: any RecordingDestination
    ) -> DestinationPublication {
        DestinationPublication(
            destinationID: destination.id,
            configurationFingerprint: destination.configurationFingerprint,
            phase: .pending,
            attempts: 0)
    }
}
