import Foundation

struct RecordingRecord: Identifiable, Equatable, Sendable {
    let noteURL: URL
    let assetDir: URL
    let modifiedAt: Date
    let manifest: RecordingManifest?
    let manifestError: String?

    init(
        noteURL: URL,
        assetDir: URL,
        modifiedAt: Date,
        manifest: RecordingManifest?,
        manifestError: String? = nil
    ) {
        self.noteURL = noteURL
        self.assetDir = assetDir
        self.modifiedAt = modifiedAt
        self.manifest = manifest
        self.manifestError = manifestError
    }

    var id: String { assetDir.standardizedFileURL.path }
    var basename: String { assetDir.lastPathComponent }
    var hasTranscript: Bool { FileManager.default.fileExists(atPath: noteURL.path) }
    var hasPublicationFailure: Bool {
        manifest?.destinations.contains { $0.phase == .failed } == true
    }
}

enum RecordingLibrary {
    static func recordings(root: URL, limit: Int? = 5) throws -> [RecordingRecord] {
        try RecordingFinalizer.recoverPendingMoves(root: root)
        let fm = FileManager.default
        let assetsRoot = root.appendingPathComponent(".assets", isDirectory: true)
        guard fm.fileExists(atPath: assetsRoot.path) else { return [] }
        let dirs = try fm.contentsOfDirectory(
            at: assetsRoot,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles])

        return try dirs.compactMap { dir in
            let values = try dir.resourceValues(
                forKeys: [.contentModificationDateKey, .isDirectoryKey])
            guard values.isDirectory == true else { return nil }
            let note = root.appendingPathComponent(dir.lastPathComponent + ".md")
            let manifestURL = dir.appendingPathComponent("manifest.json")
            let manifest: RecordingManifest?
            let manifestError: String?
            if fm.fileExists(atPath: manifestURL.path) {
                do {
                    manifest = try RecordingManifestStore.load(from: manifestURL)
                    manifestError = nil
                } catch {
                    manifest = nil
                    manifestError = error.localizedDescription
                }
            } else {
                manifest = nil
                manifestError = nil
            }
            return RecordingRecord(
                noteURL: note,
                assetDir: dir,
                modifiedAt: values.contentModificationDate ?? .distantPast,
                manifest: manifest,
                manifestError: manifestError)
        }
        .sorted {
            if $0.modifiedAt != $1.modifiedAt { return $0.modifiedAt > $1.modifiedAt }
            return $0.basename > $1.basename
        }
        .withLimit(limit)
    }
}

struct RecordingMoveTransaction: Codable, Equatable, Sendable {
    let id: UUID
    let sourceBasename: String
    let destinationBasename: String

    init(
        id: UUID = UUID(),
        sourceBasename: String,
        destinationBasename: String
    ) {
        self.id = id
        self.sourceBasename = sourceBasename
        self.destinationBasename = destinationBasename
    }
}

enum RecordingFinalizerError: Error, LocalizedError {
    case invalidTransaction
    case conflictingTransactionState(String)
    case operationAndRollbackFailed(operation: String, rollback: String)

    var errorDescription: String? {
        switch self {
        case .invalidTransaction:
            "A pending recording rename contains invalid paths."
        case .conflictingTransactionState(let id):
            "Recording rename \(id) has conflicting files and needs manual recovery."
        case .operationAndRollbackFailed(let operation, let rollback):
            "Recording rename failed: \(operation). Rollback also failed: \(rollback)"
        }
    }
}

enum RecordingFinalizer {
    private static let transactionLock = NSRecursiveLock()

    static func move(_ session: RecordingSession, toTopicSlug slug: String) throws -> URL {
        try withTransactionLock {
            try moveUnlocked(session, toTopicSlug: slug)
        }
    }

    private static func moveUnlocked(
        _ session: RecordingSession,
        toTopicSlug slug: String
    ) throws -> URL {
        let fm = FileManager.default
        let root = session.noteURL.deletingLastPathComponent()
        let assetsRoot = session.assetDir.deletingLastPathComponent()
        try recoverPendingMovesUnlocked(root: root)
        let base = "\(session.datePart)-\(RecordingSession.slug(slug))"

        var candidate = base
        var suffix = 2
        while candidate != session.basename,
              (fm.fileExists(atPath: root.appendingPathComponent(candidate + ".md").path)
               || fm.fileExists(atPath: assetsRoot.appendingPathComponent(candidate).path)) {
            candidate = "\(base)-\(suffix)"
            suffix += 1
        }

        guard candidate != session.basename else { return session.noteURL }
        let noteDestination = root.appendingPathComponent(candidate + ".md")
        let assetDestination = assetsRoot.appendingPathComponent(candidate, isDirectory: true)
        let transaction = RecordingMoveTransaction(
            sourceBasename: session.basename,
            destinationBasename: candidate)
        let journal = try persist(transaction, root: root)

        do {
            try fm.moveItem(at: session.assetDir, to: assetDestination)
            try fm.moveItem(at: session.noteURL, to: noteDestination)
            try fm.removeItem(at: journal)
        } catch {
            do {
                try rollback(transaction, root: root, journal: journal)
            } catch let rollbackError {
                throw RecordingFinalizerError.operationAndRollbackFailed(
                    operation: error.localizedDescription,
                    rollback: rollbackError.localizedDescription)
            }
            throw error
        }
        return noteDestination
    }

    static func recoverPendingMoves(root: URL) throws {
        try withTransactionLock {
            try recoverPendingMovesUnlocked(root: root)
        }
    }

    private static func recoverPendingMovesUnlocked(root: URL) throws {
        let assetsRoot = root.appendingPathComponent(".assets", isDirectory: true)
        guard FileManager.default.fileExists(atPath: assetsRoot.path) else { return }
        let journals = try FileManager.default.contentsOfDirectory(
            at: assetsRoot,
            includingPropertiesForKeys: nil)
            .filter {
                $0.lastPathComponent.hasPrefix(".meetscribe-move-")
                    && $0.pathExtension == "json"
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for journal in journals {
            let transaction = try JSONDecoder().decode(
                RecordingMoveTransaction.self,
                from: Data(contentsOf: journal))
            try recover(transaction, root: root, journal: journal)
        }
    }

    private static func withTransactionLock<T>(
        _ operation: () throws -> T
    ) rethrows -> T {
        transactionLock.lock()
        defer { transactionLock.unlock() }
        return try operation()
    }

    @discardableResult
    static func persist(
        _ transaction: RecordingMoveTransaction,
        root: URL
    ) throws -> URL {
        try validate(transaction)
        let assetsRoot = root.appendingPathComponent(".assets", isDirectory: true)
        try FileManager.default.createDirectory(
            at: assetsRoot,
            withIntermediateDirectories: true)
        let journal = assetsRoot.appendingPathComponent(
            ".meetscribe-move-\(transaction.id.uuidString.lowercased()).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(transaction).write(to: journal, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: journal.path)
        return journal
    }

    private static func recover(
        _ transaction: RecordingMoveTransaction,
        root: URL,
        journal: URL
    ) throws {
        try validate(transaction)
        let paths = transactionPaths(transaction, root: root)
        let fm = FileManager.default
        let sourceAssetExists = fm.fileExists(atPath: paths.sourceAsset.path)
        let destinationAssetExists = fm.fileExists(atPath: paths.destinationAsset.path)
        let sourceNoteExists = fm.fileExists(atPath: paths.sourceNote.path)
        let destinationNoteExists = fm.fileExists(atPath: paths.destinationNote.path)

        switch (
            sourceAssetExists,
            destinationAssetExists,
            sourceNoteExists,
            destinationNoteExists
        ) {
        case (true, false, true, false):
            try fm.removeItem(at: journal)
        case (false, true, true, false):
            try fm.moveItem(at: paths.sourceNote, to: paths.destinationNote)
            try fm.removeItem(at: journal)
        case (true, false, false, true):
            try fm.moveItem(at: paths.sourceAsset, to: paths.destinationAsset)
            try fm.removeItem(at: journal)
        case (false, true, false, true):
            try fm.removeItem(at: journal)
        case (true, false, false, false):
            try fm.removeItem(at: journal)
        case (false, true, false, false):
            try fm.moveItem(at: paths.destinationAsset, to: paths.sourceAsset)
            try fm.removeItem(at: journal)
        default:
            throw RecordingFinalizerError.conflictingTransactionState(
                transaction.id.uuidString.lowercased())
        }
    }

    private static func rollback(
        _ transaction: RecordingMoveTransaction,
        root: URL,
        journal: URL
    ) throws {
        let paths = transactionPaths(transaction, root: root)
        let fm = FileManager.default
        if fm.fileExists(atPath: paths.destinationNote.path),
           !fm.fileExists(atPath: paths.sourceNote.path)
        {
            try fm.moveItem(at: paths.destinationNote, to: paths.sourceNote)
        }
        if fm.fileExists(atPath: paths.destinationAsset.path),
           !fm.fileExists(atPath: paths.sourceAsset.path)
        {
            try fm.moveItem(at: paths.destinationAsset, to: paths.sourceAsset)
        }
        try fm.removeItem(at: journal)
    }

    private static func transactionPaths(
        _ transaction: RecordingMoveTransaction,
        root: URL
    ) -> (
        sourceNote: URL,
        destinationNote: URL,
        sourceAsset: URL,
        destinationAsset: URL
    ) {
        let assetsRoot = root.appendingPathComponent(".assets", isDirectory: true)
        return (
            sourceNote: root.appendingPathComponent(transaction.sourceBasename + ".md"),
            destinationNote: root.appendingPathComponent(transaction.destinationBasename + ".md"),
            sourceAsset: assetsRoot.appendingPathComponent(
                transaction.sourceBasename,
                isDirectory: true),
            destinationAsset: assetsRoot.appendingPathComponent(
                transaction.destinationBasename,
                isDirectory: true))
    }

    private static func validate(_ transaction: RecordingMoveTransaction) throws {
        guard validBasename(transaction.sourceBasename),
              validBasename(transaction.destinationBasename),
              transaction.sourceBasename != transaction.destinationBasename
        else {
            throw RecordingFinalizerError.invalidTransaction
        }
    }

    private static func validBasename(_ value: String) -> Bool {
        !value.isEmpty
            && value != "."
            && value != ".."
            && value == URL(fileURLWithPath: value).lastPathComponent
            && !value.contains("/")
            && !value.contains("\0")
            && !value.contains("\n")
            && !value.contains("\r")
    }
}

private extension Array {
    func withLimit(_ limit: Int?) -> [Element] {
        guard let limit else { return self }
        return Array(prefix(limit))
    }
}
