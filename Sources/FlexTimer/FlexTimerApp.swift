import SwiftUI

@main
struct FlexTimerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate

    var body: some Scene {
        MenuBarExtra {
            Button("Quit") { NSApp.terminate(nil) }
        } label: {
            Text("⏳ --:--")
        }
    }
}
