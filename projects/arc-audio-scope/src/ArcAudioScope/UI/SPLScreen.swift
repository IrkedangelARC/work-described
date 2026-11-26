//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import ScopeKit
import SwiftUI
import UniformTypeIdentifiers

private func number(_ v: Double, digits: Int = 1) -> String {
    v.isFinite ? String(format: "%.\(digits)f", v) : "--.-"
}

/// SPL layout: sound level, input health, interface and calibration. The header is RootScreen's.
struct SPLScreen: View {
    @EnvironmentObject private var model: MeterModel

    var body: some View {
        // Two columns, so the page fits the smallest window: the level takes whatever height is
        // left on the left, and everything on the right has a fixed height.
        HStack(alignment: .top, spacing: ARCTheme.paddingSmall) {
            VStack(spacing: ARCTheme.paddingSmall) {
                LevelModule()
                InputsModule().fixedSize(horizontal: false, vertical: true)
                DeviceModule().fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: ARCTheme.paddingSmall) {
                StatsModule()
                SettingsModule()
                CalibrationModule()
                Spacer(minLength: 0)
            }
            .frame(width: 440)
        }
    }
}

// MARK: level

private struct LevelModule: View {
    @EnvironmentObject private var model: MeterModel

    var body: some View {
        let mic = model.snapshot.inputs[min(model.micChannel, model.snapshot.inputs.count - 1)]
        let dead = model.mode == .none || mic.state == .dead
        let calibrated = model.calibration != nil
        VStack(spacing: 4) {
            Text(dead ? "--.-" : number(model.displayLevel))
                .font(ARCTheme.mono(150))
                .monospacedDigit()
                .minimumScaleFactor(0.3)
                .lineLimit(1)
                .foregroundStyle(mic.state == .clipping ? ARCTheme.arcRed : ARCTheme.text0)
            Text(calibrated ? "dB SPL  \(model.weighting.rawValue)  \(model.response.rawValue)"
                            : "dBFS  \(model.weighting.rawValue)  \(model.response.rawValue)  NOT CALIBRATED")
                .font(ARCTheme.mono(17))
                .foregroundStyle(calibrated ? ARCTheme.text1 : ARCTheme.warn)
            if dead && model.mode != .none {
                Text("MIC INPUT \(model.micChannel + 1) IS DEAD: NO SIGNAL AT ALL. CHECK THE CABLE AND 48V.")
                    .font(ARCTheme.caption).foregroundStyle(ARCTheme.arcRed)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .arcModule(title: "LEVEL  MIC INPUT \(model.micChannel + 1)", tint: ARCTheme.secGreen)
    }
}

private struct StatsModule: View {
    @EnvironmentObject private var model: MeterModel

    var body: some View {
        let l = model.snapshot.level
        let w = model.weighting.rawValue
        VStack(spacing: 6) {
            row("L\(w)eq", number(model.display(l.leq)))
            row("L\(w)Fmax", number(model.display(l.maxFast)))
            row("LCpeak", number(model.display(l.peakC)))
            HStack {
                Text("TIME").font(ARCTheme.mono(15)).foregroundStyle(ARCTheme.text1)
                ARCActionButton("RESET", fill: ARCTheme.appGrey, size: 13) { model.resetLevels() }
                Spacer()
                Text(clock(l.seconds)).font(ARCTheme.mono(24)).monospacedDigit().foregroundStyle(ARCTheme.text0)
            }
        }
        .arcModule(title: "SINCE RESET", tint: ARCTheme.secGreen)
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack {
            Text(name).font(ARCTheme.mono(15)).foregroundStyle(ARCTheme.text1)
            Spacer()
            Text(value).font(ARCTheme.mono(24)).monospacedDigit().foregroundStyle(ARCTheme.text0)
        }
    }

    private func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}

private struct SettingsModule: View {
    @EnvironmentObject private var model: MeterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ARCBank(Weighting.allCases.map { w in
                ARCBankItem(w.rawValue, on: model.weighting == w) { model.set(weighting: w) }
            })
            ARCBank(TimeResponse.allCases.map { r in
                ARCBankItem(r.rawValue, on: model.response == r) { model.set(response: r) }
            })
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .arcModule(title: "WEIGHTING AND RESPONSE", tint: ARCTheme.secBlue)
    }
}

// MARK: inputs

private struct InputsModule: View {
    @EnvironmentObject private var model: MeterModel

    var body: some View {
        let count = model.mode == .dual ? 2 : (model.mode == .single ? 1 : 0)
        VStack(spacing: 8) {
            if count == 0 {
                Text("NO INPUT RUNNING").font(ARCTheme.caption).foregroundStyle(ARCTheme.text2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(0..<count, id: \.self) { c in
                InputStrip(index: c, role: c == model.micChannel ? "MIC" : "REF", status: model.snapshot.inputs[c])
            }
            if model.snapshot.inputsIdentical {
                Text("INPUTS 1 AND 2 CARRY THE SAME SIGNAL. THE INTERFACE IS MIXING THEM. ON THE AMS-24 SET THE MODE SWITCH TO MUSIC. NO TRANSFER FUNCTION UNTIL THEY ARE SEPARATE.")
                    .font(ARCTheme.caption).foregroundStyle(ARCTheme.ink)
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(ARCTheme.warn, in: RoundedRectangle(cornerRadius: 3))
            }
            HStack {
                if model.snapshot.dropped > 0 {
                    Text("DROPPED \(model.snapshot.dropped) SAMPLES").font(ARCTheme.caption).foregroundStyle(ARCTheme.warn)
                }
                Spacer()
                ARCActionButton("RESET PEAKS AND CLIPS", fill: ARCTheme.appGrey, size: 13) { model.resetInputs() }
            }
        }
        .arcModule(title: "INPUTS", tint: ARCTheme.secOrange)
    }
}

/// One input: level bar from -60 to 0 dBFS with a peak-hold tick, the headroom left at the
/// loudest moment since reset, and a clip lamp. A meter with no peak hold cannot show a
/// transient that clipped (karaoke ScopeView's rule).
private struct InputStrip: View {
    let index: Int
    let role: String
    let status: InputStatus
    private let floorDB = -60.0

    var body: some View {
        HStack(spacing: ARCTheme.paddingMedium) {
            Text("\(index + 1) \(role)").font(ARCTheme.mono(15)).foregroundStyle(ARCTheme.text0).frame(width: 62, alignment: .leading)
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Rectangle().fill(ARCTheme.ink)
                    Rectangle().fill(barColor).frame(width: w * fraction(status.peakDB))
                    Rectangle().fill(ARCTheme.text0).frame(width: 2).offset(x: max(0, w * fraction(status.peakHoldDB) - 2))
                        .opacity(status.peakHoldDB.isFinite ? 1 : 0)
                    // -18 and -6 dBFS marks
                    ForEach([-18.0, -6.0], id: \.self) { mark in
                        Rectangle().fill(ARCTheme.line).frame(width: 1).offset(x: w * fraction(mark))
                    }
                }
            }
            .frame(height: 22)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            VStack(alignment: .trailing, spacing: 0) {
                Text(number(status.peakHoldDB)).font(ARCTheme.mono(17)).monospacedDigit().foregroundStyle(ARCTheme.text0)
                Text("PEAK dBFS").font(ARCTheme.mono(10)).foregroundStyle(ARCTheme.text2)
            }
            .frame(width: 84, alignment: .trailing)
            VStack(alignment: .trailing, spacing: 0) {
                Text(number(status.headroomDB)).font(ARCTheme.mono(17)).monospacedDigit()
                    .foregroundStyle(status.headroomDB < 3 ? ARCTheme.arcRed : (status.headroomDB < 10 ? ARCTheme.warn : ARCTheme.text0))
                Text("HEADROOM dB").font(ARCTheme.mono(10)).foregroundStyle(ARCTheme.text2)
            }
            .frame(width: 100, alignment: .trailing)
            Text(lampText)
                .font(ARCTheme.statusBadge)
                .foregroundStyle(status.state == .present && status.clipEvents == 0 ? ARCTheme.text1 : ARCTheme.ink)
                .frame(width: 96, height: 26)
                .background(lampColor, in: RoundedRectangle(cornerRadius: 3))
        }
    }

    private func fraction(_ db: Double) -> Double {
        guard db.isFinite else { return 0 }
        return min(1, max(0, (db - floorDB) / -floorDB))
    }
    private var barColor: Color {
        status.state == .clipping ? ARCTheme.arcRed : (status.peakDB > -6 ? ARCTheme.warn : ARCTheme.live)
    }
    private var lampText: String {
        switch status.state {
        case .clipping: return "CLIP \(status.clipEvents)"
        case .dead: return "DEAD"
        case .present: return status.clipEvents > 0 ? "CLIPPED \(status.clipEvents)" : "OK"
        }
    }
    private var lampColor: Color {
        switch status.state {
        case .clipping: return ARCTheme.arcRed
        case .dead: return ARCTheme.text2
        case .present: return status.clipEvents > 0 ? ARCTheme.warn : ARCTheme.ink
        }
    }
}

// MARK: device and calibration

private struct DeviceModule: View {
    @EnvironmentObject private var model: MeterModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("", selection: Binding(get: { model.deviceName }, set: { model.select(device: $0) })) {
                ForEach(model.devices) { d in
                    Text("\(d.name)  (\(d.inputChannels) in)").tag(d.name)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 360, alignment: .leading)
            if model.mode == .dual {
                HStack(spacing: ARCTheme.paddingMedium) {
                    Text("MIC ON").font(ARCTheme.caption).foregroundStyle(ARCTheme.text1)
                    ARCBank((0..<2).map { c in
                        ARCBankItem("INPUT \(c + 1)", on: model.micChannel == c) { model.set(micChannel: c) }
                    }, tint: ARCTheme.secOrange)
                }
                ARCModuleCaption("The other input is the console reference. Plug the console into the TRS side of the combo jack so 48V never reaches it.")
            } else if model.mode == .single {
                ARCModuleCaption("One input: level, RTA and waterfall. Transfer function needs a second input for the console reference.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .arcModule(title: "INTERFACE", tint: ARCTheme.secOrange)
    }
}

private struct CalibrationModule: View {
    @EnvironmentObject private var model: MeterModel
    @State private var matchText = ""
    @State private var note = ""
    @State private var message = ""
    @State private var picking = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let cal = model.calibration {
                Text("OFFSET \(String(format: "%+.1f", cal.offsetDB)) dB   \(label(cal.method))   \(cal.date.formatted(date: .numeric, time: .shortened))")
                    .font(ARCTheme.mono(14)).foregroundStyle(ARCTheme.text0)
                if !cal.note.isEmpty {
                    Text("GAIN NOTE  \(cal.note)").font(ARCTheme.mono(13)).foregroundStyle(ARCTheme.text1)
                }
            } else {
                Text("NOT CALIBRATED. LEVELS READ IN dBFS.").font(ARCTheme.mono(14)).foregroundStyle(ARCTheme.warn)
            }
            HStack(spacing: ARCTheme.paddingSmall) {
                ARCActionButton("CAL 94", fill: ARCTheme.secBlue, size: 13) { calibrate(94, .calibrator94) }
                ARCActionButton("CAL 114", fill: ARCTheme.secBlue, size: 13) { calibrate(114, .calibrator114) }
                Spacer()
                ARCActionButton("CLEAR", enabled: model.calibration != nil, fill: ARCTheme.appGrey, size: 13) {
                    model.clearCalibration(); message = ""
                }
            }
            HStack(spacing: ARCTheme.paddingSmall) {
                TextField("dB on another meter", text: $matchText)
                    .textFieldStyle(.roundedBorder)
                ARCActionButton("MATCH", fill: ARCTheme.secBlue, size: 13) {
                    if let v = Double(matchText), (20...150).contains(v) { calibrate(v, .matched) } else { message = "Enter the level another meter shows, 20 to 150 dB." }
                }
            }
            TextField("Gain knob position (the calibration is only true at this gain)", text: $note)
                .textFieldStyle(.roundedBorder)
            if !message.isEmpty {
                Text(message).font(ARCTheme.mono(13)).foregroundStyle(ARCTheme.warn)
            }
            HStack(spacing: ARCTheme.paddingSmall) {
                Text(model.show.micCorrection.map { "MIC FILE  \($0.name)" } ?? "NO MIC FILE")
                    .font(ARCTheme.mono(13)).foregroundStyle(model.show.micCorrection != nil ? ARCTheme.text0 : ARCTheme.text1)
                    .lineLimit(1)
                Spacer()
                ARCActionButton("LOAD", fill: ARCTheme.secBlue, size: 13) { picking = true }
                ARCActionButton("REMOVE", enabled: model.show.micCorrection != nil, fill: ARCTheme.appGrey, size: 13) { model.clearMicCorrection() }
            }
            .fileImporter(isPresented: $picking, allowedContentTypes: [.data, .text]) { result in
                if case .success(let url) = result { message = model.loadMicCorrection(from: url) ?? "" }
            }
            ARCModuleCaption("CAL 94 or CAL 114 with the calibrator on the mic and the level holding still. MATCH to what a trusted meter reads on the same sound. The mic file is the microphone's response curve (.frd, .txt, .csv) and corrects the bars, the waterfall and the level.")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .arcModule(title: "CALIBRATION  MIC INPUT \(model.micChannel + 1)", tint: ARCTheme.secCrimson)
    }

    private func calibrate(_ target: Double, _ method: Calibration.Method) {
        message = model.calibrate(to: target, method: method, note: note) ? "" : "The mic input is silent. Nothing to calibrate against."
    }

    private func label(_ m: Calibration.Method) -> String {
        switch m {
        case .calibrator94: return "CALIBRATOR 94"
        case .calibrator114: return "CALIBRATOR 114"
        case .matched: return "MATCHED"
        }
    }
}
