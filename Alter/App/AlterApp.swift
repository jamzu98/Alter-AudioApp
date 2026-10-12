import SwiftUI

@main
struct AlterApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(model)
        } label: {
            Image(systemName: "slider.vertical.3")
                .symbolRenderingMode(.hierarchical)
                .opacity(model.settings.globalBypass ? 0.5 : 1)
        }
        .menuBarExtraStyle(.window)

        Window("Alter Effects", id: WindowID.effects) {
            EffectsWindow()
                .environment(model)
                .frame(minWidth: 860, minHeight: 620)
        }
        .defaultSize(width: 980, height: 760)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

enum WindowID {
    static let effects = "effects"
}

extension View {
    /// Menu bar apps have no Dock icon, so windows must activate the app explicitly.
    func activatingApp() -> some View {
        onAppear { NSApp.activate() }
    }
}
