import Foundation
import XCTest
@testable import JunctionCore

// Updating the headphone library: downloads through a fake transport into temporary folders (no test touches the
// network), the checks a download must pass, atomic replacement of the cached copy, and which copy is used.

final class HeadphoneLibraryUpdateTests: XCTestCase {
    /// The bundled copy, uncompressed: what the mirror serves.
    static let bundledJSONL: Data = {
        let compressed = try! Data(contentsOf: HeadphoneLibraryTests.bundled)
        return try! (compressed as NSData).decompressed(using: .lzma) as Data
    }()
    /// SOURCE.md's SHA-256 of the bundled copy, uncompressed.
    static let bundledSHA256 = "5c4cf9e2f71c696bf4fc5b4d1a46c57f31c6d0041552c2146fcd1413596fd210"
    static let date = Date(timeIntervalSince1970: 1_795_000_000)

    /// Serves data, fails, or hangs until cancelled; remembers what it was asked for.
    final class FakeTransport: HeadphoneLibraryTransport, @unchecked Sendable {
        enum Behaviour {
            case serve(Data)
            case fail(Error)
            /// Writes part of a file, then waits to be cancelled.
            case hang(Data)
        }

        let behaviour: Behaviour
        private let lock = NSLock()
        private var urls: [URL] = []
        private var files: [URL] = []

        init(_ behaviour: Behaviour) { self.behaviour = behaviour }

        var requested: [URL] { lock.withLock { urls } }
        var written: [URL] { lock.withLock { files } }

        func download(_ url: URL, to file: URL) async throws {
            lock.withLock {
                urls.append(url)
                files.append(file)
            }
            switch behaviour {
            case .serve(let data): try data.write(to: file)
            case .fail(let error): throw error
            case .hang(let part):
                try part.write(to: file)
                while true { try await Task.sleep(nanoseconds: 5_000_000) }
            }
        }
    }

    private var folders: [URL] = []

    override func tearDown() {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []
        super.tearDown()
    }

    private func temporaryCache() -> HeadphoneLibraryCache {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("junction-library-update-\(UUID().uuidString)")
        folders.append(folder)
        return HeadphoneLibraryCache(folder: folder)
    }

    private func contents(_ cache: HeadphoneLibraryCache) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: cache.folder.path)) ?? []).sorted()
    }

    /// A made-up, complete library with `count` models and a preset for each.
    private func madeUp(_ count: Int, brand: String = "Acme") -> Data {
        var lines = [#"{"type":"vendor","id":"acme","data":{"name":"\#(brand)"}}"#]
        for index in 0..<count {
            lines.append(#"{"type":"product","id":"acme::m\#(index)","data":{"name":"Model \#(index)","type":"headphones","subtype":"over_the_ear","vendor_id":"acme"}}"#)
            lines.append(#"{"type":"eq","id":"acme:m\#(index)::flat","data":{"author":"Tuner","details":"Target","type":"parametric_eq","parameters":{"gain_db":-2,"bands":[{"type":"peak_dip","frequency":1000,"gain_db":-2,"q":1}]},"product_id":"acme::m\#(index)"}}"#)
        }
        return Data((lines.joined(separator: "\n") + "\n").utf8)
    }

    private let relaxed = HeadphoneLibraryCache.Requirements(minimumSize: 0, minimumProducts: 1, minimumPresets: 1)

    private func update(_ cache: HeadphoneLibraryCache, _ transport: FakeTransport, date: Date = date,
                        requirements: HeadphoneLibraryCache.Requirements = .standard) async throws -> HeadphoneLibrary {
        try await cache.update(transport: transport, date: date, requirements: requirements)
    }

    private func updateError(_ cache: HeadphoneLibraryCache, _ transport: FakeTransport,
                             requirements: HeadphoneLibraryCache.Requirements = .standard,
                             file: StaticString = #filePath, line: UInt = #line) async -> HeadphoneLibraryUpdateError? {
        do {
            _ = try await update(cache, transport, requirements: requirements)
            XCTFail("the update succeeded", file: file, line: line)
            return nil
        } catch {
            let failure = error as? HeadphoneLibraryUpdateError
            XCTAssertNotNil(failure, "\(error)", file: file, line: line)
            XCTAssertTrue(failure?.errorDescription?.hasSuffix("The current headphone library is kept.") ?? false,
                          file: file, line: line)
            return failure
        }
    }

    // MARK: Success

    func testAnUpdateDownloadsTheMirrorChecksItAndRecordsIt() async throws {
        let bundled = Self.bundledJSONL
        XCTAssertEqual(bundled.count, HeadphoneLibrary.bundledSize, "SOURCE.md's size")
        XCTAssertEqual(HeadphoneLibraryCache.Requirements.standard.minimumSize, HeadphoneLibrary.bundledSize / 2)
        let cache = temporaryCache()
        XCTAssertNil(cache.record)
        let transport = FakeTransport(.serve(bundled))
        let library = try await update(cache, transport)
        XCTAssertEqual(transport.requested, [URL(string: "https://opra.roonlabs.net/database_v1.jsonl")!])
        XCTAssertEqual(transport.written.map { $0.deletingLastPathComponent().standardizedFileURL.path },
                       [cache.folder.standardizedFileURL.path], "downloaded into a temporary file next to the cached copy")
        XCTAssertEqual(library.summary.source, .downloaded)
        XCTAssertEqual(library.summary.date, Self.date)
        XCTAssertEqual(library.summary.brands, 714)
        XCTAssertEqual(library.summary.products, 6_230)
        XCTAssertEqual(library.summary.presets, 12_594)

        let record = try XCTUnwrap(cache.record)
        XCTAssertEqual(record, HeadphoneLibraryCache.Record(date: Self.date, size: bundled.count, sha256: Self.bundledSHA256))
        XCTAssertEqual(contents(cache), ["database-\(Self.bundledSHA256).jsonl", "library.json"], "no temporary file left")
        XCTAssertEqual(try Data(contentsOf: cache.databaseURL(for: record)), bundled)

        // It is the copy used from now on, with its date and counts.
        let preferred = try await HeadphoneLibrary.loadPreferred(cache: cache, bundledURL: HeadphoneLibraryTests.fixture)
        XCTAssertEqual(preferred.summary, library.summary)
        XCTAssertFalse(preferred.indexedOnMainThread)
    }

    func testANewerCopyReplacesTheOldOne() async throws {
        let cache = temporaryCache()
        let first = try await update(cache, FakeTransport(.serve(madeUp(3))), requirements: relaxed)
        let old = try XCTUnwrap(cache.record)
        XCTAssertEqual(first.summary.products, 3)
        let later = Self.date.addingTimeInterval(86_400)
        let second = try await update(cache, FakeTransport(.serve(madeUp(5))), date: later, requirements: relaxed)
        let new = try XCTUnwrap(cache.record)
        XCTAssertNotEqual(new.sha256, old.sha256)
        XCTAssertEqual(new.date, later)
        XCTAssertEqual(second.summary.products, 5)
        XCTAssertEqual(contents(cache), ["database-\(new.sha256).jsonl", "library.json"], "the old copy is removed")
        XCTAssertEqual(try cache.read(requirements: relaxed).summary.products, 5)

        // The same file again only records the new date.
        let again = later.addingTimeInterval(86_400)
        _ = try await update(cache, FakeTransport(.serve(madeUp(5))), date: again, requirements: relaxed)
        XCTAssertEqual(cache.record, HeadphoneLibraryCache.Record(date: again, size: new.size, sha256: new.sha256))
        XCTAssertEqual(contents(cache), ["database-\(new.sha256).jsonl", "library.json"])
    }

    // MARK: Failures

    /// A current copy, then every kind of failure: each throws its error and leaves the copy, its record and the folder
    /// exactly as they were.
    func testFailuresKeepTheCurrentCopyIntact() async throws {
        let cache = temporaryCache()
        let current = madeUp(4)
        _ = try await update(cache, FakeTransport(.serve(current)), requirements: relaxed)
        let record = try XCTUnwrap(cache.record)
        let recordBytes = try Data(contentsOf: cache.recordURL)
        let listing = contents(cache)

        func assertIntact(_ what: String, file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertEqual(contents(cache), listing, what, file: file, line: line)
            XCTAssertEqual(try Data(contentsOf: cache.recordURL), recordBytes, what, file: file, line: line)
            XCTAssertEqual(try Data(contentsOf: cache.databaseURL(for: record)), current, what, file: file, line: line)
            XCTAssertEqual(try cache.read(requirements: relaxed).summary.products, 4, what, file: file, line: line)
        }

        let offline = await updateError(cache, FakeTransport(.fail(URLError(.notConnectedToInternet))))
        guard case .network(let reason) = offline else { return XCTFail("\(String(describing: offline))") }
        XCTAssertFalse(reason.isEmpty)
        try assertIntact("network error")

        let server = await updateError(cache, FakeTransport(.fail(HeadphoneLibraryUpdateError.server(404))))
        XCTAssertEqual(server, .server(404))
        try assertIntact("server error")

        // Cut off in the middle of an entry, well above the minimum size.
        let bundled = Self.bundledJSONL
        let truncated = await updateError(cache, FakeTransport(.serve(bundled.prefix(bundled.count * 4 / 5))))
        XCTAssertEqual(truncated, .truncated)
        try assertIntact("truncated")

        // Big enough, but not a library (an error page, say).
        let page = Data(String(repeating: "<html><body>Service unavailable</body></html>\n", count: 200_000).utf8)
        XCTAssertGreaterThan(page.count, HeadphoneLibrary.bundledSize / 2)
        let invalid = await updateError(cache, FakeTransport(.serve(page)))
        XCTAssertEqual(invalid, .invalid("it has no headphones or presets"))
        try assertIntact("invalid")
        let nothing = await updateError(cache, FakeTransport(.serve(Data())))
        XCTAssertEqual(nothing, .invalid("it is empty"))
        try assertIntact("empty")
        // Mostly readable isn't enough: more than one line in a hundred can't be read.
        let damaged = madeUp(20) + Data(String(repeating: "{\"type\":\n", count: 2).utf8)
        let unreadable = await updateError(cache, FakeTransport(.serve(damaged)), requirements: relaxed)
        XCTAssertEqual(unreadable, .invalid("2 of its lines can't be read"))
        try assertIntact("damaged")

        // Complete and readable, with plenty of models, but under half the bundled copy's size.
        let small = madeUp(2_000)
        XCTAssertLessThan(small.count, HeadphoneLibrary.bundledSize / 2)
        let tooSmall = await updateError(cache, FakeTransport(.serve(small)))
        XCTAssertEqual(tooSmall, .tooSmall(size: small.count, minimum: HeadphoneLibrary.bundledSize / 2))
        try assertIntact("too small")
        // Big enough, but too few models and presets.
        let few = await updateError(cache, FakeTransport(.serve(madeUp(10))),
                                    requirements: .init(minimumSize: 0, minimumProducts: 1_000, minimumPresets: 1_000))
        XCTAssertEqual(few, .invalid("it lists only 10 headphones and 10 presets"))
        try assertIntact("too few")

        // Without a current copy, a failure leaves none.
        let empty = temporaryCache()
        _ = await updateError(empty, FakeTransport(.serve(small)))
        XCTAssertEqual(contents(empty), [])
        XCTAssertNil(empty.record)
        let preferred = try await HeadphoneLibrary.loadPreferred(cache: empty, bundledURL: HeadphoneLibraryTests.fixture)
        XCTAssertEqual(preferred.summary.source, .bundled)
    }

    func testAnUpdateCanBeCancelled() async throws {
        let cache = temporaryCache()
        let current = madeUp(4)
        _ = try await update(cache, FakeTransport(.serve(current)), requirements: relaxed)
        let recordBytes = try Data(contentsOf: cache.recordURL)
        let listing = contents(cache)

        let transport = FakeTransport(.hang(Self.bundledJSONL.prefix(1_000)))
        let task = Task { try await self.update(cache, transport, requirements: self.relaxed) }
        // Wait for the download to start, then cancel it.
        for _ in 0..<1_000 where contents(cache).count == listing.count {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(contents(cache).count, listing.count + 1, "the temporary file is there while it downloads")
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("a cancelled update succeeded")
        } catch {
            XCTAssertEqual(error as? HeadphoneLibraryUpdateError, .cancelled)
        }
        XCTAssertEqual(contents(cache), listing, "the temporary file is removed")
        XCTAssertEqual(try Data(contentsOf: cache.recordURL), recordBytes)
        XCTAssertEqual(try cache.read(requirements: relaxed).summary.products, 4)

        // URLSession reports its own cancellation as an URLError.
        let urlCancelled = await updateError(cache, FakeTransport(.fail(URLError(.cancelled))))
        XCTAssertEqual(urlCancelled, .cancelled)
        XCTAssertEqual(contents(cache), listing)
    }

    // MARK: Which copy is used

    func testAValidDownloadedCopyIsPreferredAndAnInvalidOneIgnored() async throws {
        let fixture = HeadphoneLibraryTests.fixture
        let none = try await HeadphoneLibrary.loadPreferred(cache: temporaryCache(), bundledURL: fixture,
                                                           requirements: relaxed)
        XCTAssertEqual(none.summary.source, .bundled)
        XCTAssertEqual(none.summary.date, HeadphoneLibrary.bundledDate)
        XCTAssertEqual(none.summary.products, 5, "the fixture standing in for the bundled copy")

        func preferred(_ cache: HeadphoneLibraryCache,
                       _ requirements: HeadphoneLibraryCache.Requirements? = nil) async throws -> HeadphoneLibrary.Summary {
            try await HeadphoneLibrary.loadPreferred(cache: cache, bundledURL: fixture,
                                                     requirements: requirements ?? relaxed).summary
        }

        let cache = temporaryCache()
        _ = try await update(cache, FakeTransport(.serve(madeUp(7))), requirements: relaxed)
        let record = try XCTUnwrap(cache.record)
        var summary = try await preferred(cache)
        XCTAssertEqual(summary.source, .downloaded)
        XCTAssertEqual(summary.date, Self.date)
        XCTAssertEqual(summary.products, 7)
        XCTAssertEqual(summary.presets, 7)

        // A copy that is valid but fails the requirements in force (too small for the real ones) is ignored.
        summary = try await preferred(cache, .standard)
        XCTAssertEqual(summary.source, .bundled)

        // Changed on disk: no longer what its record says.
        let database = cache.databaseURL(for: record)
        let good = try Data(contentsOf: database)
        var changed = good
        changed[changed.count / 2] ^= 0x20
        try changed.write(to: database)
        XCTAssertThrowsError(try cache.read(requirements: relaxed))
        summary = try await preferred(cache)
        XCTAssertEqual(summary.source, .bundled)
        XCTAssertEqual(summary.products, 5)

        // Missing.
        try FileManager.default.removeItem(at: database)
        summary = try await preferred(cache)
        XCTAssertEqual(summary.source, .bundled)

        // A record that can't be read.
        try good.write(to: database)
        summary = try await preferred(cache)
        XCTAssertEqual(summary.source, .downloaded)
        try Data("{\"date\":".utf8).write(to: cache.recordURL)
        XCTAssertNil(cache.record)
        summary = try await preferred(cache)
        XCTAssertEqual(summary.source, .bundled)

        // A record naming a file that matches it but isn't a usable library.
        let truncated = good.prefix(good.count - 10)
        let sha = HeadphoneLibraryCache.sha256(truncated)
        try FileManager.default.removeItem(at: database)
        try truncated.write(to: cache.folder.appendingPathComponent("database-\(sha).jsonl"))
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(HeadphoneLibraryCache.Record(date: Self.date, size: truncated.count, sha256: sha))
            .write(to: cache.recordURL)
        XCTAssertThrowsError(try cache.read(requirements: relaxed)) {
            XCTAssertEqual($0 as? HeadphoneLibraryUpdateError, .truncated)
        }
        summary = try await preferred(cache)
        XCTAssertEqual(summary.source, .bundled)
    }

    func testTheCacheLivesInJunctionsApplicationSupportFolder() {
        let cache = HeadphoneLibraryCache()
        XCTAssertEqual(cache.folder.standardizedFileURL.path,
                       Store().folder.appendingPathComponent("HeadphoneLibrary").standardizedFileURL.path)
        XCTAssertEqual(HeadphoneLibraryCache.mirrorURL.absoluteString, "https://opra.roonlabs.net/database_v1.jsonl")
    }
}
