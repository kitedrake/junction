import Foundation
import Observation

// The Choose Headphones sheet, without the window: the headphone library as the app holds it (loaded once, updated on
// request, shared by the sheet and Settings), and the sheet itself: search, a style filter, the chosen headphones'
// presets compared as curves, and Use, which loads one into the output's Calibration effect as one undo step. Opened
// again on an effect with a library preset, the sheet starts on that preset.

/// The headphone library the app uses: the downloaded copy when there is a valid one, else the bundled one; and
/// updating it when the user asks.
@MainActor @Observable
public final class HeadphoneLibraryStore {
    public enum UpdateState: Equatable, Sendable {
        case idle
        /// Downloading and checking the database (cancellable).
        case updating
        /// The download was checked and is in use now.
        case updated
        /// Why it failed (or that it was cancelled); the current library is kept.
        case failed(String)
    }

    public private(set) var library: HeadphoneLibrary?
    /// Why the library couldn't be read (nil while it loads, and once it has).
    public private(set) var loadProblem: String?
    public private(set) var isLoading = false
    public private(set) var updateState = UpdateState.idle

    @ObservationIgnored private let loader: @Sendable () async throws -> HeadphoneLibrary
    @ObservationIgnored private let updater: @Sendable () async throws -> HeadphoneLibrary
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var updateTask: Task<Void, Never>?

    /// `loader` reads the library to use; `updater` downloads, checks and caches a new one, and returns it.
    public init(loader: @escaping @Sendable () async throws -> HeadphoneLibrary,
                updater: @escaping @Sendable () async throws -> HeadphoneLibrary) {
        self.loader = loader
        self.updater = updater
    }

    /// Junction's library: the cached copy in `cache`, else the bundled one, updated from the mirror through
    /// `transport`.
    public convenience init(cache: HeadphoneLibraryCache = HeadphoneLibraryCache(),
                            bundledURL: URL? = HeadphoneLibrary.bundledDatabaseURL,
                            transport: HeadphoneLibraryTransport = HeadphoneLibraryDownloader(),
                            requirements: HeadphoneLibraryCache.Requirements = .standard) {
        self.init(loader: { try await HeadphoneLibrary.loadPreferred(cache: cache, bundledURL: bundledURL,
                                                                     requirements: requirements) },
                  updater: { try await cache.update(transport: transport, requirements: requirements) })
    }

    /// A library that is already read (snapshot mode); updating it fails with `updateProblem`.
    public convenience init(library: HeadphoneLibrary, updateProblem: String) {
        self.init(loader: { library }, updater: { throw HeadphoneLibraryUpdateError.network(updateProblem) })
        self.library = library
    }

    /// Reads the library the first time it is needed (off the main thread); later calls wait for that read.
    public func load() async {
        if library != nil { return }
        if let loadTask { return await loadTask.value }
        isLoading = true
        loadProblem = nil
        let task = Task { [loader] in
            do {
                let library = try await loader()
                if self.library == nil { self.library = library }
            } catch {
                self.loadProblem = error.localizedDescription
            }
            self.isLoading = false
            self.loadTask = nil
        }
        loadTask = task
        await task.value
    }

    public var isUpdating: Bool { updateState == .updating }

    /// Update Library: downloads the database, checks it and uses it. A failure or Cancel keeps the current library.
    public func update() {
        guard !isUpdating else { return }
        updateState = .updating
        updateTask = Task { [updater] in
            do {
                let library = try await updater()
                self.library = library
                self.loadProblem = nil
                self.updateState = .updated
            } catch {
                self.updateState = .failed(error.localizedDescription)
            }
            self.updateTask = nil
        }
    }

    /// Waits for the update under way, if any (for tests and snapshot mode).
    public func waitForUpdate() async { await updateTask?.value }

    public func cancelUpdate() { updateTask?.cancel() }

    /// "Bundled with Junction · 26 Nov 2026" or "Downloaded 3 Dec 2026", then the counts: what Settings and the sheet
    /// show.
    public var status: String {
        guard let summary = library?.summary else {
            return loadProblem ?? "Reading the headphone library…"
        }
        return Self.status(summary)
    }

    public static func status(_ summary: HeadphoneLibrary.Summary) -> String {
        let date = summary.date.map { $0.formatted(date: .abbreviated, time: .omitted) }
        let source = switch summary.source {
        case .bundled: date.map { "Bundled with Junction, from \($0)" } ?? "Bundled with Junction"
        case .downloaded: date.map { "Downloaded \($0)" } ?? "Downloaded"
        }
        func count(_ number: Int, _ one: String, _ many: String) -> String {
            "\(number.formatted()) \(number == 1 ? one : many)"
        }
        return "\(source) · \(count(summary.products, "headphone model", "headphone models")) · "
            + count(summary.presets, "preset", "presets")
    }
}

/// Where the sheet loads a preset: the app (or a test).
@MainActor
public protocol HeadphonePickerHost: AnyObject {
    /// Puts `profile` into the node's Calibration effect `effect` (nil: its first one, added when it has none) as one
    /// undo step.
    func use(_ profile: CalibrationProfile, node: UUID, effect: UUID?)
}

@MainActor @Observable
public final class HeadphonePicker: Identifiable {
    public let id = UUID()
    /// The output and its Calibration effect (nil: it has none yet; Use adds one).
    public let node: UUID
    public let effect: UUID?
    /// The device the output plays on now: a loaded profile is made for it.
    public let deviceUID: String?
    public let deviceName: String?
    /// The library preset the effect has now, if any.
    public let presetInUse: String?
    public let store: HeadphoneLibraryStore
    @ObservationIgnored private weak var host: HeadphonePickerHost?

    /// The search field.
    public var query = ""
    /// The style filter (nil: every style).
    public var style: HeadphoneStyle?
    /// The headphones whose presets are shown, by id.
    public var chosenID: String? {
        didSet {
            guard chosenID != oldValue else { return }
            problem = nil
            let presets = chosen?.presets ?? []
            selectedPresetID = presets.first { $0.id == presetInUse }?.id ?? presets.first { $0.isAvailable }?.id
            compared = selectedPresetID.map { [$0] } ?? []
        }
    }
    /// The preset Use loads.
    public var selectedPresetID: String? {
        didSet {
            if let selectedPresetID { compared.insert(selectedPresetID) }
            problem = nil
        }
    }
    /// The presets drawn on the graph (the selected one always is).
    public private(set) var compared: Set<String> = []
    /// Why Use didn't load the preset.
    public private(set) var problem: String?

    public init(node: UUID, effect: UUID?, deviceUID: String? = nil, deviceName: String? = nil,
                presetInUse: String? = nil, store: HeadphoneLibraryStore, host: HeadphonePickerHost) {
        self.node = node
        self.effect = effect
        self.deviceUID = deviceUID
        self.deviceName = deviceName
        self.presetInUse = presetInUse
        self.store = store
        self.host = host
        showPresetInUse()
    }

    /// Reads the library if it isn't yet, then shows the preset in use.
    public func load() async {
        await store.load()
        showPresetInUse()
    }

    /// Chooses the headphones of the preset in use (once the library is read), with that preset selected.
    private func showPresetInUse() {
        guard chosenID == nil, let presetInUse, let library = store.library,
              let model = library.models.first(where: { $0.presets.contains { $0.id == presetInUse } }) else { return }
        chosenID = model.id
    }

    // MARK: Browsing

    /// The headphones matching the search and the style filter.
    public var results: HeadphoneSearchResults {
        store.library?.search(query, style: style) ?? .empty
    }

    /// The styles to filter by, the most common first.
    public var styles: [HeadphoneStyle] { store.library?.styles ?? [] }

    public var chosen: HeadphoneModel? { chosenID.flatMap { store.library?.model(id: $0) } }

    public var selectedPreset: HeadphonePreset? {
        chosen?.presets.first { $0.id == selectedPresetID }
    }

    /// Shows or hides a preset's curve on the graph (the selected preset stays shown).
    public func setCompared(_ preset: String, _ shown: Bool) {
        if shown {
            compared.insert(preset)
        } else if preset != selectedPresetID {
            compared.remove(preset)
        }
    }

    /// The compared presets in the headphones' order: the ones that can be loaded, so the graph has a curve for each.
    public var comparedPresets: [HeadphonePreset] {
        (chosen?.presets ?? []).filter { compared.contains($0.id) && $0.isAvailable }
    }

    /// A preset's correction as it would run (filters and preamp, at full amount) on `CalibrationGrid`, in dB; nil
    /// for one that can't be loaded.
    public func curve(_ preset: HeadphonePreset) -> [Double]? {
        guard let model = chosen, let profile = try? CalibrationProfile.headphones(model, preset: preset) else { return nil }
        return profile.curve(channel: 0, sampleRate: 48_000)
    }

    // MARK: Use

    public var canUse: Bool { selectedPreset?.isAvailable ?? false }

    /// Loads the selected preset into the output's Calibration effect (one undo step). Returns whether it did.
    @discardableResult
    public func use(date: Date = Date()) -> Bool {
        guard let model = chosen, let preset = selectedPreset else { return false }
        do {
            var profile = try CalibrationProfile.headphones(model, preset: preset, date: date)
            profile.deviceUID = deviceUID
            profile.deviceName = deviceName
            host?.use(profile, node: node, effect: effect)
            return true
        } catch {
            problem = error.localizedDescription
            return false
        }
    }
}

extension HeadphoneLibrary {
    /// The database's project, credited where the library is browsed.
    public static let projectName = "OPRA"
    public static let projectURL = URL(string: "https://github.com/opra-project/OPRA")!
    public static let projectDescription = "An open database of headphone EQ presets, shared under CC BY-SA 4.0."
    /// The project's logo, for the credit (in the bundled folder).
    public static var logoURL: URL? { bundledFolder?.appendingPathComponent("opra_logo.png") }
}

extension HeadphoneSearchResults {
    /// No models (the library isn't read yet).
    public static let empty = HeadphoneSearchResults(models: [], positions: [])
}

/// A licence that comes with the headphone library, as Settings › Acknowledgements shows it.
public struct HeadphoneLibraryLicence: Hashable, Identifiable, Sendable {
    public var title: String
    public var summary: String
    public var text: String
    public var id: String { title }

    /// The licence texts in the library's folder: the database's (its data under CC BY-SA 4.0, its code under MIT)
    /// and AutoEQ's (MIT). Files that are missing are left out.
    public static func bundled(in folder: URL? = HeadphoneLibrary.bundledFolder) -> [HeadphoneLibraryLicence] {
        guard let folder else { return [] }
        let files = [("OPRA", "Headphone data: CC BY-SA 4.0. Code: MIT.", "LICENSE.md"),
                     ("AutoEQ", "Presets measured and fitted by AutoEQ: MIT.", "THIRD_PARTY_LICENSES.md")]
        return files.compactMap { title, summary, file in
            guard let text = try? String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8) else { return nil }
            return HeadphoneLibraryLicence(title: title, summary: summary, text: text)
        }
    }
}
