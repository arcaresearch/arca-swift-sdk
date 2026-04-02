import Foundation

/// Low-level HTTP client for the Arca API.
///
/// Uses `URLSession` for networking. Handles:
/// - Bearer token injection on every request
/// - Standard `{ success, data, error }` envelope unwrapping
/// - Automatic retries for transient errors (502/503/504 and network failures)
/// - Single 401 retry via `onUnauthorized` (token provider refresh)
///
/// Thread-safe via NSLock on the mutable token. HTTP methods run concurrently
/// (no actor mailbox serialization) so parallel CDN fallback and gap fetches
/// are truly parallel.
public final class ArcaClient: @unchecked Sendable {
    private let tokenLock = NSLock()
    private var _token: String
    private var token: String {
        get { tokenLock.lock(); defer { tokenLock.unlock() }; return _token }
        set { tokenLock.lock(); defer { tokenLock.unlock() }; _token = newValue }
    }
    private let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder

    private let onUnauthorized: (@Sendable () async throws -> String)?
    private let onAuthError: (@Sendable (Error) -> Void)?

    private static let transientStatuses: Set<Int> = [502, 503, 504]
    private static let maxRetries = 2
    private static let retryDelay: UInt64 = 1_000_000_000 // 1 second in nanoseconds

    public init(
        token: String,
        baseURL: URL,
        urlSessionConfiguration: URLSessionConfiguration = .default,
        onUnauthorized: (@Sendable () async throws -> String)? = nil,
        onAuthError: (@Sendable (Error) -> Void)? = nil
    ) {
        self._token = token
        self.baseURL = baseURL.appendingPathComponent("api/v1")
        self.session = URLSession(configuration: urlSessionConfiguration)
        self.decoder = JSONDecoder()
        self.onUnauthorized = onUnauthorized
        self.onAuthError = onAuthError
    }

    /// Update the bearer token (e.g., after a token refresh).
    public func updateToken(_ newToken: String) {
        self.token = newToken
    }

    // MARK: - Public HTTP Methods

    public func get<T: Decodable>(_ path: String, query: [String: String]? = nil) async throws -> T {
        try await executeWithAuthRetry(method: "GET", path: path, query: query)
    }

    public func post<T: Decodable>(_ path: String, body: (any Encodable)? = nil) async throws -> T {
        try await executeWithAuthRetry(method: "POST", path: path, body: body)
    }

    public func delete<T: Decodable>(_ path: String, query: [String: String]? = nil) async throws -> T {
        try await executeWithAuthRetry(method: "DELETE", path: path, query: query)
    }

    // MARK: - Auth Retry Wrapper

    private func executeWithAuthRetry<T: Decodable>(
        method: String,
        path: String,
        query: [String: String]? = nil,
        body: (any Encodable)? = nil
    ) async throws -> T {
        do {
            return try await requestWithRetry(method: method, path: path, query: query, body: body)
        } catch {
            guard Self.isUnauthorized(error), let onUnauthorized else {
                if Self.isUnauthorized(error) {
                    onAuthError?(error)
                }
                throw error
            }
            do {
                let newToken = try await onUnauthorized()
                self.token = newToken
                return try await requestWithRetry(method: method, path: path, query: query, body: body)
            } catch {
                onAuthError?(error)
                throw error
            }
        }
    }

    private static func isUnauthorized(_ error: Error) -> Bool {
        if case ArcaError.unauthorized = error { return true }
        return false
    }

    // MARK: - Retry Logic

    private func requestWithRetry<T: Decodable>(
        method: String,
        path: String,
        query: [String: String]? = nil,
        body: (any Encodable)? = nil
    ) async throws -> T {
        var lastError: Error?

        for attempt in 0...Self.maxRetries {
            try Task.checkCancellation()
            do {
                return try await requestOnce(method: method, path: path, query: query, body: body)
            } catch {
                lastError = error
                if !Self.isTransient(error) || attempt == Self.maxRetries {
                    throw error
                }
                try await Task.sleep(nanoseconds: Self.retryDelay)
            }
        }
        throw lastError!
    }

    // MARK: - Single Request

    private func requestOnce<T: Decodable>(
        method: String,
        path: String,
        query: [String: String]? = nil,
        body: (any Encodable)? = nil
    ) async throws -> T {
        let url = buildURL(path: path, query: query)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        if let body = body {
            request.httpBody = try JSONEncoder().encode(AnyEncodable(body))
        }

        let data: Data
        let response: URLResponse

        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ArcaError.networkError(underlying: error)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ArcaError.networkError(underlying: URLError(.badServerResponse))
        }

        if Self.transientStatuses.contains(httpResponse.statusCode) {
            throw TransientHTTPError(statusCode: httpResponse.statusCode)
        }

        return try unwrap(data: data, statusCode: httpResponse.statusCode)
    }

    // MARK: - Response Unwrapping

    private func unwrap<T: Decodable>(data: Data, statusCode: Int) throws -> T {
        let envelope: APIResponse<T>
        do {
            envelope = try decoder.decode(APIResponse<T>.self, from: data)
        } catch let decodingError as DecodingError {
            if data.first == UInt8(ascii: "{") || data.first == UInt8(ascii: "[") {
                throw ArcaError.decodingError(underlying: decodingError)
            }
            let body = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
            throw ArcaError.nonJsonResponse(statusCode: statusCode, body: body)
        } catch {
            let body = String(data: data.prefix(200), encoding: .utf8) ?? "<binary>"
            throw ArcaError.nonJsonResponse(statusCode: statusCode, body: body)
        }

        if !envelope.success || envelope.data == nil {
            if statusCode == 401 {
                throw ArcaError.unauthorized(
                    message: envelope.error?.message ?? "Invalid or expired authentication",
                    errorId: envelope.error?.errorId
                )
            }
            if let error = envelope.error {
                throw mapAPIError(code: error.code, message: error.message, errorId: error.errorId)
            }
            throw ArcaError.unknown(
                code: "UNKNOWN",
                message: "Request failed with status \(statusCode)",
                errorId: nil
            )
        }

        return envelope.data!
    }

    // MARK: - URL Building

    private func buildURL(path: String, query: [String: String]?) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: true)!
        if let query = query, !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        return components.url!
    }

    // MARK: - Transient Detection

    private static func isTransient(_ error: Error) -> Bool {
        if error is TransientHTTPError { return true }
        if (error as? URLError) != nil { return true }
        return false
    }
}

// MARK: - Internal Helpers

/// Sentinel error for transient HTTP status codes (502/503/504).
private struct TransientHTTPError: Error {
    let statusCode: Int
}

/// Type-erased Encodable wrapper for encoding arbitrary request bodies.
private struct AnyEncodable: Encodable {
    private let encodeClosure: (Encoder) throws -> Void

    init(_ wrapped: any Encodable) {
        self.encodeClosure = { encoder in
            try wrapped.encode(to: encoder)
        }
    }

    func encode(to encoder: Encoder) throws {
        try encodeClosure(encoder)
    }
}
