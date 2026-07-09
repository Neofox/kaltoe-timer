import Foundation

/// Flex private API constants, captured 2026-07-09 (see docs/flex-api.md).
/// Unofficial endpoints — if Flex changes them, this file and the fixtures
/// are the only places to update.
enum FlexAPIConfig {
    static let loginURL = URL(string: "https://flex.team/sign-in")!

    /// Cookies that must all exist for a session to count as logged in.
    /// AID is the auth token; V2_WS_AID carries the workspace context.
    static let sessionCookieNames: Set<String> = ["AID", "V2_WS_AID"]

    /// Opaque per-user identifier appearing in both endpoint URLs.
    /// Auto-discovered from the V2_CUSTOMER_INFO cookie at login; the
    /// literal is the value captured during API discovery, as fallback.
    static var userIdHash: String {
        UserDefaults.standard.string(forKey: "flexUserIdHash") ?? "SCRUBBEDHASH"
    }

    private static func dayString(_ date: Date) -> String {
        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = .current
        return df.string(from: date)
    }

    private static func request(_ url: URL, cookieHeader: String) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        req.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
        return req
    }

    /// Completed WORK/REST blocks per day, [from, to] inclusive local dates.
    static func schedulesRequest(from: Date, to: Date, cookieHeader: String) -> URLRequest {
        var comps = URLComponents(
            string: "https://flex.team/api/v3/time-tracking/users/\(userIdHash)/work-schedules")!
        comps.queryItems = [
            URLQueryItem(name: "from", value: dayString(from)),
            URLQueryItem(name: "to", value: dayString(to)),
            URLQueryItem(name: "timezone", value: TimeZone.current.identifier),
        ]
        return request(comps.url!, cookieHeader: cookieHeader)
    }

    /// Live work-clock records (carries the ongoing day), epoch-ms bounds.
    static func clockRequest(from: Date, to: Date, cookieHeader: String) -> URLRequest {
        var comps = URLComponents(
            string: "https://flex.team/api/v2/time-tracking/work-clock/users")!
        comps.queryItems = [
            URLQueryItem(name: "userIdHashes", value: userIdHash),
            URLQueryItem(name: "timeStampFrom", value: String(Int(from.timeIntervalSince1970 * 1000))),
            URLQueryItem(name: "timeStampTo", value: String(Int(to.timeIntervalSince1970 * 1000))),
        ]
        return request(comps.url!, cookieHeader: cookieHeader)
    }
}
