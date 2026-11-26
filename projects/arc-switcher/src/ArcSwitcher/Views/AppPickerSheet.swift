//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Modal sheet to register running apps as switchable sources.
struct AppPickerSheet: View {
    @Environment(SwitcherEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    @State private var apps: [AppEntry] = []
    @State private var selectedApp: AppEntry?
    @State private var friendlyName = ""

    struct AppEntry: Identifiable {
        let id: pid_t
        let name: String
        let bundleId: String
        let icon: NSImage?
        let app: NSRunningApplication
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("ADD SOURCE")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .foregroundStyle(ARCTheme.textTertiary)
                    .tracking(1)
                Spacer()
                Button("Done") { dismiss() }
            }
            .padding(16)

            Divider()

            // App list
            List(apps, selection: Binding(
                get: { selectedApp?.id },
                set: { pid in
                    selectedApp = apps.first { $0.id == pid }
                    friendlyName = selectedApp?.name ?? ""
                }
            )) { app in
                HStack(spacing: 10) {
                    if let icon = app.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 24, height: 24)
                    }
                    VStack(alignment: .leading) {
                        Text(app.name)
                            .font(.system(size: 13, weight: .medium))
                        Text(app.bundleId)
                            .font(.system(size: 10))
                            .foregroundStyle(ARCTheme.textTertiary)
                    }
                }
                .tag(app.id)
            }
            .scrollContentBackground(.hidden)

            Divider()

            // Register controls
            if let selected = selectedApp {
                HStack(spacing: 8) {
                    if let icon = selected.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 20, height: 20)
                    }
                    TextField("Friendly name", text: $friendlyName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(ARCTheme.surface, in: RoundedRectangle(cornerRadius: 5))

                    Button {
                        engine.registerSource(app: selected.app, friendlyName: friendlyName)
                        refreshApps()
                        selectedApp = nil
                        friendlyName = ""
                    } label: {
                        Text("ADD")
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .foregroundStyle(ARCTheme.background)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 5)
                            .background(ARCTheme.accent, in: RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                    .disabled(friendlyName.isEmpty)
                }
                .padding(16)
            } else {
                Text("Select an application to register as a source")
                    .font(.system(size: 12))
                    .foregroundStyle(ARCTheme.textTertiary)
                    .padding(16)
            }
        }
        .frame(width: 480, height: 400)
        .background(ARCTheme.background)
        .onAppear { refreshApps() }
    }

    private func refreshApps() {
        apps = engine.availableApps().compactMap { app in
            guard let name = app.localizedName,
                  let bundleId = app.bundleIdentifier else { return nil }
            return AppEntry(
                id: app.processIdentifier,
                name: name,
                bundleId: bundleId,
                icon: app.icon,
                app: app
            )
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }
}
