//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Mac-side popover showing connected iPad clients and server info.
struct ServerStatusView: View {
    @Environment(HTTPRemoteServer.self) private var server

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Remote Displays", systemImage: "ipad.and.arrow.forward")
                .font(.headline)

            if server.isRunning {
                HStack {
                    Image(systemName: "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                    Text(verbatim: "Server running on port \(String(server.port))")
                        .font(.subheadline)
                }

                let count = server.connectedDisplayCount
                HStack {
                    Image(systemName: "ipad.landscape")
                        .foregroundStyle(count > 0 ? ARCTheme.accent : .secondary)
                    Text("\(count) iPad\(count == 1 ? "" : "s") connected")
                        .font(.subheadline)
                        .foregroundStyle(count > 0 ? .primary : .secondary)
                }
            } else {
                HStack {
                    Image(systemName: "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.red)
                    Text("Server stopped")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Text("Start the HTTP server to allow iPad connections.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .frame(minWidth: 250)
    }
}
