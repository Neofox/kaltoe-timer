import AppKit
import Combine
import Foundation

@MainActor
final class AppState: ObservableObject {
    @Published var menuText = "--:--"
    @Published var menuDisplay = MenuDisplay(state: .notClockedIn, urgency: .normal)
    @Published var week: [WorkRecord] = []
    @Published var dayOffDates: Set<Date> = []
    @Published var lastSync: Date?
    @Published var syncError: String?
    @Published var hasSession: Bool = CookieVault.load()?.isEmpty == false {
        didSet { sessionNotifier?.sessionBecame(hasSession) }
    }

    var rules: WorkRules { SettingsStore.rules }

    private let client = FlexClient()
    private let login = LoginWindowController()
    /// Attached in start() only, so unit tests calling recompute never launch scripts.
    var hookRunner: HookRunner?
    /// Attached in start() only, so unit tests never touch UNUserNotificationCenter.
    var sessionNotifier: SessionNotifier?
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
        let weekStart = WorkCalculator.weekStart(of: now)
        var records = week.filter { $0.clockIn >= weekStart }
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
        hookRunner = HookRunner()
        sessionNotifier = SessionNotifier.live { [weak self] in
            Task { @MainActor in self?.signIn() }
        }
        // Establish baseline. Launching with present-but-expired cookies means
        // hasSession starts true here, so the first refresh's true→false transition
        // intentionally notifies; a no-cookie launch starts false and never does.
        sessionNotifier?.sessionBecame(hasSession)
        Task { await refresh() }
    }

    func recompute(now: Date) {
        let record = todayRecord(now: now)
        hookRunner?.evaluate(today: record, now: now)
        let display = DisplayState.computeDisplay(hasSession: hasSession, today: record,
                                                  week: weekIncludingManual(now: now),
                                                  dayOffs: dayOffDates,
                                                  now: now, rules: rules)
        menuDisplay = display
        menuText = display.state.menuBarText
    }

    func refresh() async {
        do {
            let now = Date()
            let weekStart = WorkCalculator.weekStart(of: now)
            let weekEnd = Calendar.current.date(byAdding: .day, value: 6, to: weekStart) ?? now
            let result = try await client.fetchWeek(from: weekStart, to: max(now, weekEnd))
            week = result.records
            dayOffDates = result.dayOffDates
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
