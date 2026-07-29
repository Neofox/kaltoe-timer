import AppKit
import Combine
import Foundation
import KaltoeCore

@MainActor
final class AppState: ObservableObject {
    @Published var menuText = "--:--"
    @Published var menuDisplay = MenuDisplay(state: .notClockedIn, urgency: .normal)
    @Published var week: [WorkRecord] = []
    @Published var dayOffDates: Set<Date> = []
    @Published var timeOff: [Date: TimeInterval] = [:]
    @Published var lastSync: Date?
    @Published var syncError: String?
    @Published var hasSession: Bool = CookieVault.load()?.isEmpty == false {
        didSet { sessionNotifier?.sessionBecame(hasSession) }
    }
    /// Mirrors the stored setting. Written through on set so the popover toggle
    /// persists, and published so the menu bar label re-renders immediately —
    /// an external `defaults write` would not be picked up by the running app.
    @Published var highContrastOnInactiveDisplays = SettingsStore.highContrastOnInactiveDisplays {
        didSet { SettingsStore.highContrastOnInactiveDisplays = highContrastOnInactiveDisplays }
    }

    var rules: WorkRules { SettingsStore.rules }
    var weekData: WeekData { WeekData(records: week, dayOffDates: dayOffDates, timeOff: timeOff) }

    private let client = FlexClient()
    private let login = LoginWindowController()
    /// Attached in start() only, so unit tests calling recompute never launch scripts.
    var hookRunner: HookRunner?
    /// Attached in start() only, so unit tests never touch UNUserNotificationCenter.
    var sessionNotifier: SessionNotifier?
    /// Attached in start() only, so unit tests calling recompute never notify.
    var limitNotifier: LimitNotifier?
    private var tickTimer: Timer?
    private var refreshTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    /// Stored to mirror `wakeObserver` and, like it, never removed: AppState
    /// lives for the process lifetime, so there is no deinit for removal to
    /// run in.
    private var unlockObserver: NSObjectProtocol?
    /// The in-flight unlock re-sync, held so the next unlock can cancel it.
    private var unlockResync: Task<Void, Never>?

    var today: WorkRecord? {
        todayRecord(now: Date())
    }

    /// Flex record for the day if present, else a synthetic record from manual entry.
    func todayRecord(now: Date) -> WorkRecord? {
        weekData.todayRecord(now: now)
    }

    /// Week records including the synthetic manual record for today, if any.
    func weekIncludingManual(now: Date) -> [WorkRecord] {
        weekData.weekIncludingManual(now: now)
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
        // didWakeNotification only fires when the Mac wakes from sleep. A Mac
        // that was merely locked never posts it, which is the case that had the
        // user clicking refresh every morning.
        unlockObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("com.apple.screenIsUnlocked"),
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleUnlockResync() }
        }
        hookRunner = HookRunner()
        limitNotifier = LimitNotifier.live()
        sessionNotifier = SessionNotifier.live { [weak self] in
            Task { @MainActor in self?.signIn() }
        }
        // Establish baseline. Launching with present-but-expired cookies means
        // hasSession starts true here, so the first refresh's true→false transition
        // intentionally notifies; a no-cookie launch starts false and never does.
        sessionNotifier?.sessionBecame(hasSession)
        Task { await refresh() }
    }

    /// Whether an unlock re-sync should try again. `attempt` is 0-based and
    /// names the attempt that just finished. `hasTodayRecord` means *any* record
    /// for today, including a synthetic one from a manual start — `AppState.today`
    /// makes no distinction — so a manual entry ends the retries exactly as a Flex
    /// record does. Stops as soon as a record is present, stops immediately when
    /// signed out — retrying a dead session only hammers it — and stops at the
    /// ceiling. Pure in its four parameters, so it needs no actor.
    nonisolated static func shouldRetryUnlockResync(attempt: Int, maxAttempts: Int,
                                                    hasSession: Bool, hasTodayRecord: Bool) -> Bool {
        guard hasSession, !hasTodayRecord else { return false }
        return attempt + 1 < maxAttempts
    }

    func recompute(now: Date) {
        let record = todayRecord(now: now)
        hookRunner?.evaluate(today: record, now: now)
        // Derived once and shared. This runs every second, and the display and
        // the notifier need the same figure — computing it twice was thousands
        // of redundant passes an hour.
        let weekly = WorkCalculator.weeklyOvertime(records: weekIncludingManual(now: now),
                                                   timeOff: timeOff, now: now, rules: rules)
        let display = DisplayState.computeDisplay(hasSession: hasSession, today: record,
                                                  weeklyOvertime: weekly,
                                                  timeOff: timeOff,
                                                  now: now, rules: rules)
        menuDisplay = display
        menuText = display.state.menuBarText
        limitNotifier?.evaluate(weeklyOvertime: weekly,
                                clockedIn: record?.clockOut == nil && record != nil,
                                now: now, rules: rules)
    }

    func refresh() async {
        do {
            let now = Date()
            let weekStart = WorkCalculator.weekStart(of: now)
            let weekEnd = Calendar.current.date(byAdding: .day, value: 6, to: weekStart) ?? now
            let result = try await client.fetchWeek(from: weekStart, to: max(now, weekEnd))
            week = result.records
            dayOffDates = result.dayOffDates
            timeOff = result.timeOff
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

    /// Start an unlock re-sync, cancelling any still-running one first.
    ///
    /// Cancel-and-replace, because nothing else guards re-entry: waking a locked
    /// Mac fires `didWakeNotification` *and* `com.apple.screenIsUnlocked` moments
    /// apart, and a network fetch outlives that gap, so two `fetchWeek` calls
    /// would sit in flight writing the same `week`/`timeOff`/`hasSession`/`lastSync`.
    /// MainActor keeps that memory-safe but not ordered — an older response
    /// landing second would win — and repeated lock/unlock cycles stacked loops.
    func scheduleUnlockResync() {
        unlockResync?.cancel()
        unlockResync = Task { [weak self] in await self?.resyncAfterUnlock() }
    }

    /// Re-sync after the screen unlocks, retrying briefly while today has no
    /// record at all: the user typically clocks in moments before unlocking, and
    /// the API lags that by seconds.
    func resyncAfterUnlock(maxAttempts: Int = 3, delay: TimeInterval = 20) async {
        for attempt in 0..<maxAttempts {
            await refresh()
            guard Self.shouldRetryUnlockResync(attempt: attempt, maxAttempts: maxAttempts,
                                               hasSession: hasSession,
                                               hasTodayRecord: today != nil) else { return }
            // Not `try?`: that swallows CancellationError, and a cancelled loop
            // would then run its remaining attempts back-to-back with no delay —
            // worse than the overlap the cancellation exists to prevent.
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
        }
    }

    func signIn() {
        login.show { [weak self] in
            Task { @MainActor in await self?.refresh() }
        }
    }
}
