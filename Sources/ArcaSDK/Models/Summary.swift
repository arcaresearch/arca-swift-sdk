import Foundation

public struct ExplorerSummary: Codable, Sendable {
    public let objectCount: Int
    public let operationCount: Int
    public let eventCount: Int
    public let pendingOperationCount: Int?
    public let expiredOperationCount: Int?
}
