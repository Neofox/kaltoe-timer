import Foundation

public enum Urgency: String, Equatable, Sendable {
    case normal, warning, critical
}

public struct MenuDisplay: Equatable, Sendable {
    public var state: DisplayState
    public var urgency: Urgency

    public init(state: DisplayState, urgency: Urgency) {
        self.state = state
        self.urgency = urgency
    }
}

public enum DisplayState: Equatable, Sendable {
    case noSession
    case notClockedIn
    case toLunch(timeLeft: TimeInterval)   // counting down to the lunch-leave moment
    case onBreak(timeLeft: TimeInterval)   // counting down to work resuming
    case counting(timeLeft: TimeInterval)  // counting down to leave time
    case overtime(today: TimeInterval, clockedIn: Bool)   // overtime worked today; negative if short

    private static let warningThreshold: TimeInterval = 30 * 60
    private static let criticalThreshold: TimeInterval = 10 * 60
    /// How long the 자유! celebration lasts: exactly the span `signedHM` would render
    /// as "+0:00". `fileprivate` rather than `private` only because the speech that
    /// has to agree with it lives on `MenuDisplay`, one type over in this file.
    fileprivate static let jayuWindow: TimeInterval = 60

    /// Smart single value with day phases and an overwork urgency level.
    ///
    /// `weeklyOvertime` is supplied by the caller rather than derived here.
    /// Both callers already compute it for their own purposes, and `recompute`
    /// runs every second — deriving it again inside this function was pure
    /// waste. Taking it as a parameter also removes the need for `week`, which
    /// fed nothing else.
    public static func computeDisplay(hasSession: Bool, today: WorkRecord?,
                               weeklyOvertime: TimeInterval,
                               timeOff: [Date: TimeInterval] = [:],
                               now: Date, rules: WorkRules,
                               calendar: Calendar = .current) -> MenuDisplay {
        guard hasSession else { return MenuDisplay(state: .noSession, urgency: .normal) }
        guard let today else { return MenuDisplay(state: .notClockedIn, urgency: .normal) }
        let off = WorkCalculator.timeOff(on: today.clockIn, in: timeOff, calendar: calendar)
        let left = WorkCalculator.timeLeft(clockIn: today.clockIn, now: now, rules: rules, timeOff: off)
        if today.clockOut == nil && left > 0 {
            let lunch = WorkCalculator.lunchWindow(on: now, rules: rules, calendar: calendar)
            let leave = WorkCalculator.leaveTime(clockIn: today.clockIn, rules: rules, timeOff: off)
            if leave > lunch.endAt { // lunch phases only apply to a normally-shaped day
                if now < lunch.leaveAt {
                    return MenuDisplay(state: .toLunch(timeLeft: lunch.leaveAt.timeIntervalSince(now)),
                                       urgency: .normal)
                }
                if now < lunch.endAt {
                    return MenuDisplay(state: .onBreak(timeLeft: lunch.endAt.timeIntervalSince(now)),
                                       urgency: .normal)
                }
            }
            let urgency: Urgency = left <= criticalThreshold ? .critical
                : left <= warningThreshold ? .warning : .normal
            return MenuDisplay(state: .counting(timeLeft: left), urgency: urgency)
        }
        let todayOvertime = WorkCalculator.dailyOvertime(record: today, now: now,
                                                         rules: rules, timeOff: timeOff)
        let clockedIn = today.clockOut == nil
        let urgency: Urgency
        if WorkCalculator.hasReachedWeeklyCap(weeklyOvertime: weeklyOvertime, rules: rules) {
            urgency = .critical                     // cap applies on or off the clock
        } else if clockedIn, WorkCalculator.isPastOvertimeCutoff(now: now, rules: rules,
                                                                 calendar: calendar) {
            urgency = .critical                     // working past the cutoff
        } else if clockedIn {
            urgency = .warning                      // in overtime, within both limits
        } else {
            urgency = .normal                       // day settled
        }
        return MenuDisplay(state: .overtime(today: todayOvertime, clockedIn: clockedIn),
                           urgency: urgency)
    }

    public var menuBarText: String {
        switch self {
        case .noSession: return "—"
        case .notClockedIn: return "--:--"
        case .toLunch(let left): return Formatting.hm(left)
        case .onBreak(let left): return "BREAK " + Formatting.hm(left)
        case .counting(let left): return Formatting.hm(left)
        case .overtime(let today, _): return "OT " + Formatting.signedHM(today)
        }
    }

    public var iconName: String {
        switch self {
        case .toLunch: return "fork.knife"
        case .onBreak: return "cup.and.saucer"
        case .noSession, .notClockedIn, .counting, .overtime: return "timer"
        }
    }

    /// Menu-bar-only glyph, deliberately parallel to `iconName` rather than
    /// replacing it. `iconName` is the daemon's NDJSON contract: `kaltoe-tray.py`
    /// maps exactly `timer`, `fork.knife` and `cup.and.saucer` in `ICON_BASE` and
    /// falls back to a generic timer for anything else, so putting these names on the
    /// wire would silently flatten the lunch phases on Linux.
    public var labelGlyph: String {
        switch self {
        case .noSession: return "zzz"
        case .notClockedIn: return "timer"
        case .toLunch: return "fork.knife"
        case .onBreak: return "cup.and.saucer"
        case .counting(let left):
            // Shares `warningThreshold` with `Urgency.warning`, so retuning the
            // urgency threshold moves the walking figure with it — the two values
            // coincide on purpose, and the coupling is the constant, not a test.
            return left <= Self.warningThreshold ? "figure.walk" : "timer"
        case .overtime(let today, let clockedIn):
            // Settled outranks everything: a day you have clocked out of reads as
            // closed even if it ended short, in which case the fill did not finish
            // and the figure is signed.
            guard clockedIn else { return "checkmark" }
            return today < Self.jayuWindow ? "figure.walk.departure" : "flame"
        }
    }

    /// Menu-bar-only text: `menuBarText` minus the `BREAK`/`OT` word prefixes, which
    /// `labelGlyph` now carries. The prefixes stay on the wire because on KDE the
    /// tray renders that text alone with no glyph at all, making them its only phase
    /// signal.
    public var labelText: String {
        switch self {
        case .noSession: return ""
        case .notClockedIn: return "--:--"
        case .toLunch(let left), .onBreak(let left), .counting(let left):
            return Formatting.hm(left)
        case .overtime(let today, let clockedIn):
            // 자유! for exactly the span `signedHM` would render "+0:00", so nothing
            // is displaced. Not a state, an event or a timer — just what this
            // property returns for one minute, which is why it cannot get stuck on,
            // fire repeatedly under the 1s tick, or fire retroactively on a launch
            // at 20:00.
            if clockedIn, today < Self.jayuWindow { return "자유!" }
            return Formatting.signedHM(today)
        }
    }
}

public extension MenuDisplay {
    /// What VoiceOver announces for the Mac menu bar label — the third member of the
    /// label's vocabulary, beside `labelGlyph` and `labelText`.
    ///
    /// It cannot be assembled from those two. The label renders to a single
    /// `NSImage`, which has no per-element accessibility, so the glyph is invisible
    /// to VoiceOver and `labelText` alone is ambiguous: the three countdowns are all
    /// a bare `Formatting.hm`, and overtime is a signed figure with nothing saying
    /// what it counts. Speech therefore has to restate in words what the glyph says
    /// in pixels.
    ///
    /// On `MenuDisplay` rather than `DisplayState` because at-limit and ordinary
    /// overtime differ only by urgency.
    var spokenLabel: String {
        switch state {
        case .noSession:
            // Keyed to the case, not to an empty `labelText` — that would be a
            // coincidence of vocabulary, and any later state with no text would
            // inherit the phrase.
            return "Signed out"
        case .notClockedIn:
            return "Not clocked in"
        case .toLunch(let left):
            return "\(Formatting.hm(left)) until lunch"
        case .onBreak(let left):
            return "\(Formatting.hm(left)) of break left"
        case .counting(let left):
            return "\(Formatting.hm(left)) until leave time"
        case .overtime(let today, let clockedIn):
            let figure = Formatting.signedHM(today)
            guard clockedIn else { return "Clocked out, \(figure) against today's target" }
            let jayu = today < DisplayState.jayuWindow
            // Through `LabelPhase` rather than reading `urgency` here: `.critical`
            // arrives off the clock too, and that derivation already exists.
            //
            // Ahead of the 자유! minute deliberately. The two can coincide — the
            // weekly cap is `.critical` whatever today's figure is — and hitting the
            // cap is the more important of the two things to say. It does not *replace*
            // the celebration, though: in that minute the figure is "+0:00", which is
            // exactly the nothing `labelText` swaps for 자유!, so speech carries both
            // facts in words instead of announcing a figure the screen suppresses.
            if LabelPhase(self) == .atLimit {
                return jayu ? "Free to go, at the limit" : "Overtime \(figure), at the limit"
            }
            // The minute `labelText` spends on 자유!. Punctuation reads as nothing at
            // all aloud, so speech gets words for it.
            return jayu ? "Free to go" : "Overtime \(figure)"
        }
    }
}
