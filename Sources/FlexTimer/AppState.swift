import AppKit
import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var menuText = "⏳ --:--"
    @Published var week: [WorkRecord] = []
    @Published var lastSync: Date?
    @Published var syncError: String?
    @Published var hasSession: Bool = CookieVault.load()?.isEmpty == false

    var rules: WorkRules { WorkRules() } // Task 9 replaces this with SettingsStore.rules

    private let client = FlexClient()
    private let login = LoginWindowController()
    private var tickTimer: Timer?
    private var refreshTimer: Timer?

    var today: WorkRecord? {
        week.first { Calendar.current.isDate($0.clockIn, inSameDayAs: Date()) }
    }

    /// Kick off timers and the first fetch. Call once from the App.
    func start() {
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recompute(now: Date()) }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    func recompute(now: Date) {
        let todayRecord = week.first { Calendar.current.isDate($0.clockIn, inSameDayAs: now) }
        let state = DisplayState.compute(hasSession: hasSession, today: todayRecord,
                                         week: week, now: now, rules: rules)
        menuText = state.menuBarText
    }

    func refresh() async {
        do {
            let now = Date()
            week = try await client.fetchWeek(from: WorkCalculator.weekStart(of: now), to: now)
            lastSync = now
            syncError = nil
            hasSession = true
        } catch let e as FlexClient.FlexError where e == .noSession || e == .sessionExpired {
            hasSession = false
        } catch {
            syncError = "Flex sync failed — showing last known data"
        }
        recompute(now: Date())
    }

    func signIn() {
        login.show { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
    }
}
