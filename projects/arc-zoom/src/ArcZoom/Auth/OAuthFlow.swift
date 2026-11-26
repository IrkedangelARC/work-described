//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import CryptoKit
import Foundation

enum OAuthFlow {
    struct AccessTokenResponse: Decodable {
        let accessToken: String
        let refreshToken: String?
        let tokenType: String
        let expiresIn: Int
        let scope: String

        enum CodingKeys: String, CodingKey {
            case accessToken = "access_token"
            case refreshToken = "refresh_token"
            case tokenType = "token_type"
            case expiresIn = "expires_in"
            case scope
        }
    }

    enum FlowError: Error, CustomStringConvertible {
        case tokenExchangeFailed(status: Int, body: String)
        case browserOpenFailed
        case decodeFailed(Error)

        var description: String {
            switch self {
            case .tokenExchangeFailed(let status, let body):
                return "token exchange failed (HTTP \(status)): \(body)"
            case .browserOpenFailed:
                return "failed to open browser for authorization URL"
            case .decodeFailed(let err):
                return "failed to decode token response: \(err)"
            }
        }
    }

    /// The browser round trip, with `state` (CSRF) and PKCE (S256) so a stray redirect cannot be replayed
    /// into a token (audit P1). Only for a first sign-in or when a refresh fails: a running show never
    /// wants a browser (see `refresh`).
    static func authorize(
        clientId: String,
        clientSecret: String,
        scopes: [String],
        redirectURI: String = "http://localhost:8767/oauth/callback"
    ) async throws -> AccessTokenResponse {
        let state = randomToken(24)
        let verifier = randomToken(48)
        let server = LocalCallbackServer(expectedState: state)

        let authURL = makeAuthorizationURL(clientId: clientId, scopes: scopes, redirectURI: redirectURI,
                                           state: state, codeChallenge: pkceChallenge(verifier))
        ShowLog.log("oauth: opening the browser for ARC Tech's consent")
        guard NSWorkspace.shared.open(authURL) else { throw FlowError.browserOpenFailed }

        ShowLog.log("oauth: waiting for the redirect on \(redirectURI)")
        let code = try await server.waitForCode()
        ShowLog.log("oauth: authorization code received, exchanging it")

        return try await exchangeCode(code: code, clientId: clientId, clientSecret: clientSecret,
                                      redirectURI: redirectURI, codeVerifier: verifier)
    }

    /// The refresh-token grant: the same Basic auth, no browser. Zoom ROTATES refresh tokens, so the
    /// caller must store the new one or the next refresh fails.
    static func refresh(refreshToken: String, clientId: String, clientSecret: String) async throws -> AccessTokenResponse {
        var req = URLRequest(url: URL(string: "https://zoom.us/oauth/token")!)
        req.httpMethod = "POST"
        let basic = Data("\(clientId):\(clientSecret)".utf8).base64EncodedString()
        req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [URLQueryItem(name: "grant_type", value: "refresh_token"), URLQueryItem(name: "refresh_token", value: refreshToken)]
        req.httpBody = body.percentEncodedQuery?.data(using: .utf8)
        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw FlowError.tokenExchangeFailed(status: (response as? HTTPURLResponse)?.statusCode ?? -1, body: String(data: data, encoding: .utf8) ?? "")
        }
        do { return try JSONDecoder().decode(AccessTokenResponse.self, from: data) } catch { throw FlowError.decodeFailed(error) }
    }

    static func randomToken(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes, &b)
        return base64url(Data(b))
    }
    static func pkceChallenge(_ verifier: String) -> String { base64url(Data(SHA256.hash(data: Data(verifier.utf8)))) }
    private static func base64url(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    static func makeAuthorizationURL(
        clientId: String,
        scopes: [String],
        redirectURI: String,
        state: String? = nil,
        codeChallenge: String? = nil
    ) -> URL {
        var comps = URLComponents(string: "https://zoom.us/oauth/authorize")!
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientId),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: scopes.joined(separator: " "))
        ]
        if let state { items.append(URLQueryItem(name: "state", value: state)) }
        if let codeChallenge {
            items.append(URLQueryItem(name: "code_challenge", value: codeChallenge))
            items.append(URLQueryItem(name: "code_challenge_method", value: "S256"))
        }
        comps.queryItems = items
        return comps.url!
    }

    static func exchangeCode(
        code: String,
        clientId: String,
        clientSecret: String,
        redirectURI: String,
        codeVerifier: String? = nil
    ) async throws -> AccessTokenResponse {
        var req = URLRequest(url: URL(string: "https://zoom.us/oauth/token")!)
        req.httpMethod = "POST"
        let basic = Data("\(clientId):\(clientSecret)".utf8).base64EncodedString()
        req.setValue("Basic \(basic)", forHTTPHeaderField: "Authorization")
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "grant_type", value: "authorization_code"),
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "redirect_uri", value: redirectURI)
        ] + (codeVerifier.map { [URLQueryItem(name: "code_verifier", value: $0)] } ?? [])
        req.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let body = String(data: data, encoding: .utf8) ?? ""
            throw FlowError.tokenExchangeFailed(status: status, body: body)
        }
        do {
            return try JSONDecoder().decode(AccessTokenResponse.self, from: data)
        } catch {
            throw FlowError.decodeFailed(error)
        }
    }
}
