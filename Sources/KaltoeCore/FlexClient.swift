import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public final class FlexClient {
    public enum FlexError: Error, Equatable { case noSession, sessionExpired, badResponse }

    private let session: URLSession

    public init() {
        // No automatic cookie storage/redirect surprises: we manage cookies ourselves.
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        // Two sequential requests happen per refresh; keep each bounded so the
        // daemon's 60 s heartbeat can never be starved by a hung connection.
        config.timeoutIntervalForRequest = 15
        session = URLSession(configuration: config)
    }

    public func fetchWeek(from: Date, to: Date) async throws -> ParseResult {
        guard let cookies = CookieVault.load(), !cookies.isEmpty else { throw FlexError.noSession }
        // No discovered user id yet (first run / pre-login) — nothing to query.
        guard !FlexAPIConfig.userIdHash.isEmpty else { throw FlexError.noSession }
        let header = cookies.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")

        let schedulesRequest = FlexAPIConfig.schedulesRequest(from: from, to: to, cookieHeader: header)
        let clockRequest = FlexAPIConfig.clockRequest(from: from, to: to, cookieHeader: header)

        let schedulesData = try await fetch(schedulesRequest)
        let clockData = try await fetch(clockRequest)

        return try FlexRecordParser.parse(schedules: schedulesData, clock: clockData)
    }

    /// Performs one request, applying the shared status/HTML-login-page checks.
    private func fetch(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FlexError.badResponse }
        switch http.statusCode {
        case 200:
            // An HTML login page with status 200 also means the session died.
            if let text = String(data: data.prefix(64), encoding: .utf8),
               text.lowercased().contains("<!doctype html") || text.lowercased().hasPrefix("<html") {
                CookieVault.clear()
                throw FlexError.sessionExpired
            }
            return data
        case 401, 403:
            CookieVault.clear()
            throw FlexError.sessionExpired
        default:
            throw FlexError.badResponse
        }
    }
}
