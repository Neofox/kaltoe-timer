import SwiftUI
import KaltoeCore

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
            MenuBarLabel(display: state.menuDisplay, text: state.menuText,
                         progress: state.labelProgress, geometry: state.labelGeometry)
        }
        .menuBarExtraStyle(.window)
    }
}
