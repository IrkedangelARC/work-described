//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import Security

/// Every keychain read and write in ARC Zoom goes through here (2026-09-23).
///
/// The operator: "we cant have this pop up 5 times every time we do this" and "i keep hitting always allow and it
/// keeps popping up". Three causes, all closed here:
///
/// 1. READ ON EVERY REDRAW. `AppLogin.provisioned`, the CONNECT module's `credentialsOK`/`signedIn` and the
///    login gate's 2 s re-check each ran `SecItemCopyMatching`. An item this build is not trusted for asks
///    once PER READ, and a Deny or a dismissed dialog was simply asked again two seconds later. Now each
///    item is read at most once per launch; the answer, including a refusal, is kept until `invalidate`.
/// 2. DELETE + ADD ON EVERY WRITE. A token refresh replaced the item, and a new item trusts only the build
///    that wrote it, so whichever of Debug / Release wrote last locked the other out and "Always Allow"
///    never held. Writes now update the existing item in place (`SecItemUpdate`), which keeps its access list.
/// 3. THE TEST HOST. `xcodebuild test` launches the Debug app, whose login gate read the real keychain. Under
///    XCTest this is an in-memory store and the login keychain is never touched.
///
/// Debug builds are also signed Developer ID now (project.yml), so they satisfy the same access list as
/// the release app instead of being a stranger to it.
enum Keychain {
    enum Read: Equatable {
        case value(Data)
        case missing
        /// The item exists but this build may not read it (denied, dialog dismissed, or locked keychain).
        case refused(OSStatus)
    }

    static let underTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil

    /// Every item the app reads, preloaded off the main thread at launch.
    static let appItems: [(service: String, account: String)] = [
        (AppLogin.service, AppLogin.user),
        (ZoomCredentials.service, "ARC Zoom Client ID"), (ZoomCredentials.service, "ARC Zoom"),
        (TokenStore.service, "ARC Tech"),
    ]

    private static let lock = NSLock()
    private static var cache: [String: Read] = [:]
    private static var inFlight: Set<String> = []
    private static var memory: [String: Data] = [:]   // the XCTest store
    private static var slowSince: Date?
    /// When each item was last found missing: a main-thread miss inside this window does not start another
    /// fetch, so a view redrawing every second cannot keep a background read permanently in flight.
    private static var missingAt: [String: Date] = [:]
    private static var preloaded = false

    private static func key(_ service: String, _ account: String) -> String { service + "\u{1F}" + account }

    /// A keychain read has been waiting on macOS for more than a few seconds: an approval dialog is up (or
    /// could not be shown because the app is in the background). The login gate says so instead of hanging.
    static var waitingOnMacOS: Bool {
        lock.lock(); defer { lock.unlock() }
        return slowSince.map { Date().timeIntervalSince($0) > 3 } ?? false
    }

    /// The launch preload is not back yet (the gate shows CHECKING until it is).
    static var loading: Bool { lock.lock(); defer { lock.unlock() }; return !underTest && !preloaded }

    /// The item. NEVER blocks the main thread (2026-09-23: a background launch hung for good inside
    /// SecItemCopyMatching, called from the login gate's body): on the main thread an item not yet read is
    /// fetched on a background thread and `.missing` is answered for now; `.arcKeychainChanged` says when
    /// the real answer is in. Off the main thread the call reads and waits.
    static func read(service: String, account: String) -> Read {
        let k = key(service, account)
        lock.lock()
        if underTest { defer { lock.unlock() }; return memory[k].map(Read.value) ?? .missing }
        if let hit = cache[k] { lock.unlock(); return hit }
        lock.unlock()
        if Thread.isMainThread {
            lock.lock(); let recent = missingAt[k].map { Date().timeIntervalSince($0) < 2 } ?? false; lock.unlock()
            if !recent { fetchInBackground(service: service, account: account) }
            return .missing
        }
        return fetch(service: service, account: account)
    }

    /// Load every app item on a background thread; posts `.arcKeychainChanged` when done.
    static func preload() {
        guard !underTest else { return }
        lock.lock(); preloaded = false; lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            let t0 = Date()
            let answers = appItems.map { i -> String in
                switch fetch(service: i.service, account: i.account) {
                case .value: return "ok"
                case .missing: return "missing"
                case .refused(let st): return "refused(\(st))"
                }
            }
            lock.lock(); preloaded = true; lock.unlock()
            ShowLog.log("keychain preload: \(answers.joined(separator: ", ")) in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            DispatchQueue.main.async { NotificationCenter.default.post(name: .arcKeychainChanged, object: nil) }
        }
    }

    /// Suspends until the launch preload is back (only the preload: other background reads come and go).
    static func waitForPreload() async {
        while loading { try? await Task.sleep(for: .milliseconds(50)) }
    }

    private static func fetchInBackground(service: String, account: String) {
        let k = key(service, account)
        lock.lock()
        guard !inFlight.contains(k) else { lock.unlock(); return }
        inFlight.insert(k)
        lock.unlock()
        DispatchQueue.global(qos: .userInitiated).async {
            let before = cachedValue(k)
            let after = fetch(service: service, account: account)
            lock.lock(); inFlight.remove(k); lock.unlock()
            if after != before || after != .missing {
                DispatchQueue.main.async { NotificationCenter.default.post(name: .arcKeychainChanged, object: nil) }
            }
        }
    }

    private static func cachedValue(_ k: String) -> Read? { lock.lock(); defer { lock.unlock() }; return cache[k] }

    /// The blocking read. The lock is NOT held across SecItemCopyMatching, so a read waiting on a macOS
    /// dialog never stalls another thread's cache lookup.
    private static func fetch(service: String, account: String) -> Read {
        let k = key(service, account)
        lock.lock(); if slowSince == nil { slowSince = Date() }; lock.unlock()
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        let result: Read
        switch status {
        case errSecSuccess: result = (item as? Data).map(Read.value) ?? .missing
        case errSecItemNotFound: result = .missing
        default: result = .refused(status)
        }
        lock.lock()
        slowSince = nil
        // A missing item is not cached: a seed can land while the app runs, and asking about an item that
        // is not there never raises a dialog.
        if result != .missing { cache[k] = result; missingAt[k] = nil } else { missingAt[k] = Date() }
        lock.unlock()
        return result
    }

    static func data(service: String, account: String) -> Data? {
        if case .value(let d) = read(service: service, account: account) { return d }
        return nil
    }

    static func string(service: String, account: String) -> String? {
        data(service: service, account: account).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Update the item in place (its access list survives), or add it when it is not there yet.
    @discardableResult
    static func write(service: String, account: String, data: Data) -> Bool {
        let k = key(service, account)
        if underTest { lock.lock(); memory[k] = data; lock.unlock(); return true }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        var status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = base
            add[kSecValueData as String] = data
            status = SecItemAdd(add as CFDictionary, nil)
        }
        lock.lock(); cache[k] = status == errSecSuccess ? .value(data) : nil; lock.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: .arcKeychainChanged, object: nil) }
        return status == errSecSuccess
    }

    static func delete(service: String, account: String) {
        let k = key(service, account)
        if underTest { lock.lock(); memory[k] = nil; lock.unlock(); return }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        lock.lock(); cache[k] = nil; lock.unlock()
    }

    /// Forget what was read, so the next read asks the keychain again (the operator retrying after a Deny).
    static func invalidate() {
        lock.lock(); cache.removeAll(); lock.unlock()
        preload()
    }
}

extension Notification.Name {
    /// A keychain answer arrived (launch preload, TRY AGAIN, a seed). Views re-read the cache.
    static let arcKeychainChanged = Notification.Name("arcKeychainChanged")
}
