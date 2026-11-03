import SwiftUI

struct EasyDockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @AppStorage("languagePreference") private var languageRaw = AppLocale.systemDefault.rawValue
    private let windowDelegate = HideInsteadOfCloseDelegate()

    private var appLocale: AppLocale {
        AppLocale(rawValue: languageRaw) ?? .systemDefault
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .background(WindowAccessor(delegate: windowDelegate))
                .environment(\.locale, appLocale.locale)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") { AppUpdater.checkForUpdates() }
            }
            // Settings is a sidebar tab of the main window, not a separate
            // scene. Deferred a run-loop turn: changing the sidebar selection
            // while AppKit's menu is still tracking left SignalBar's sidebar
            // unresponsive.
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    DispatchQueue.main.async { WindowPresenter.showSettings() }
                }
                .keyboardShortcut(",", modifiers: .command)
            }
            // One main window: no File › New Window.
            CommandGroup(replacing: .newItem) {}
        }
    }
}
