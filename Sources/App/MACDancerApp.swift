import AppKit
import SwiftUI

@main
struct MACDancerApp: App {
  @StateObject private var model = AppModel(
    client: DaemonClient(),
    service: ServiceController(),
    reader: BackgroundInterfaceReader(reader: SystemInterfaceReader()),
    remover: SystemAppRemover()
  )
  @StateObject private var updates = UpdateController()
  @AppStorage(menuBarIconPreferenceKey) private var showMenuBarIcon = true

  var body: some Scene {
    // A single window: reopening it from the Dock or the menu bar brings the
    // same window back instead of stacking copies.
    Window(L("app.title", "MACDancer"), id: mainWindowID) {
      MainWindowView()
        .environmentObject(model)
        .environmentObject(updates)
        .task {
          model.start()
          updates.checkOnLaunchIfDue()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
          model.recheckService()
          model.refresh()
        }
    }
    .windowStyle(.hiddenTitleBar)
    .windowResizability(.contentMinSize)
    .defaultSize(width: 780, height: 680)
    .commands { AppCommands(model: model, updates: updates) }

    Settings {
      SettingsView()
        .environmentObject(model)
        .environmentObject(updates)
        .task { model.start() }
    }

    MenuBarExtra(L("menu_bar.title", "MACDancer"), systemImage: "shuffle.circle.fill", isInserted: $showMenuBarIcon) {
      MenuBarPanel()
        .environmentObject(model)
    }
    .menuBarExtraStyle(.window)
  }
}

private struct AppCommands: Commands {
  @ObservedObject var model: AppModel
  @ObservedObject var updates: UpdateController
  @Environment(\.openWindow) private var openWindow

  var body: some Commands {
    CommandGroup(replacing: .newItem) {}

    CommandGroup(after: .appInfo) {
      Button(L("command.check_updates", "Check for Updates…")) {
        openWindow(id: mainWindowID)
        updates.check(userInitiated: true)
      }
      .disabled(updates.isBusy)
    }

    CommandGroup(after: .toolbar) {
      Button(L("command.refresh", "Refresh MAC addresses")) { model.refresh() }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(model.isRefreshing)
    }
  }
}
