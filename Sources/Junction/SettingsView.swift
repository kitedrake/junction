import AppKit
import JunctionCore
import ServiceManagement
import SwiftUI

/// Whether Junction shows a Dock icon. Without one it lives in the menu bar (routing never needs the window).
enum DockIcon {
    static let key = "showsDockIcon"

    static var isShown: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

    @MainActor static func apply(_ shown: Bool) {
        NSApp.setActivationPolicy(shown ? .regular : .accessory)
        // Switching policy can send the app behind other apps; keep the window that was just used in front.
        DispatchQueue.main.async { NSApp.activate() }
    }
}

/// Junction › Settings…: where routing runs, start at login, the Dock icon, driver installs, crash reports and
/// uninstalling.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(DockIcon.key) private var showsDockIcon = true
    @State private var loginStatus = SMAppService.Status.notRegistered
    @State private var loginError: String?

    var body: some View {
        @Bindable var model = model
        Form {
            RoutingSection(keepRouting: $model.keepRoutingAfterQuit)
            Section {
                Toggle("Open at login", isOn: Binding(
                    get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                    set: { setOpensAtLogin($0) }))
                if loginStatus == .requiresApproval {
                    HStack {
                        Text("macOS needs your approval in System Settings › General › Login Items.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let loginError {
                    Text(loginError).font(.callout).foregroundStyle(.red)
                }
            } footer: {
                Text("Routing starts as soon as Junction opens, with the setup you left it in. Opened at login, Junction starts in the menu bar without its window.")
            }
            Section {
                Toggle("Show in Dock", isOn: $showsDockIcon)
            } footer: {
                Text("Junction keeps routing from the menu bar when its window is closed. Without the Dock icon, open the window and these settings from the menu bar icon.")
            }
            DriverInstallerSection()
            Section {
                Toggle("Offer to send crash reports", isOn: $model.offersCrashReports)
            } footer: {
                Text(CrashReporting.destination != nil || model.isDemo
                     ? "After Junction or Junction Helper crashes, Junction offers a report the next time it opens: its diagnostic report (versions, your audio devices and apps, your setup, recent routing events) and the crash log macOS wrote. You read all of it first; nothing is sent unless you click Send Report."
                     : "After Junction or Junction Helper crashes, Junction offers a report the next time it opens: its diagnostic report (versions, your audio devices and apps, your setup, recent routing events) and the crash log macOS wrote. This build has no address to send it to: copy it into a bug report yourself.")
            }
            UninstallSection()
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onAppear { loginStatus = model.isDemo ? .notRegistered : SMAppService.mainApp.status }
        .onChange(of: showsDockIcon) { _, shown in if !model.isDemo { DockIcon.apply(shown) } }
    }

    private func setOpensAtLogin(_ on: Bool) {
        guard !model.isDemo else { return }  // screenshots never register a login item
        loginError = nil
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = "Couldn't change it: \(error.localizedDescription)"
        }
        loginStatus = SMAppService.mainApp.status
    }
}

/// Where routing runs: in Junction Helper, in the background (builds made for it), or inside Junction.
private struct RoutingSection: View {
    @Environment(AppModel.self) private var model
    @Binding var keepRouting: Bool

    var body: some View {
        // Snapshot mode shows what a build with the helper shows.
        let background = model.placement.usesHelper || model.isDemo
        Section {
            LabeledContent {
                Text(background ? "Junction Helper" : "Junction").foregroundStyle(.secondary)
            } label: {
                Label(background ? "Routing runs in the background" : "Routing runs inside Junction",
                      systemImage: background ? "arrow.triangle.branch" : "app")
            }
            Toggle("Keep routing after quitting Junction", isOn: $keepRouting)
                .disabled(!background)
            if model.helperRegistration == .requiresApproval {
                HStack {
                    Text("Junction Helper is turned off in Login Items.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
        } footer: {
            Text(footer(background: background))
        }
    }

    private func footer(background: Bool) -> String {
        if background {
            return "Junction Helper opens your devices and captures app audio, so macOS asks for permissions in its name. With this switch on, routing goes on after you quit Junction and starts again when you log in. To turn the helper off, switch Junction off in System Settings › General › Login Items & Extensions: Junction then routes by itself."
        }
        if case .inProcess(let reason) = model.placement {
            return "\(reason) Routing stops when Junction quits."
        }
        return "Routing stops when Junction quits."
    }
}

/// Whether Install Driver… needs a password: Junction Driver Installer installs without one once the user approves it.
private struct DriverInstallerSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let approval = model.driverInstaller
        Section {
            LabeledContent {
                Text(status(approval)).foregroundStyle(.secondary)
            } label: {
                Label("Driver installs", systemImage: approval == .approved ? "lock.open" : "lock")
            }
            if approval == .requiresApproval {
                HStack {
                    Text("Allow Junction in Login Items to install the driver without a password.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Open Login Items") { if !model.isDemo { SMAppService.openSystemSettingsLoginItems() } }
                }
            }
        } footer: {
            Text(approval == nil
                 ? "This build installs, updates and removes the driver with an administrator password."
                 : "\(DriverDaemon.displayName) installs, updates and removes the driver without your password once you allow Junction under System Settings › General › Login Items & Extensions. It only installs the driver inside this copy of Junction, and only when its signature matches Junction's. Until then, Install Driver… asks for an administrator password.")
        }
    }

    private func status(_ approval: DaemonApproval?) -> String {
        switch approval {
        case .approved?: "Without a password"
        case .requiresApproval?: "Waiting for your approval"
        case nil, .notRegistered?, .notFound?, .failed?: "With your password"
        }
    }
}

/// Uninstall Junction…: the driver, both helpers and the login item, and on request the saved setup and settings.
private struct UninstallSection: View {
    @Environment(AppModel.self) private var model
    @State private var confirming = false

    var body: some View {
        Section {
            HStack {
                Text("Remove Junction from this Mac")
                Spacer()
                Button(model.isUninstalling ? "Uninstalling…" : "Uninstall Junction…", role: .destructive) { confirming = true }
                    .disabled(model.isUninstalling || model.isInstallingDriver)
            }
        } footer: {
            Text("Removes the audio driver (your virtual devices disappear from every app), Junction Helper, the driver installer and the login item, then quits. Then move Junction to the Bin.")
        }
        .confirmationDialog("Uninstall Junction?", isPresented: $confirming) {
            Button("Uninstall and Keep My Setup", role: .destructive) { model.uninstallJunction(removeSettings: false) }
            Button("Uninstall and Remove My Setup", role: .destructive) { model.uninstallJunction(removeSettings: true) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removing the driver restarts macOS's audio system, so all sound stops for a moment, and may ask for your password. Keeping your setup leaves your devices, canvases and scenes for a later install; removing it also deletes Junction's settings.")
        }
    }
}
