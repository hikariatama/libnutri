import Foundation

public enum TrackerError: Error, Equatable, Sendable {
    case offline, connection, invalidKey, missingKey, insufficientBalance, unavailableModel
    case configuration, permission, invalidResponse, emptyInput, noSpeech, persistence, cancelled
    case signedOut, conflict, notFound
    case nutritionOutOfRange
    case rateLimited(TimeInterval?)
    public var message: String {
        switch self {
        case .signedOut: "Your session has expired. Sign in again."
        case .conflict:
            "This meal changed on another client. Review the latest version and try again."
        case .notFound: "This meal has been deleted."
        case .offline: "You're offline. Connect to the internet to analyze this meal."
        case .connection: "Couldn't connect. Try again."
        case .invalidKey: "Your OpenRouter API key is invalid."
        case .missingKey: "Add your OpenRouter API key in Settings."
        case .insufficientBalance: "Your OpenRouter balance is insufficient."
        case .unavailableModel: "The selected AI model is unavailable."
        case .configuration: "Check your AI model configuration in Settings."
        case .permission: "This request isn't allowed. Check your OpenRouter settings."
        case .invalidResponse: "Couldn't analyze this meal. Try again."
        case .nutritionOutOfRange:
            "The estimate exceeds the limit for one entry. Check the quantity and units, or split the meal into smaller entries."
        case .emptyInput: "Enter a food description."
        case .noSpeech: "Couldn't hear any speech. Try recording again."
        case .persistence: "Couldn't save your changes. Your input is still here. Try again."
        case .cancelled: "Processing was cancelled."
        case .rateLimited: "Too many requests. Wait a moment and try again."
        }
    }
    public var retryable: Bool {
        switch self {
        case .connection, .invalidResponse, .nutritionOutOfRange, .rateLimited: true
        default: false
        }
    }
    public var opensSettings: Bool {
        switch self {
        case .invalidKey, .missingKey, .insufficientBalance, .unavailableModel, .configuration,
            .permission:
            true
        default: false
        }
    }
    public var category: String {
        switch self {
        case .signedOut: "invalid_token"
        case .conflict: "version_conflict"
        case .notFound: "not_found"
        case .offline: "offline"
        case .connection: "connection"
        case .invalidKey: "invalid_key"
        case .missingKey: "missing_key"
        case .insufficientBalance: "insufficient_balance"
        case .unavailableModel: "unavailable_model"
        case .configuration: "configuration"
        case .permission: "permission"
        case .invalidResponse: "invalid_response"
        case .nutritionOutOfRange: "nutrition_out_of_range"
        case .emptyInput: "empty_input"
        case .noSpeech: "no_speech"
        case .persistence: "persistence"
        case .cancelled: "cancelled"
        case .rateLimited: "rate_limited"
        }
    }
    public static func normalize(_ error: any Error) -> TrackerError {
        if let error = error as? TrackerError { return error }
        if error is CancellationError { return .cancelled }
        if let error = error as? URLError {
            switch error.code {
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff: return .offline
            case .cancelled: return .cancelled
            case .badURL, .unsupportedURL, .serverCertificateUntrusted, .secureConnectionFailed:
                return .configuration
            default: return .connection
            }
        }
        return .invalidResponse
    }
}

extension TrackerError {
    public static func remote(_ category: String) -> Self {
        switch category {
        case "invalid_token", "invalid_grant", "insufficient_scope": .signedOut
        case "version_conflict", "operation_in_progress", "idempotency_conflict": .conflict
        case "not_found", "deleted": .notFound
        case "invalid_key": .invalidKey
        case "missing_key": .missingKey
        case "insufficient_balance": .insufficientBalance
        case "unavailable_model": .unavailableModel
        case "configuration": .configuration
        case "permission": .permission
        case "nutrition_out_of_range": .nutritionOutOfRange
        case "empty_input", "input_too_long": .emptyInput
        case "no_speech", "record_again", "invalid_audio": .noSpeech
        case "rate_limited": .rateLimited(nil)
        case "connection", "interrupted", "auth_unavailable": .connection
        case "cancelled": .cancelled
        case "persistence": .persistence
        default: .invalidResponse
        }
    }
}
