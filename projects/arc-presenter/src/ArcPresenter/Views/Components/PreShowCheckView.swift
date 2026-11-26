//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// PRE-SHOW CHECK in THIS MAC on the load screen: the button, and the PASS/FAIL list under the tiles.
struct PreShowCheckButton: View {
    @Environment(PreShowCheck.self) private var check
    @State private var hover = false

    var body: some View {
        Button {
            Task { await check.run() }
        } label: {
            HStack(spacing: 8) {
                if check.isRunning {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "checklist").font(.system(size: 14, weight: .bold))
                }
                Text(check.isRunning ? "CHECKING…" : "PRE-SHOW CHECK")
                    .font(ARCTheme.mono(13, .heavy)).tracking(1).lineLimit(1)
                Spacer(minLength: 0)
            }
            .foregroundStyle(ARCTheme.ink)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity).frame(height: 42)
            .background(hover ? ARCTheme.secGreen.opacity(0.88) : ARCTheme.secGreen)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .disabled(check.isRunning)
        .help("Permissions, the saved show's displays and SDI device, every deck and clip, disk space, the control API. Result goes to the show log.")
    }
}

/// The last run's result: the summary, then the flagged rows and the ones worth seeing when they pass.
struct PreShowResults: View {
    @Environment(PreShowCheck.self) private var check

    private var shown: [PreShowCheck.Row] {
        check.rows.filter { !$0.ok || $0.id.hasPrefix("deck.") || $0.id.hasPrefix("display.") || $0.id == "sdi" }
    }

    var body: some View {
        if check.lastRun != nil {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Text("PRE-SHOW CHECK")
                        .font(ARCTheme.mono(10, .heavy)).tracking(1)
                        .foregroundStyle(ARCTheme.textTertiary)
                    Text(check.summary)
                        .font(ARCTheme.mono(12, .heavy))
                        .foregroundStyle(check.passed ? (check.rows.allSatisfy(\.ok) ? ARCTheme.readyGreen : ARCTheme.warn) : ARCTheme.liveRed)
                    Spacer(minLength: 0)
                    if let t = check.lastRun {
                        Text(t.formatted(date: .omitted, time: .standard))
                            .font(ARCTheme.mono(11, .bold)).foregroundStyle(ARCTheme.textTertiary).monospacedDigit()
                    }
                }
                .padding(.vertical, 6)
                if !shown.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(shown) { r in
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Circle().fill(r.ok ? ARCTheme.readyGreen : (r.required ? ARCTheme.liveRed : ARCTheme.warn))
                                        .frame(width: 8, height: 8)
                                    Text(r.label).font(ARCTheme.mono(11, .heavy)).foregroundStyle(ARCTheme.textPrimary)
                                        .frame(width: 180, alignment: .leading).lineLimit(1)
                                    Text(r.detail).font(ARCTheme.mono(11, .regular))
                                        .foregroundStyle(r.ok ? ARCTheme.textSecondary : ARCTheme.textPrimary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 150)
                }
            }
            .padding(.top, 4)
            .overlay(alignment: .top) { Rectangle().fill(ARCTheme.line).frame(height: 1) }
        }
    }
}
