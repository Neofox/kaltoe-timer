import SwiftUI

@main
struct FlexTimerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state: AppState

    init() {
        let s = AppState()
        _state = StateObject(wrappedValue: s)
        Task { @MainActor in s.start() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView().environmentObject(state)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "timer")
                Text(state.menuText)
            }
        }
        .menuBarExtraStyle(.window)
    }
}
