import CryptoKit
import Foundation

// Updating the headphone library, only when the user asks: the database is downloaded from the project's mirror into a
// temporary file next to the cached copy (Application Support/Junction/HeadphoneLibrary), checked (complete, readable,
// with a sane number of models and presets, at least half the bundled copy's size), and only then made the cached copy.
// The cache holds the database under its SHA-256 (database-<sha>.jsonl, uncompressed) and library.json, which records
// its date, size and SHA-256; replacing library.json (an atomic rename) is what switches copies, so a failed or
// cancelled update leaves the current one as it was. A cached copy whose file doesn't match its record, or that fails
// the same checks, is ignored and the bundled copy is used.

/// Fetches a file. Junction's is `HeadphoneLibraryDownloader` (URLSession); the tests use a fake, so none of them touch
/// the network.
public protocol HeadphoneLibraryTransport: Sendable {
    /// Downloads `url` into `file` (which doesn't exist yet). Throws for any failure, and stops when its task is
    /// cancelled.
    func download(_ url: URL, to file: URL) async throws
}

/// Downloads with URLSession, without its cache.
public struct HeadphoneLibraryDownloader: HeadphoneLibraryTransport {
    public init() {}

    public func download(_ url: URL, to file: URL) async throws {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 60)
        request.setValue("Junction", forHTTPHeaderField: "User-Agent")
        let (temporary, response) = try await URLSession.shared.download(for: request)
        defer { try? FileManager.default.removeItem(at: temporary) }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw HeadphoneLibraryUpdateError.server(http.statusCode)
        }
        try FileManager.default.moveItem(at: temporary, to: file)
    }
}

public enum HeadphoneLibraryUpdateError: Error, LocalizedError, Equatable {
    case network(String)
    case server(Int)
    case cancelled
    case truncated
    case invalid(String)
    case tooSmall(size: Int, minimum: Int)
    case storage(String)

    public var errorDescription: String? {
        let kept = "The current headphone library is kept."
        return switch self {
        case .network(let reason): "The headphone library couldn't be downloaded: \(reason) \(kept)"
        case .server(let status): "The headphone library's server answered with error \(status). \(kept)"
        case .cancelled: "The headphone library update was cancelled. \(kept)"
        case .truncated: "The downloaded headphone library is incomplete: it ends in the middle of an entry. \(kept)"
        case .invalid(let reason): "The downloaded file isn't a usable headphone library: \(reason). \(kept)"
        case .tooSmall(let size, let minimum):
            "The downloaded headphone library is too small (\(size) bytes; at least \(minimum) expected). \(kept)"
        case .storage(let reason): "The downloaded headphone library couldn't be saved: \(reason) \(kept)"
        }
    }
}

/// The downloaded copy of the headphone library, and updating it.
public struct HeadphoneLibraryCache: Sendable {
    /// The project's mirror of the database.
    public static let mirrorURL = URL(string: "https://opra.roonlabs.net/database_v1.jsonl")!

    /// What library.json records about the cached copy.
    public struct Record: Codable, Hashable, Sendable {
        /// When it was downloaded.
        public var date: Date
        /// Bytes.
        public var size: Int
        /// Lowercase hex.
        public var sha256: String
    }

    /// What a copy must have to be used.
    public struct Requirements: Hashable, Sendable {
        public var minimumSize: Int
        public var minimumProducts: Int
        public var minimumPresets: Int

        public init(minimumSize: Int, minimumProducts: Int, minimumPresets: Int) {
            self.minimumSize = minimumSize
            self.minimumProducts = minimumProducts
            self.minimumPresets = minimumPresets
        }

        /// At least half the bundled copy's size, and a thousand models and presets (it has over 6,000 and 12,000).
        public static let standard = Requirements(minimumSize: HeadphoneLibrary.bundledSize / 2, minimumProducts: 1_000,
                                                  minimumPresets: 1_000)
    }

    public let folder: URL

    /// `folder` defaults to HeadphoneLibrary in Junction's Application Support folder (or `$JUNCTION_HOME`).
    public init(folder: URL? = nil) {
        self.folder = folder ?? Store().folder.appendingPathComponent("HeadphoneLibrary", isDirectory: true)
    }

    public var recordURL: URL { folder.appendingPathComponent("library.json") }

    public func databaseURL(for record: Record) -> URL { folder.appendingPathComponent("database-\(record.sha256).jsonl") }

    /// The cached copy's record, if there is one that can be read (its file may still not match it).
    public var record: Record? {
        guard let data = try? Data(contentsOf: recordURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let record = try? decoder.decode(Record.self, from: data),
              record.sha256.count == 64, record.sha256.allSatisfy({ "0123456789abcdef".contains($0) }) else { return nil }
        return record
    }

    // MARK: Reading

    /// The cached copy, read and checked off the main thread. Throws when there is none or it isn't valid.
    public func load(requirements: Requirements = .standard) async throws -> HeadphoneLibrary {
        try await Task.detached(priority: .userInitiated) { try self.read(requirements: requirements) }.value
    }

    /// The cached copy, read and checked on the calling thread: its file must match its record and pass the checks.
    public func read(requirements: Requirements = .standard) throws -> HeadphoneLibrary {
        guard let record else { throw HeadphoneLibraryError.missing(recordURL.lastPathComponent) }
        let url = databaseURL(for: record)
        guard let data = try? Data(contentsOf: url) else { throw HeadphoneLibraryError.missing(url.lastPathComponent) }
        guard data.count == record.size, Self.sha256(data) == record.sha256 else {
            throw HeadphoneLibraryError.unreadable(url.lastPathComponent)
        }
        return try Self.check(data, date: record.date, requirements: requirements)
    }

    /// A library from a downloaded file, if it is complete, readable and big enough.
    static func check(_ data: Data, date: Date, requirements: Requirements) throws -> HeadphoneLibrary {
        guard let last = data.last else { throw HeadphoneLibraryUpdateError.invalid("it is empty") }
        guard last == UInt8(ascii: "\n") else { throw HeadphoneLibraryUpdateError.truncated }
        let library = HeadphoneLibrary(jsonl: data, source: .downloaded, date: date)
        let summary = library.summary
        guard summary.products > 0, summary.presets > 0 else {
            throw HeadphoneLibraryUpdateError.invalid("it has no headphones or presets")
        }
        let entries = summary.brands + summary.products + summary.presets + summary.droppedProducts
            + summary.droppedPresets + summary.unreadableLines
        guard summary.unreadableLines * 100 <= entries else {
            throw HeadphoneLibraryUpdateError.invalid("\(summary.unreadableLines) of its lines can't be read")
        }
        guard data.count >= requirements.minimumSize else {
            throw HeadphoneLibraryUpdateError.tooSmall(size: data.count, minimum: requirements.minimumSize)
        }
        guard summary.products >= requirements.minimumProducts, summary.presets >= requirements.minimumPresets else {
            throw HeadphoneLibraryUpdateError.invalid("it lists only \(summary.products) headphones and \(summary.presets) presets")
        }
        return library
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Updating

    /// Downloads the database, checks it and makes it the cached copy, recording `date`; returns it as a library.
    /// Cancelling the task stops it. Any failure throws a `HeadphoneLibraryUpdateError` and leaves the cached copy (or
    /// its absence) as it was. Run one update at a time.
    public func update(transport: HeadphoneLibraryTransport = HeadphoneLibraryDownloader(), from url: URL = mirrorURL,
                       date: Date = Date(), requirements: Requirements = .standard) async throws -> HeadphoneLibrary {
        let files = FileManager.default
        do {
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            throw HeadphoneLibraryUpdateError.storage(error.localizedDescription)
        }
        // Next to the cached copy, so moving it in is a rename on the same volume.
        let partial = folder.appendingPathComponent("download-\(UUID().uuidString).partial")
        defer { try? files.removeItem(at: partial) }
        do {
            try await transport.download(url, to: partial)
        } catch let error as HeadphoneLibraryUpdateError {
            throw Task.isCancelled ? .cancelled : error
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw HeadphoneLibraryUpdateError.cancelled
            }
            throw HeadphoneLibraryUpdateError.network(error.localizedDescription)
        }
        if Task.isCancelled { throw HeadphoneLibraryUpdateError.cancelled }

        let (library, record) = try await Task.detached(priority: .userInitiated) {
            guard let data = try? Data(contentsOf: partial) else { throw HeadphoneLibraryUpdateError.invalid("it can't be read") }
            let library = try Self.check(data, date: date, requirements: requirements)
            return (library, Record(date: date, size: data.count, sha256: Self.sha256(data)))
        }.value
        if Task.isCancelled { throw HeadphoneLibraryUpdateError.cancelled }

        // The database goes in under its own name, then library.json is replaced: until then the old copy is in use.
        // (The same content under the same name is renamed over it: a damaged copy of it is replaced too.)
        let previous = self.record
        let database = databaseURL(for: record)
        let pending = folder.appendingPathComponent("library-\(UUID().uuidString).partial")
        defer { try? files.removeItem(at: pending) }
        func move(_ from: URL, to: URL) throws {
            guard rename(from.path, to.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        do {
            try move(partial, to: database)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(record).write(to: pending)
            try move(pending, to: recordURL)
        } catch {
            if previous?.sha256 != record.sha256 { try? files.removeItem(at: database) }
            throw HeadphoneLibraryUpdateError.storage(error.localizedDescription)
        }
        if let previous, previous.sha256 != record.sha256 { try? files.removeItem(at: databaseURL(for: previous)) }
        return library
    }
}

extension HeadphoneLibrary {
    /// The downloaded copy when there is a valid one, otherwise the bundled copy (`bundledURL`, dated `bundledDate`);
    /// `summary.source` says which. Read off the main thread.
    public static func loadPreferred(cache: HeadphoneLibraryCache = HeadphoneLibraryCache(),
                                     bundledURL: URL? = bundledDatabaseURL,
                                     requirements: HeadphoneLibraryCache.Requirements = .standard) async throws -> HeadphoneLibrary {
        if let downloaded = try? await cache.load(requirements: requirements) { return downloaded }
        guard let bundledURL else { throw HeadphoneLibraryError.missing("database_v1.jsonl.lzma") }
        return try await load(contentsOf: bundledURL, source: .bundled, date: bundledDate)
    }
}
