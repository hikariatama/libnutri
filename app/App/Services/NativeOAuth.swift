import AuthenticationServices
import CryptoKit
import Foundation
import NutritionCore
import UIKit

@MainActor final class NativeOAuth: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum Failure: Error { case cancelled, invalidCallback }
    private var browser: ASWebAuthenticationSession?
    struct Grant {
        var code: String
        var verifier: String
    }
    func authorize() async throws -> Grant {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw Failure.invalidCallback
        }
        let verifier = Data(bytes).base64URL
        let state = UUID().uuidString
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
        var url = URLComponents(
            url: CloudSession.issuer.appendingPathComponent("oauth/authorize"),
            resolvingAgainstBaseURL: false)!
        url.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            .init(name: "client_id", value: CloudSession.clientID),
            .init(name: "redirect_uri", value: CloudSession.callback),
            .init(name: "scope", value: "nutrition:read nutrition:write offline_access"),
            .init(name: "resource", value: CloudSession.origin.absoluteString),
            .init(name: "state", value: state),
            .init(name: "code_challenge", value: challenge),
            .init(name: "code_challenge_method", value: "S256"),
        ]
        return try await withCheckedThrowingContinuation { continuation in
            browser = ASWebAuthenticationSession(
                url: url.url!, callbackURLScheme: "nutritiontracker"
            ) {
                callback, error in
                if let error = error as? ASWebAuthenticationSessionError,
                    error.code == .canceledLogin
                {
                    continuation.resume(throwing: Failure.cancelled)
                    return
                }
                guard let callback, callback.scheme == "nutritiontracker", callback.host == "oauth",
                    callback.path == "/callback",
                    let parts = URLComponents(url: callback, resolvingAgainstBaseURL: false)
                else {
                    continuation.resume(throwing: Failure.invalidCallback)
                    return
                }
                let values = Dictionary(
                    parts.queryItems?.map { ($0.name, $0.value ?? "") } ?? [],
                    uniquingKeysWith: { _, _ in "" })
                guard values["state"] == state, values["iss"] == CloudSession.issuer.absoluteString,
                    let code = values["code"], !code.isEmpty
                else {
                    continuation.resume(throwing: Failure.invalidCallback)
                    return
                }
                continuation.resume(returning: Grant(code: code, verifier: verifier))
            }
            browser?.presentationContextProvider = self
            if browser?.start() != true { continuation.resume(throwing: Failure.invalidCallback) }
        }
    }
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
            .first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}
extension Data {
    fileprivate var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(
            of: "/", with: "_"
        ).replacingOccurrences(of: "=", with: "")
    }
}
