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
    let hookRunner = HookRunner()
    let encoder = StatusLine.encoder()
    var lastEmitted: StatusLine?
    var lastEmitAt = Date.distantPast
    var tick = 0
    while true {
        let forced = refreshFlag.consume()
        if tick % 600 == 0 || forced { await state.refresh() }
        let now = Date()
        hookRunner.evaluate(today: state.weekData.todayRecord(now: now), now: now)
        let line = state.status(now: now)
        if line != lastEmitted || now.timeIntervalSince(lastEmitAt) >= 60 {
            if var data = try? encoder.encode(line) {
                data.append(0x0A)   // NDJSON terminator; the encoder already gave us UTF-8
                // Write straight to fd 1 rather than `print`: C stdio would need
                // an explicit flush (the tray reads this over a fully-buffered
                // pipe), and flushing is not safe here — the stdin reader thread
                // above holds stdin's stream lock inside getline for the life of
                // the daemon, so fflush(nil) would deadlock walking every stream.
                // `try?` keeps `print`'s silent-failure behaviour once the tray
                // exits; FileHandle.write(_:) would trap instead.
                try? FileHandle.standardOutput.write(contentsOf: data)
                lastEmitted = line
                lastEmitAt = now
            }
        }
        tick += 1
        do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { break }
    }
}

dispatchMain()
