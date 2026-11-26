//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import Network

/// Discovered ARC Stage Timer server on the local network
struct DiscoveredServer: Identifiable, Hashable {
    let id: String
    let name: String
    let endpoint: NWEndpoint

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: DiscoveredServer, rhs: DiscoveredServer) -> Bool {
        lhs.id == rhs.id
    }
}

/// Browses for ARC Stage Timer servers on the local network via Bonjour.
/// Used on iPad client to discover the Mac controller.
@Observable
final class BonjourBrowser {

    private(set) var servers: [DiscoveredServer] = []
    private(set) var isSearching = false

    private var browser: NWBrowser?
    private var onFirstServer: ((DiscoveredServer) -> Void)?
    private let queue = DispatchQueue(label: "com.example.arc.bonjour.browser", qos: .userInitiated)

    func startBrowsing(onFirstServer: ((DiscoveredServer) -> Void)? = nil) {
        guard browser == nil else { return }
        self.onFirstServer = onFirstServer

        let descriptor = NWBrowser.Descriptor.bonjour(type: "_arcstage._tcp", domain: nil)
        let params = NWParameters()
        params.includePeerToPeer = true

        let newBrowser = NWBrowser(for: descriptor, using: params)

        newBrowser.stateUpdateHandler = { [weak self] state in
            DispatchQueue.main.async {
                switch state {
                case .ready:
                    self?.isSearching = true
                case .failed, .cancelled:
                    self?.isSearching = false
                default:
                    break
                }
            }
        }

        newBrowser.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async {
                self?.handleResults(results)
            }
        }

        newBrowser.start(queue: queue)
        browser = newBrowser
    }

    func stopBrowsing() {
        browser?.cancel()
        browser = nil
        isSearching = false
        servers = []
        onFirstServer = nil
    }

    // MARK: - Private

    private func handleResults(_ results: Set<NWBrowser.Result>) {
        let previous = servers
        servers = results.compactMap { result in
            switch result.endpoint {
            case .service(let name, let type, let domain, _):
                let id = "\(name).\(type).\(domain)"
                return DiscoveredServer(id: id, name: name, endpoint: result.endpoint)
            default:
                return nil
            }
        }

        // Auto-connect to first discovered server
        if previous.isEmpty, let first = servers.first, let callback = onFirstServer {
            callback(first)
            onFirstServer = nil
        }
    }
}
