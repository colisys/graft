import SwiftUI
import GraftCore

@main
struct GraftApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(model)
                .environmentObject(model.environment)
                .environmentObject(model.log)
        } label: {
            Image(systemName: "square.stack.3d.up.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
