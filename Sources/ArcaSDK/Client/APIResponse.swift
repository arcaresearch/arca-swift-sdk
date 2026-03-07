import Foundation

/// The standard Arca API response envelope.
/// All API responses are wrapped in `{ success, data?, error? }`.
struct APIResponse<T: Decodable>: Decodable {
    let success: Bool
    let data: T?
    let error: APIErrorBody?
}

struct APIErrorBody: Decodable {
    let code: String
    let message: String
    let errorId: String?
}
