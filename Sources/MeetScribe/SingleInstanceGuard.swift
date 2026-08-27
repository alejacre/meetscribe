import Darwin
import Foundation
import Synchronization

enum SingleInstanceAcquisition: Equatable {
    case acquired
    case alreadyRunning
    case unavailable
}

final class SingleInstanceGuard {
    private static let processIdentifiers = Mutex<Set<String>>([])

    private var lockFileDescriptor: Int32 = -1
    private var heldIdentifier: String?

    func acquire(identifier: String) -> SingleInstanceAcquisition {
        if heldIdentifier == identifier { return .acquired }
        guard heldIdentifier == nil else { return .unavailable }
        guard Self.processIdentifiers.withLock({
            $0.insert(identifier).inserted
        }) else {
            return .alreadyRunning
        }

        let lockURL = Self.lockURL(identifier: identifier)
        let descriptor = Darwin.open(
            lockURL.path,
            O_CREAT | O_RDWR,
            mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else {
            Self.removeProcessIdentifier(identifier)
            return .unavailable
        }
        guard Self.setLock(descriptor: descriptor, type: Int16(F_WRLCK)) == 0 else {
            let lockError = errno
            Darwin.close(descriptor)
            Self.removeProcessIdentifier(identifier)
            return lockError == EACCES || lockError == EAGAIN
                ? .alreadyRunning
                : .unavailable
        }

        _ = Darwin.ftruncate(descriptor, 0)
        let owner = "\(ProcessInfo.processInfo.processIdentifier)\n"
        _ = owner.withCString {
            Darwin.write(descriptor, $0, owner.utf8.count)
        }
        lockFileDescriptor = descriptor
        heldIdentifier = identifier
        return .acquired
    }

    func release() {
        guard lockFileDescriptor >= 0, let identifier = heldIdentifier else {
            return
        }
        _ = Self.setLock(
            descriptor: lockFileDescriptor,
            type: Int16(F_UNLCK))
        Darwin.close(lockFileDescriptor)
        lockFileDescriptor = -1
        heldIdentifier = nil
        Self.removeProcessIdentifier(identifier)
    }

    static func lockURL(identifier: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("\(identifier).lock", isDirectory: false)
    }

    private static func setLock(descriptor: Int32, type: Int16) -> Int32 {
        var lock = flock()
        lock.l_start = 0
        lock.l_len = 0
        lock.l_pid = 0
        lock.l_type = type
        lock.l_whence = Int16(SEEK_SET)
        return Darwin.fcntl(descriptor, F_SETLK, &lock)
    }

    private static func removeProcessIdentifier(_ identifier: String) {
        _ = processIdentifiers.withLock {
            $0.remove(identifier)
        }
    }

    deinit {
        release()
    }
}
