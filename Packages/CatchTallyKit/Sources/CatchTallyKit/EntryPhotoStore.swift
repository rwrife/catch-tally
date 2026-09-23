import Foundation

/// File-storage error surface for photo copying.
public enum PhotoStoreError: Error, Equatable, Sendable {
    /// An attach was requested with a reference the store already holds —
    /// the caller must detach the current photo first (one photo per entry,
    /// so no orphan files can exist).
    case photoAlreadyAttached
    /// A detach/replace was requested but no photo exists at that reference.
    case photoMissing(String)
}

/// Abstraction over the app-private photo copy store (issue #4).
///
/// The domain never touches photos directly — the app injects an
/// implementation writing into an app-private container (Documents or
/// Application Support subdirectory). No photo-library write-back ever
/// happens: the picker hands over image data, the app stores its own copy.
/// Linux tests inject an in-memory fake to prove the full photo-copy
/// lifecycle without a filesystem.
public protocol EntryPhotoStore: Sendable {
    /// Store bytes under a reference (e.g. UUID filename). Idempotent.
    func writePhoto(data: Data, ref: String) throws
    /// Read back the stored bytes; nil ⇒ not present.
    func readPhoto(ref: String) throws -> Data?
    /// Approximate on-disk bytes for `ref`; 0 ⇒ not present.
    func byteCount(ref: String) throws -> Int
    /// Delete the stored bytes; missing files are not an error.
    func deletePhoto(ref: String) throws
}

/// In-memory `EntryPhotoStore` for tests and transient sessions.
public final class InMemoryPhotoStore: EntryPhotoStore, @unchecked Sendable {
    private let lock = NSLock()
    private var files: [String: Data] = [:]

    public init() {}

    public func writePhoto(data: Data, ref: String) throws {
        lock.lock(); defer { lock.unlock() }
        files[ref] = data
    }

    public func readPhoto(ref: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return files[ref]
    }

    public func byteCount(ref: String) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        return files[ref]?.count ?? 0
    }

    public func deletePhoto(ref: String) throws {
        lock.lock(); defer { lock.unlock() }
        files[ref] = nil
    }

    /// Test aid: all currently-held references.
    public var refs: [String] {
        lock.lock(); defer { lock.unlock() }
        return files.keys.sorted()
    }
}

/// File-backed `EntryPhotoStore` writing into an app-private directory.
public final class DirectoryPhotoStore: EntryPhotoStore, @unchecked Sendable {
    private let directory: URL

    /// Create (or adopt) the private photos directory.
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
    }

    private func fileURL(ref: String) -> URL {
        // refs are app-generated filenames (UUIDs); refuse anything that
        // could escape the private directory.
        let name = (ref as NSString).lastPathComponent
        return directory.appendingPathComponent(name)
    }

    public func writePhoto(data: Data, ref: String) throws {
        try data.write(to: fileURL(ref: ref), options: .atomic)
    }

    public func readPhoto(ref: String) throws -> Data? {
        let url = fileURL(ref: ref)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    public func byteCount(ref: String) throws -> Int {
        let url = fileURL(ref: ref)
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return 0 }
        return (attrs[.size] as? Int) ?? 0
    }

    public func deletePhoto(ref: String) throws {
        let url = fileURL(ref: ref)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
