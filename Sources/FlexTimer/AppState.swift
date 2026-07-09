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

    var rules: WorkRules { SettingsStore.rules }

    private let client = FlexClient()
    private let login = LoginWindowController()
    private var tickTimer: Timer?
    private var refreshTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    var today: WorkRecord? {
        todayRecord(now: Date())
    }

    /// Flex record for the day if present, else a synthetic record from manual entry.
    func todayRecord(now: Date) -> WorkRecord? {
        if let flex = week.first(where: { Calendar.current.isDate($0.clockIn, inSameDayAs: now) }) {
            return flex
        }
        if let manual = SettingsStore.manualStart(on: now) {
            return WorkRecord(clockIn: manual, clockOut: nil, flexWorkedNet: nil)
        }
        return nil
    }

    /// Week records including the synthetic manual record for today, if any.
    func weekIncludingManual(now: Date) -> [WorkRecord] {
        var records = week
        if !records.contains(where: { Calendar.current.isDate($0.clockIn, inSameDayAs: now) }),
           let manual = todayRecord(now: now) {
            records.append(manual)
        }
        return records
    }

    /// Kick off timers and the first fetch. Call once from the App.
    func start() {
        guard tickTimer == nil else { return }
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.recompute(now: Date()) }
        }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        Task { await refresh() }
    }

    func recompute(now: Date) {
        let record = todayRecord(now: now)
        let state = DisplayState.compute(hasSession: hasSession, today: record,
                                         week: weekIncludingManual(now: now), now: now, rules: rules)
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
