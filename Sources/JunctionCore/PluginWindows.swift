import AppKit
import AudioToolbox
import AudioToolbox.AUCocoaUIView
import CoreAudioKit

// A plugin's own window, opened in the process that runs its unit: Junction Helper (a UI-element app, so it can show
// windows) or Junction when it routes by itself. The view comes from the unit: a view controller
// (kAudioUnitProperty_RequestViewController: version 3 units, and units macOS hosts out of process), a Cocoa view
// (kAudioUnitProperty_CocoaUI: version 2 units in this process), or Apple's generic parameter view. While the window
// is open, and when it closes, the unit's state is read back and handed on, so it is saved with the graph.

@MainActor
public final class PluginWindows: NSObject, NSWindowDelegate {
    public static let shared = PluginWindows()

    /// How often an open window's state is read back.
    static let stateInterval: TimeInterval = 2

    private final class Open {
        let window: NSWindow
        let unit: EffectUnit
        let onState: (Data) -> Void
        var lastState: Data?
        var timer: Timer?
        /// Kept until the unit has answered (it calls back later).
        var request: AnyObject?

        init(window: NSWindow, unit: EffectUnit, onState: @escaping (Data) -> Void) {
            self.window = window
            self.unit = unit
            self.onState = onState
            lastState = unit.state
        }
    }

    private var open: [UUID: Open] = [:]

    /// Effects whose windows are open.
    public var openEffects: Set<UUID> { Set(open.keys) }

    /// Opens (or brings forward) the window of `unit`, the running unit of `effect`. `onState` gets the unit's state
    /// whenever it changed.
    public func open(_ unit: EffectUnit, effect: UUID, title: String, onState: @escaping (Data) -> Void) {
        NSApp.activate()
        if let existing = open[effect], existing.unit === unit {
            existing.window.makeKeyAndOrderFront(nil)
            return
        }
        close(effect)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
                              styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.delegate = self
        let entry = Open(window: window, unit: unit, onState: onState)
        open[effect] = entry
        entry.timer = Timer.scheduledTimer(withTimeInterval: Self.stateInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.readState(effect) }
        }
        Self.requestView(unit, entry: entry) { [weak self] view in
            guard let self, self.open[effect] === entry else { return }
            self.show(view, in: window)
        }
    }

    /// Closes windows whose effect no longer runs, or now runs on another unit (a new format).
    public func keep(_ units: [UUID: EffectUnit]) {
        for (effect, entry) in open where units[effect] !== entry.unit { close(effect) }
    }

    public func close(_ effect: UUID) {
        guard let entry = open[effect] else { return }
        entry.window.close()  // windowWillClose reads the state one last time
    }

    public func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
              let effect = open.first(where: { $0.value.window === window })?.key else { return }
        readState(effect)
        open[effect]?.timer?.invalidate()
        open[effect] = nil
    }

    private func readState(_ effect: UUID) {
        guard let entry = open[effect], let state = entry.unit.state, state != entry.lastState else { return }
        entry.lastState = state
        entry.onState(state)
    }

    private func show(_ view: NSView, in window: NSWindow) {
        let size = view.frame.size.width > 10 && view.frame.size.height > 10 ? view.frame.size : NSSize(width: 420, height: 260)
        let container = NSView(frame: NSRect(origin: .zero, size: size))
        view.frame = container.bounds
        view.autoresizingMask = [.width, .height]
        container.addSubview(view)
        window.contentView = container
        window.setContentSize(size)
        window.center()
        window.makeKeyAndOrderFront(nil)
    }

    // MARK: Views

    private typealias ViewControllerBlock = @convention(block) (AnyObject?) -> Void

    /// The unit's own view if it has one, else Apple's generic view of its parameters. `done` is called on the main
    /// thread.
    private static func requestView(_ effectUnit: EffectUnit, entry: Open, done: @escaping (NSView) -> Void) {
        let unit = effectUnit.unit
        var size: UInt32 = 0
        var writable: DarwinBoolean = false
        if AudioUnitGetPropertyInfo(unit, kAudioUnitProperty_RequestViewController, kAudioUnitScope_Global, 0, &size,
                                    &writable) == noErr, writable.boolValue {
            let block: ViewControllerBlock = { controller in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        entry.request = nil
                        if let controller = controller as? NSViewController {
                            controller.view.frame.size = controller.preferredContentSize.width > 10
                                ? controller.preferredContentSize : controller.view.frame.size
                            done(controller.view)
                        } else {
                            done(cocoaView(unit) ?? genericView(unit))
                        }
                    }
                }
            }
            entry.request = block as AnyObject
            var pointer = unsafeBitCast(block, to: UnsafeRawPointer.self)
            if AudioUnitSetProperty(unit, kAudioUnitProperty_RequestViewController, kAudioUnitScope_Global, 0, &pointer,
                                    UInt32(MemoryLayout<UnsafeRawPointer>.size)) == noErr {
                return
            }
            entry.request = nil
        }
        done(cocoaView(unit) ?? genericView(unit))
    }

    /// A version 2 unit's Cocoa view, made by the factory class in the bundle it names.
    private static func cocoaView(_ unit: AudioUnit) -> NSView? {
        var size: UInt32 = 0
        var writable: DarwinBoolean = false
        guard AudioUnitGetPropertyInfo(unit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, &size, &writable) == noErr,
              size >= UInt32(MemoryLayout<AudioUnitCocoaViewInfo>.size) else { return nil }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioUnitCocoaViewInfo>.alignment)
        defer { raw.deallocate() }
        guard AudioUnitGetProperty(unit, kAudioUnitProperty_CocoaUI, kAudioUnitScope_Global, 0, raw, &size) == noErr else { return nil }
        let info = raw.load(as: AudioUnitCocoaViewInfo.self)
        let location = info.mCocoaAUViewBundleLocation.takeRetainedValue() as URL
        let className = info.mCocoaAUViewClass.takeRetainedValue() as String
        guard let bundle = Bundle(url: location), bundle.load(),
              let factoryClass = bundle.classNamed(className) as? NSObject.Type,
              let factory = factoryClass.init() as? AUCocoaUIBase
        else { return nil }
        return factory.uiView(forAudioUnit: unit, with: NSSize(width: 420, height: 260))
    }

    /// Apple's generic view: a slider per parameter.
    private static func genericView(_ unit: AudioUnit) -> NSView {
        let view = AUGenericView(audioUnit: unit)
        view.showsExpertParameters = true
        return view
    }
}
