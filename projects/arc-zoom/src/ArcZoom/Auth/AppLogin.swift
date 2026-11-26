//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import Observation
import Security

/// The OPERATOR login in front of the operator window (2026-09-22).
///
/// A GUARD, NOT A LOCK. It keeps a crew member from wandering into the Zoom controls mid show. It
/// protects no secret: the Marketplace pair is NOT in this binary, it is pushed into each Mac's login
/// keychain by `seed-zoom-credentials.sh`, which also pushes this password. So the
/// password is not in the binary either, and rotating it is a re-seed, not a rebuild.
///
/// Deliberately NOT gated: the control API on 127.0.0.1:8766 (Companion and Presenter drive it with no
/// person at the keyboard) and Meeting > End Meeting for Everyone (ending must never wait on a password).
@MainActor @Observable
final class AppLogin {
    static let shared = AppLogin()

    static let service = "ARC Zoom App Login"
    static let user = "OPERATOR"

    private(set) var unlocked = false

    /// Is there a password on this Mac at all. No item = not seeded yet, and the gate says so.
    var provisioned: Bool { Self.storedPassword() != nil }

    func attempt(user: String, password: String) -> Bool {
        guard user.trimmingCharacters(in: .whitespaces).uppercased() == Self.user,
              let stored = Self.storedPassword(), !stored.isEmpty,
              Self.equal(Data(password.utf8), Data(stored.utf8))
        else {
            ShowLog.log("login refused for \"\(user)\"")
            return false
        }
        unlocked = true
        ShowLog.log("login: \(Self.user) unlocked the operator window")
        return true
    }

    func lock() { unlocked = false; ShowLog.log("login: operator window locked") }

    // MARK: - Keychain

    static func storedPassword() -> String? { Keychain.string(service: service, account: user) }

    /// The item is there but this build was refused it (Deny, a dismissed dialog, a locked keychain).
    static var refused: Bool { if case .refused = Keychain.read(service: service, account: user) { return true } else { return false } }

    @discardableResult
    static func store(password: String) -> Bool {
        Keychain.write(service: service, account: user, data: Data(password.utf8))
    }

    /// Constant-time over equal lengths, so timing says nothing about how much of a guess was right.
    private static func equal(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}
