import AppKit
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

/// Junction › Settings…: start at login and the Dock icon.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(DockIcon.key) private var showsDockIcon = true
    @State private var loginStatus = SMAppService.Status.notRegistered
    @State private var loginError: String?

    var body: some View {
        Form {
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
                Text("Routing starts as soon as Junction opens, with the setup you left it in.")
            }
            Section {
                Toggle("Show in Dock", isOn: $showsDockIcon)
            } footer: {
                Text("Junction keeps routing from the menu bar when its window is closed. Without the Dock icon, open the window and these settings from the menu bar icon.")
            }
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
