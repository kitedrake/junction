import Foundation

// The headphone library: ready-made parametric EQ presets from the bundled copy of the OPRA database
// (Resources/HeadphoneLibrary; SOURCE.md there says which copy). The database is JSON Lines, one entry per line:
// {"type": …, "id": …, "data": {…}}. Vendors ("vendor": a name) are the brands; products ("product": a name, a type and
// subtype, the vendor's id) the models; presets ("eq": an author, details, an optional link, the product's id and a
// parametric EQ: a gain and bands). Other entry types and fields are ignored, lines that can't be read are skipped and
// counted, and so are presets whose product or brand is missing. It is read once, off the main thread, into an index
// that search runs over without touching the data again.

/// Where a profile from the headphone library came from, kept with it: the database's licence asks for its authors to
/// be credited.
public struct HeadphoneLibraryCredit: Codable, Hashable, Sendable {
    /// The preset's id in the library ("brand:model::preset").
    public var presetID: String
    public var author: String
    /// What the preset was made from or for ("Measured by …", "Harman Target").
    public var details: String
    /// The author's page for the preset, when the data has one.
    public var link: String?

    public init(presetID: String, author: String, details: String, link: String? = nil) {
        self.presetID = presetID
        self.author = author
        self.details = details
        self.link = link
    }
}

/// A kind of headphone as the data names it: a type ("headphones") and a subtype ("over_the_ear", "in_ear", …).
public struct HeadphoneStyle: Hashable, Sendable {
    public var type: String
    public var subtype: String

    public init(type: String, subtype: String) {
        self.type = type
        self.subtype = subtype
    }

    /// The style as shown: "Over-ear", "On-ear", "In-ear", "Earbuds", or the data's own word for others.
    public var name: String {
        switch subtype {
        case "over_the_ear", "over_ear": return "Over-ear"
        case "on_ear": return "On-ear"
        case "in_ear": return "In-ear"
        case "earbuds": return "Earbuds"
        default:
            let word = (subtype.isEmpty ? type : subtype).replacingOccurrences(of: "_", with: " ")
            return word.prefix(1).uppercased() + word.dropFirst()
        }
    }
}

/// One headphone model with its presets.
public struct HeadphoneModel: Hashable, Identifiable, Sendable {
    /// The product's id in the library.
    public var id: String
    public var brand: String
    public var model: String
    public var style: HeadphoneStyle
    /// In the database's order.
    public var presets: [HeadphonePreset]

    public init(id: String, brand: String, model: String, style: HeadphoneStyle, presets: [HeadphonePreset]) {
        self.id = id
        self.brand = brand
        self.model = model
        self.style = style
        self.presets = presets
    }

    /// "Brand Model".
    public var name: String { "\(brand) \(model)" }
}

/// One parametric EQ preset for a model: loadable as a whole, or unavailable with the reason.
public struct HeadphonePreset: Hashable, Identifiable, Sendable {
    public var id: String
    public var author: String
    public var details: String
    public var link: String?
    /// dB, as the data gives it.
    public var preamp: Double
    /// The bands as filters, in the data's order; empty when the preset is unavailable (never part of it).
    public var filters: [CalibrationFilter]
    /// Why Junction can't load it (nil: it can).
    public var problem: String?

    public init(id: String, author: String, details: String, link: String? = nil, preamp: Double,
                filters: [CalibrationFilter], problem: String? = nil) {
        self.id = id
        self.author = author
        self.details = details
        self.link = link
        self.preamp = preamp
        self.filters = problem == nil ? filters : []
        self.problem = problem
    }

    public var isAvailable: Bool { problem == nil }

    public var credit: HeadphoneLibraryCredit {
        HeadphoneLibraryCredit(presetID: id, author: author, details: details, link: link)
    }
}

/// A search's models in order, read from the library as they are used (nothing is copied).
public struct HeadphoneSearchResults: RandomAccessCollection, Sendable {
    let models: [HeadphoneModel]
    let positions: [Int]

    public var startIndex: Int { 0 }
    public var endIndex: Int { positions.count }
    public subscript(position: Int) -> HeadphoneModel { models[positions[position]] }
}

public enum HeadphoneLibraryError: Error, LocalizedError, Equatable {
    case missing(String)
    case unreadable(String)
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .missing(let name): "The headphone library “\(name)” isn't there."
        case .unreadable(let name): "The headphone library “\(name)” can't be read."
        case .unavailable(let reason): "Junction can't load this preset: \(reason)."
        }
    }
}

public struct HeadphoneLibrary: Sendable {
    public enum Source: String, Hashable, Sendable {
        /// The copy inside Junction.app.
        case bundled
        /// A copy downloaded on request into Application Support (see `HeadphoneLibraryCache`).
        case downloaded
    }

    /// What was read: where from, when the data was taken, and the counts (for the credits and the self-test).
    public struct Summary: Hashable, Sendable {
        public var source: Source
        /// When the data was taken from the database.
        public var date: Date?
        public var brands: Int
        public var products: Int
        public var presets: Int
        /// Presets listed but not loadable (a band type Junction doesn't have, for example).
        public var unavailablePresets: Int
        /// Lines that aren't an entry Junction can read (not JSON, an entry missing its id or name, or one repeating
        /// an id).
        public var unreadableLines: Int
        /// Products whose brand isn't in the data, and presets whose product or brand isn't: left out.
        public var droppedProducts: Int
        public var droppedPresets: Int
    }

    /// The bundled copy's folder and database inside Junction.app (with its licences, logo and SOURCE.md).
    public static var bundledFolder: URL? { Bundle.main.resourceURL?.appendingPathComponent("HeadphoneLibrary") }
    public static var bundledDatabaseURL: URL? { bundledFolder?.appendingPathComponent("database_v1.jsonl.lzma") }
    /// When the bundled copy was taken (see SOURCE.md).
    public static let bundledDate = DateComponents(calendar: Calendar(identifier: .gregorian),
                                                   timeZone: TimeZone(identifier: "UTC"), year: 2026, month: 11, day: 26).date!
    /// The bundled copy's size uncompressed, in bytes (see SOURCE.md): a download must be at least half of it.
    public static let bundledSize = 12_636_756

    public let summary: Summary
    /// Every model, by brand and then model.
    public let models: [HeadphoneModel]
    private let index: SearchIndex
    private let positions: [String: Int]
    /// Whether the index was built on the main thread (it shouldn't be: see `load`).
    let indexedOnMainThread: Bool

    /// The bundled library, read off the main thread.
    public static func loadBundled() async throws -> HeadphoneLibrary {
        guard let url = bundledDatabaseURL else { throw HeadphoneLibraryError.missing("database_v1.jsonl.lzma") }
        return try await load(contentsOf: url, source: .bundled, date: bundledDate)
    }

    /// A library file (".lzma": compressed as the bundled one is), read and indexed off the main thread.
    public static func load(contentsOf url: URL, source: Source, date: Date?) async throws -> HeadphoneLibrary {
        try await Task.detached(priority: .userInitiated) {
            try HeadphoneLibrary(contentsOf: url, source: source, date: date)
        }.value
    }

    /// A library file read and indexed on the calling thread (`load` does it off the main thread).
    public init(contentsOf url: URL, source: Source, date: Date?) throws {
        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url) else { throw HeadphoneLibraryError.missing(name) }
        var jsonl = data
        if url.pathExtension == "lzma" {
            guard let decompressed = try? (data as NSData).decompressed(using: .lzma) as Data else {
                throw HeadphoneLibraryError.unreadable(name)
            }
            jsonl = decompressed
        }
        self.init(jsonl: jsonl, source: source, date: date)
    }

    /// A library from the database's JSON Lines.
    public init(jsonl: Data, source: Source, date: Date?) {
        var brands: [String: String] = [:]
        var products: [(id: String, name: String, brand: String, style: HeadphoneStyle)] = []
        var presets: [(product: String, preset: HeadphonePreset)] = []
        var seen = Set<String>()
        var unreadable = 0
        for line in jsonl.split(separator: UInt8(ascii: "\n")) {
            let line = line.last == UInt8(ascii: "\r") ? line.dropLast() : line
            guard line.contains(where: { $0 != UInt8(ascii: " ") && $0 != UInt8(ascii: "\t") }) else { continue }
            guard let entry = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any],
                  let type = entry["type"] as? String else { unreadable += 1; continue }
            guard ["vendor", "product", "eq"].contains(type) else { continue }  // other entries: not ours
            guard let id = entry["id"] as? String, let data = entry["data"] as? [String: Any], seen.insert(type + "\n" + id).inserted
            else { unreadable += 1; continue }
            switch type {
            case "vendor":
                guard let name = data["name"] as? String else { unreadable += 1; continue }
                brands[id] = name
            case "product":
                guard let name = data["name"] as? String, let brand = data["vendor_id"] as? String else { unreadable += 1; continue }
                products.append((id, name, brand, HeadphoneStyle(type: data["type"] as? String ?? "",
                                                                 subtype: data["subtype"] as? String ?? "")))
            default:
                guard let product = data["product_id"] as? String else { unreadable += 1; continue }
                presets.append((product, Self.preset(id: id, data)))
            }
        }

        var byProduct: [String: [HeadphonePreset]] = [:]
        for (product, preset) in presets { byProduct[product, default: []].append(preset) }
        var models: [HeadphoneModel] = []
        var droppedProducts = 0
        for product in products {
            guard let brand = brands[product.brand] else { droppedProducts += 1; continue }
            models.append(HeadphoneModel(id: product.id, brand: brand, model: product.name, style: product.style,
                                         presets: byProduct[product.id] ?? []))
        }
        let names = models.map { (brand: SearchIndex.fold($0.brand), model: SearchIndex.fold($0.model)) }
        let order = models.indices.sorted { (names[$0].brand, names[$0].model, $0) < (names[$1].brand, names[$1].model, $1) }
        self.models = order.map { models[$0] }
        index = SearchIndex(self.models)
        positions = Dictionary(self.models.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        indexedOnMainThread = Thread.isMainThread
        let listed = self.models.reduce(0) { $0 + $1.presets.count }
        summary = Summary(source: source, date: date, brands: brands.count, products: self.models.count, presets: listed,
                          unavailablePresets: self.models.reduce(0) { $0 + $1.presets.filter { !$0.isAvailable }.count },
                          unreadableLines: unreadable, droppedProducts: droppedProducts,
                          droppedPresets: presets.count - listed)
    }

    /// The styles the data has, the most common first.
    public var styles: [HeadphoneStyle] {
        var counts: [HeadphoneStyle: Int] = [:]
        for model in models { counts[model.style, default: 0] += 1 }
        return counts.keys.sorted { (-counts[$0]!, $0.name) < (-counts[$1]!, $1.name) }
    }

    public func model(id: String) -> HeadphoneModel? { positions[id].map { models[$0] } }

    // MARK: Search

    /// Models whose brand and model contain every word of `query` (in any case, with or without accents, spaces or
    /// dashes: "hd600" finds "HD 600"), of `style` when given. Those whose model, or brand and model, start with the
    /// query come first, then those where every word starts one of theirs, then the rest; each group by brand and
    /// model. An empty query lists every model.
    public func search(_ query: String, style: HeadphoneStyle? = nil) -> HeadphoneSearchResults {
        HeadphoneSearchResults(models: models, positions: index.search(query, style: style))
    }

    /// Every model's brand and model words, folded (case, accents, width) and run together as UTF-8, in one buffer
    /// with plain-number entries, so a query is a few C string comparisons per model.
    private struct SearchIndex: Sendable {
        struct Entry: Sendable {
            /// The model's bytes in `text`: brand then model words, without spaces; its model's start; its words in
            /// `wordStarts` and `wordEnds`; its style in `styles`.
            var start, end, modelStart, firstWord, wordCount, style: Int
        }

        var text: [UInt8] = []
        var wordStarts: [Int] = []
        var wordEnds: [Int] = []
        var entries: [Entry] = []
        var styles: [HeadphoneStyle: Int] = [:]

        init(_ models: [HeadphoneModel]) {
            for model in models {
                let style = styles[model.style] ?? styles.count
                styles[model.style] = style
                let start = text.count, firstWord = wordStarts.count
                var modelStart = start
                for (part, isModel) in [(model.brand, false), (model.model, true)] {
                    if isModel { modelStart = text.count }
                    for word in Self.words(part) {
                        wordStarts.append(text.count)
                        text.append(contentsOf: word.utf8)
                        wordEnds.append(text.count)
                    }
                }
                entries.append(Entry(start: start, end: text.count, modelStart: modelStart, firstWord: firstWord,
                                     wordCount: wordStarts.count - firstWord, style: style))
            }
        }

        static func fold(_ text: String) -> String {
            text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        }

        /// Folded words: runs of letters and digits.
        static func words(_ text: String) -> [String] {
            fold(text).split { !$0.isLetter && !$0.isNumber }.map(String.init)
        }

        /// The matching models' positions: those whose model, or brand and model, start with the query, then those
        /// where every query word starts a word, then those that contain every query word anywhere.
        func search(_ query: String, style: HeadphoneStyle?) -> [Int] {
            var wanted = -1
            if let style {
                guard let id = styles[style] else { return [] }
                wanted = id
            }
            var needle: [UInt8] = []  // the query's words run together
            var parts: [(start: Int, count: Int)] = []
            for word in Self.words(query) {
                parts.append((needle.count, word.utf8.count))
                needle.append(contentsOf: word.utf8)
            }
            var groups: [[Int]] = [[], [], []]
            text.withUnsafeBufferPointer { text in
                needle.withUnsafeBufferPointer { needle in
                    wordStarts.withUnsafeBufferPointer { wordStarts in
                        wordEnds.withUnsafeBufferPointer { wordEnds in
                            entries.withUnsafeBufferPointer { entries in
                                let t = text.baseAddress ?? UnsafePointer(bitPattern: 1)!
                                let n = needle.baseAddress ?? UnsafePointer(bitPattern: 1)!
                                for position in 0..<entries.count {
                                    let entry = entries[position]
                                    if wanted >= 0, entry.style != wanted { continue }
                                    if parts.isEmpty
                                        || (needle.count <= entry.end - entry.modelStart && memcmp(t + entry.modelStart, n, needle.count) == 0)
                                        || (needle.count <= entry.end - entry.start && memcmp(t + entry.start, n, needle.count) == 0) {
                                        groups[0].append(position)
                                        continue
                                    }
                                    var everywhere = true, wordStarting = true
                                    for part in parts {
                                        guard memmem(t + entry.start, entry.end - entry.start, n + part.start, part.count) != nil else {
                                            everywhere = false
                                            break
                                        }
                                        if wordStarting {
                                            var starts = false
                                            for word in entry.firstWord..<(entry.firstWord + entry.wordCount)
                                            where part.count <= wordEnds[word] - wordStarts[word]
                                                && memcmp(t + wordStarts[word], n + part.start, part.count) == 0 {
                                                starts = true
                                                break
                                            }
                                            wordStarting = starts
                                        }
                                    }
                                    if everywhere { groups[wordStarting ? 1 : 2].append(position) }
                                }
                            }
                        }
                    }
                }
            }
            return groups[0] + groups[1] + groups[2]
        }
    }

    // MARK: Presets

    /// A preset from an "eq" entry's data: its bands as filters, or the reason it can't be loaded.
    static func preset(id: String, _ data: [String: Any]) -> HeadphonePreset {
        let author = data["author"] as? String ?? ""
        let details = data["details"] as? String ?? ""
        let link = data["link"] as? String
        func unavailable(_ reason: String, preamp: Double = 0) -> HeadphonePreset {
            HeadphonePreset(id: id, author: author, details: details, link: link, preamp: preamp, filters: [], problem: reason)
        }
        let kind = data["type"] as? String ?? "parametric_eq"
        guard kind == "parametric_eq" else { return unavailable("it is a \(kind.replacingOccurrences(of: "_", with: " ")), not a parametric EQ") }
        guard let parameters = data["parameters"] as? [String: Any], let bands = parameters["bands"] as? [Any] else {
            return unavailable("it has no bands")
        }
        let preamp = number(parameters["gain_db"]) ?? 0
        var filters: [CalibrationFilter] = []
        for (index, band) in bands.enumerated() {
            switch filter(band) {
            case .success(let filter): filters.append(filter)
            case .failure(let problem): return unavailable("band \(index + 1) \(problem.reason)", preamp: preamp)
            }
        }
        return HeadphonePreset(id: id, author: author, details: details, link: link, preamp: preamp, filters: filters)
    }

    struct BandProblem: Error { let reason: String }

    /// One band: `peak_dip` (frequency, gain, Q), `low_shelf` and `high_shelf` (the same; Q 0.707 when missing) and
    /// `low_pass` (frequency, Q 0.707 or its own, 12 dB per octave).
    static func filter(_ band: Any) -> Result<CalibrationFilter, BandProblem> {
        guard let band = band as? [String: Any], let type = band["type"] as? String else {
            return .failure(BandProblem(reason: "can't be read"))
        }
        let kind: CalibrationFilter.Kind
        switch type {
        case "peak_dip": kind = .peaking
        case "low_shelf": kind = .lowShelf
        case "high_shelf": kind = .highShelf
        case "low_pass": kind = .lowPass
        default: return .failure(BandProblem(reason: "is a \(type.replacingOccurrences(of: "_", with: "-")) filter, which Junction doesn't have"))
        }
        guard let frequency = number(band["frequency"]), frequency > 0 else {
            return .failure(BandProblem(reason: "has no frequency"))
        }
        if kind == .lowPass {
            if let slope = number(band["slope"]), slope != 12 {
                return .failure(BandProblem(reason: "is a \(Int(slope)) dB/octave low-pass; Junction's have 12 dB/octave"))
            }
            let q = number(band["q"]) ?? 1 / 2.0.squareRoot()
            guard q > 0 else { return .failure(BandProblem(reason: "has no usable Q")) }
            return .success(CalibrationFilter(.lowPass, frequency: frequency, gain: 0, q: q))
        }
        guard let gain = number(band["gain_db"]) else { return .failure(BandProblem(reason: "has no gain")) }
        let q = number(band["q"]) ?? (kind == .peaking ? nil : 1 / 2.0.squareRoot())
        guard let q, q > 0 else { return .failure(BandProblem(reason: "has no usable Q")) }
        return .success(CalibrationFilter(kind, frequency: frequency, gain: gain, q: q))
    }

    /// A JSON number (not a Boolean, which JSONSerialization also hands over as an NSNumber).
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        return double.isFinite ? double : nil
    }
}

extension CalibrationProfile {
    /// A headphone profile from a library preset, named after the brand and model and carrying the preset's credits
    /// (one set of filters for every channel; the preamp is kept at or below 0 dB). Throws for an unavailable preset,
    /// with its reason: nothing of it is loaded.
    public static func headphones(_ model: HeadphoneModel, preset: HeadphonePreset,
                                  date: Date = Date()) throws -> CalibrationProfile {
        if let problem = preset.problem { throw HeadphoneLibraryError.unavailable(problem) }
        return CalibrationProfile(name: model.name, kind: .headphones, date: date,
                                  channels: [CalibrationChannel(filters: preset.filters)], preamp: min(0, preset.preamp),
                                  library: preset.credit)
    }
}
