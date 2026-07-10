import Dispatch
import Foundation
import KaltoeCore

/// Headless 칼퇴타이머 core for the Linux tray. Protocol (see
/// linux/kaltoe-tray.py): NDJSON StatusLine on stdout, emitted on change and
/// at least every 60 s; any stdin line forces a refresh; stdin EOF exits.

final class RefreshFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false
    func raise() { lock.lock(); raised = true; lock.unlock() }
    func consume() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let value = raised; raised = false; return value
    }
}

let refreshFlag = RefreshFlag()

Thread.detachNewThread {
    while readLine(strippingNewline: true) != nil { refreshFlag.raise() }
    exit(0) // stdin closed — the tray frontend is gone
}

Task { @MainActor in
    let state = HeadlessState()
    let encoder = StatusLine.encoder()
    var lastEmitted: StatusLine?
    var lastEmitAt = Date.distantPast
    var tick = 0
    while true {
        if tick % 600 == 0 || refreshFlag.consume() { await state.refresh() }
        let now = Date()
        let line = state.status(now: now)
        if line != lastEmitted || now.timeIntervalSince(lastEmitAt) >= 60 {
            if let data = try? encoder.encode(line),
               let json = String(data: data, encoding: .utf8) {
                print(json)
                fflush(stdout)
                lastEmitted = line
                lastEmitAt = now
            }
        }
        tick += 1
        try? await Task.sleep(nanoseconds: 1_000_000_000)
    }
}

dispatchMain()
