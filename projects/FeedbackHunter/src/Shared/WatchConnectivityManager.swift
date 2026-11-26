import Foundation
import WatchConnectivity
import Combine

/// Manages communication between iPad and Apple Watch
/// iPad acts as the data source, Watch as the receiver
final class WatchConnectivityManager: NSObject, ObservableObject {

    // MARK: - Singleton

    static let shared = WatchConnectivityManager()

    // MARK: - Published State

    /// Latest data received from counterpart
    @Published private(set) var latestData: WatchData?

    /// Connection status
    @Published private(set) var isReachable = false

    /// Whether Watch app is installed (iPad only)
    @Published private(set) var isWatchAppInstalled = false

    // MARK: - Private

    private var session: WCSession?

    private override init() {
        super.init()

        if WCSession.isSupported() {
            session = WCSession.default
            session?.delegate = self
            session?.activate()
        }
    }

    // MARK: - Send Data (iPad → Watch)

    /// Send current RTA data to Watch
    /// Uses applicationContext for latest state (not queued messages)
    func send(data: WatchData) {
        guard let session = session,
              session.activationState == .activated else {
            return
        }

        #if os(iOS)
        guard session.isWatchAppInstalled else { return }
        #endif

        do {
            let encoded = try JSONEncoder().encode(data)
            let dict: [String: Any] = ["rtaData": encoded]

            // Use updateApplicationContext for live data
            // This overwrites previous context (we only care about latest)
            try session.updateApplicationContext(dict)

            // Also send immediate message if reachable
            if session.isReachable {
                session.sendMessage(dict, replyHandler: nil) { error in
                    print("WatchConnectivity send error: \(error.localizedDescription)")
                }
            }
        } catch {
            print("WatchConnectivity encoding error: \(error)")
        }
    }
}

// MARK: - WCSessionDelegate

extension WatchConnectivityManager: WCSessionDelegate {

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
            #if os(iOS)
            self.isWatchAppInstalled = session.isWatchAppInstalled
            #endif
        }
    }

    func sessionReachabilityDidChange(_ session: WCSession) {
        DispatchQueue.main.async {
            self.isReachable = session.isReachable
        }
    }

    // Receive immediate messages
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handleReceivedData(message)
    }

    // Receive application context updates
    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        handleReceivedData(applicationContext)
    }

    private func handleReceivedData(_ dict: [String: Any]) {
        guard let data = dict["rtaData"] as? Data,
              let decoded = try? JSONDecoder().decode(WatchData.self, from: data) else {
            return
        }

        DispatchQueue.main.async {
            self.latestData = decoded
        }
    }

    // Required for iOS
    #if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif
}
