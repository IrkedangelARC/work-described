//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// The STATUS group's expanded view (2026-09-19): every health chip with
/// its name, state and the line behind it; the last error and what it means
/// for the show; the log's tail. Read-only: the fixes live where the
/// problems are (System Settings for the clicker, the OUTPUTS group, the SOURCES window).
struct StatusWindowView: View {
    @Environment(HealthMonitor.self) private var health

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            ScrollView(.vertical) {
                VStack(spacing: ARCTheme.paddingSmall) {
                    group("Outputs", tint: ARCTheme.secGreen, ids: ["pgm", "mon", "sdi"])
                    group("Sources and input", tint: ARCTheme.secBlue, ids: ["ppt", "zoom", "clk", "ptr"])
                    machine
                    lastError
                    log
                }
                .padding(ARCTheme.paddingMedium)
            }
        }
        .frame(minWidth: 720, minHeight: 560)
        .background(ARCTheme.background)
    }

    private func group(_ title: String, tint: Color, ids: [String]) -> some View {
        VStack(spacing: 6) {
            ForEach(ids, id: \.self) { id in
                if let chip = health.chips.first(where: { $0.id == id }) { row(chip) }
            }
        }
        .padding(ARCTheme.modulePad)
        .arcModule(title: title, tint: tint)
    }

    private var machine: some View {
        VStack(spacing: 6) {
            if let disk = health.chips.first(where: { $0.id == "disk" }) { row(disk) }
            row(HealthMonitor.Chip(id: "lag", label: "LAG", level: HealthMonitor.lagLevel(ms: health.mainThreadLagMs),
                                   detail: "main thread late by \(health.mainThreadLagMs) ms now, worst \(health.maxLagMs) ms this run",
                                   help: HealthMonitor.about["lag"] ?? "", name: "MAIN THREAD", state: "\(health.mainThreadLagMs) MS"))
            row(HealthMonitor.Chip(id: "up", label: "UP", level: .ok, detail: "running \(Self.uptime(health.uptime))", name: "UPTIME", state: Self.uptime(health.uptime)))
        }
        .padding(ARCTheme.modulePad)
        .arcModule(title: "This Mac", tint: ARCTheme.line)
    }

    private var lastError: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let e = ShowLog.lastError {
                let age = Int(Date().timeIntervalSince(e.at))
                Text(e.text).font(ARCTheme.mono(12, .bold)).foregroundStyle(ARCTheme.liveRed).textSelection(.enabled)
                Text(age < 120 ? "\(age) s ago" : e.at.formatted(date: .omitted, time: .standard)).font(ARCTheme.mono(11, .bold)).foregroundStyle(ARCTheme.text1)
                Text(HealthMonitor.meaning(of: e.text)).font(ARCTheme.caption).foregroundStyle(ARCTheme.textPrimary)
            } else {
                Text("No errors this run.").font(ARCTheme.caption).foregroundStyle(ARCTheme.text2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(ARCTheme.modulePad)
        .arcModule(title: "Last error", tint: ShowLog.lastError == nil ? ARCTheme.line : ARCTheme.arcRed)
    }

    private var log: some View {
        ScrollView(.vertical) {
            Text(ShowLog.tail(40).joined(separator: "\n"))
                .font(.system(size: 11, weight: .regular, design: .monospaced))
                .foregroundStyle(ARCTheme.textPrimary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 180)
        .padding(ARCTheme.modulePad)
        .arcModule(title: "Log, last 40 lines", tint: ARCTheme.line, badge: ARCBandBadge(text: ShowLog.url.lastPathComponent.uppercased(), fill: ARCTheme.text0))
    }

    private func row(_ chip: HealthMonitor.Chip) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle().fill(color(chip.level)).frame(width: 8, height: 8).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            Text(chip.name).font(ARCTheme.mono(11, .heavy)).foregroundStyle(ARCTheme.text1).frame(width: 110, alignment: .leading)
            Text(chip.state).font(ARCTheme.mono(12, .heavy)).foregroundStyle(chip.level == .off ? ARCTheme.text1 : (chip.level == .ok ? ARCTheme.textPrimary : color(chip.level)))
                .frame(width: 110, alignment: .leading).lineLimit(1)
            Text(chip.detail).font(ARCTheme.caption).foregroundStyle(ARCTheme.textPrimary).lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .help(chip.help.isEmpty ? chip.detail : chip.help)
    }

    private func color(_ level: HealthMonitor.Level) -> Color {
        switch level {
        case .ok: ARCTheme.readyGreen
        case .warn: ARCTheme.warn
        case .bad: ARCTheme.liveRed
        case .off: ARCTheme.text2
        }
    }

    private static func uptime(_ s: TimeInterval) -> String {
        let t = Int(s); let h = t / 3600, m = (t % 3600) / 60
        return h > 0 ? "\(h) H \(m) MIN" : "\(m) MIN"
    }
}
