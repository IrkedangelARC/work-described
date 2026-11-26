//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import CryptoKit
import Foundation

enum JWTSigner {
    struct SDKTokenPayload: Encodable {
        let iss: String
        let appKey: String
        let iat: Int
        let exp: Int
        let tokenExp: Int
    }

    static func makeSDKInitToken(
        sdkKey: String,
        sdkSecret: String,
        lifetime: TimeInterval = 60 * 60 * 24
    ) throws -> String {
        let now = Int(Date().timeIntervalSince1970)
        let exp = now + Int(lifetime)
        let payload = SDKTokenPayload(
            iss: sdkKey,
            appKey: sdkKey,
            iat: now,
            exp: exp,
            tokenExp: exp
        )
        return try sign(payload: payload, secret: sdkSecret)
    }

    static func sign<T: Encodable>(payload: T, secret: String) throws -> String {
        let headerJSON = #"{"alg":"HS256","typ":"JWT"}"#
        let headerB64 = Data(headerJSON.utf8).base64URLEncoded()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let payloadData = try encoder.encode(payload)
        let payloadB64 = payloadData.base64URLEncoded()

        let unsigned = "\(headerB64).\(payloadB64)"
        let key = SymmetricKey(data: Data(secret.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data(unsigned.utf8), using: key)
        let sigB64 = Data(mac).base64URLEncoded()

        return "\(unsigned).\(sigB64)"
    }
}

extension Data {
    func base64URLEncoded() -> String {
        return base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
