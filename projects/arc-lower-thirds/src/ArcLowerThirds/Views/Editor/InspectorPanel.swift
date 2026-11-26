//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Right-side property inspector for the selected graphic.
/// Sections: Template, Text, Typography, Colors, Layout, Animation, Logo, Notes.
struct InspectorPanel: View {
    @Bindable var graphic: Graphic
    let defaultTemplate: GraphicTemplate
    var scrollToElement: CanvasElement? = nil
    @Environment(PresetManager.self) private var presetManager
    @Environment(GraphicsEngine.self) private var engine
    @State private var showSavePreset = false
    @State private var presetName = ""
    @State private var highlightedSection: String?
    @State private var showPresetImporter = false
    @State private var showPresetBrowser = false

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // STYLE CLIPBOARD
                HStack(spacing: 8) {
                    Button {
                        engine.copyStyle(from: graphic)
                    } label: {
                        Label("Copy Style", systemImage: "paintbrush")
                            .font(.system(size: 11))
                    }
                    .controlSize(.small)

                    Button {
                        engine.pasteStyle(to: graphic)
                    } label: {
                        Label("Paste Style", systemImage: "paintbrush.fill")
                            .font(.system(size: 11))
                    }
                    .controlSize(.small)
                    .disabled(!engine.hasClipboardStyle)
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)

                // PRESETS
                presetSection

                Divider().background(ARCTheme.divider)

                // GRAPHIC TYPE
                inspectorSection("TYPE", icon: "square.stack.3d.up") {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: graphic.graphicType.sfSymbol)
                                .foregroundStyle(ARCTheme.accent)
                            Text(graphic.graphicType.displayName)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(ARCTheme.textPrimary)
                            Spacer()
                        }

                        // Layer override picker
                        HStack(spacing: 6) {
                            Text("Layer")
                                .font(.system(size: 11))
                                .foregroundStyle(ARCTheme.textSecondary)
                                .frame(width: 42, alignment: .leading)
                            Picker("", selection: Binding(
                                get: { graphic.layer ?? graphic.graphicType.defaultLayer },
                                set: { graphic.layer = ($0 == graphic.graphicType.defaultLayer) ? nil : $0 }
                            )) {
                                ForEach(GraphicLayer.allCases) { layer in
                                    Text(layer.displayName).tag(layer)
                                }
                            }
                            .controlSize(.small)
                            .labelsHidden()
                        }

                        if graphic.layer != nil {
                            Text("Overriding default (\(graphic.graphicType.defaultLayer.displayName))")
                                .font(.system(size: 10))
                                .foregroundStyle(ARCTheme.textTertiary)
                        }
                    }
                }

                Divider().background(ARCTheme.divider)

                // TYPE-SPECIFIC CONTROLS
                if graphic.graphicType == .ticker {
                    tickerControls
                    Divider().background(ARCTheme.divider)
                }
                if graphic.graphicType == .clock {
                    clockControls
                    Divider().background(ARCTheme.divider)
                }
                if graphic.graphicType == .logoBug {
                    bugCornerControls
                    Divider().background(ARCTheme.divider)
                }

                // TEMPLATE (lower thirds only)
                if graphic.graphicType == .lowerThird {
                    inspectorSection("TEMPLATE", icon: "rectangle.stack") {
                        TemplatePickerGrid(
                            selected: $graphic.template,
                            accentColor: graphic.accentColor
                        )
                    }

                    Divider().background(ARCTheme.divider)
                }

                // TEXT
                inspectorSection("TEXT", icon: "textformat") {
                    VStack(spacing: 10) {
                        InspectorTextField(label: "Name / Line 1", text: $graphic.line1)

                        InspectorTextField(label: "Title / Line 2", text: Binding(
                            get: { graphic.line2 ?? "" },
                            set: { graphic.line2 = $0.isEmpty ? nil : $0 }
                        ))

                        InspectorTextField(label: "Organization / Line 3", text: Binding(
                            get: { graphic.line3 ?? "" },
                            set: { graphic.line3 = $0.isEmpty ? nil : $0 }
                        ))
                    }
                }

                Divider().background(ARCTheme.divider)

                // TYPOGRAPHY
                inspectorSection("TYPOGRAPHY", icon: "textformat.size") {
                    VStack(alignment: .leading, spacing: 10) {
                        // Font family
                        FontFamilyPicker(selection: Binding(
                            get: { graphic.fontFamily ?? "" },
                            set: { graphic.fontFamily = $0.isEmpty ? nil : $0 }
                        ))

                        // Line 1 — size + weight
                        lineTypographyRow(
                            label: "Line 1",
                            size: $graphic.line1FontSize,
                            sizeRange: 24...96,
                            weight: $graphic.line1Weight
                        )
                        // Line 2 — size + weight
                        lineTypographyRow(
                            label: "Line 2",
                            size: $graphic.line2FontSize,
                            sizeRange: 16...72,
                            weight: $graphic.line2Weight
                        )
                        // Line 3 — size + weight
                        lineTypographyRow(
                            label: "Line 3",
                            size: $graphic.line3FontSize,
                            sizeRange: 12...56,
                            weight: $graphic.line3Weight
                        )

                        // Line spacing
                        InspectorSlider(
                            label: "Spacing",
                            value: $graphic.lineSpacing,
                            range: 0...20,
                            step: 1,
                            unit: "pt"
                        )

                        // Text shadow
                        Toggle(isOn: $graphic.shadowEnabled) {
                            Text("Text Shadow")
                                .font(.system(size: 11))
                                .foregroundStyle(ARCTheme.textSecondary)
                        }
                        .toggleStyle(.checkbox)
                        .controlSize(.small)

                        if graphic.shadowEnabled {
                            InspectorSlider(
                                label: "Radius",
                                value: $graphic.shadowRadius,
                                range: 1...20,
                                step: 0.5,
                                unit: "px"
                            )
                            InspectorSlider(
                                label: "Opacity",
                                value: $graphic.shadowOpacity,
                                range: 0...1,
                                step: 0.05,
                                unit: "%",
                                isPercent: true
                            )
                        }
                    }
                }

                Divider().background(ARCTheme.divider)

                // COLORS
                inspectorSection("COLORS", icon: "paintbrush") {
                    VStack(alignment: .leading, spacing: 10) {
                        // Accent color
                        Text("Accent")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(ARCTheme.textTertiary)
                        ColorControls(hex: $graphic.accentColor)

                        Divider().background(ARCTheme.divider)

                        // Per-line colors
                        Text("Text Colors")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(ARCTheme.textTertiary)

                        lineColorRow(label: "Line 1", color: $graphic.line1Color, opacity: $graphic.line1Opacity)
                        lineColorRow(label: "Line 2", color: $graphic.line2Color, opacity: $graphic.line2Opacity)
                        lineColorRow(label: "Line 3", color: $graphic.line3Color, opacity: $graphic.line3Opacity)

                        Divider().background(ARCTheme.divider)

                        // Accent background opacity
                        InspectorSlider(
                            label: "Accent BG",
                            value: $graphic.backgroundOpacity,
                            range: 0...1,
                            step: 0.05,
                            unit: "%",
                            isPercent: true
                        )
                    }
                }

                Divider().background(ARCTheme.divider)

                // BACKGROUNDS
                inspectorSection("BACKGROUNDS", icon: "rectangle.fill") {
                    VStack(alignment: .leading, spacing: 10) {
                        // Title section background
                        Text("Title Section")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(ARCTheme.textTertiary)

                        HStack(spacing: 6) {
                            Text("Color")
                                .font(.system(size: 11))
                                .foregroundStyle(ARCTheme.textSecondary)
                                .frame(width: 42, alignment: .leading)

                            let titleHex = graphic.titleBgColor ?? ""
                            let titleDisplayColor = titleHex.isEmpty ? Color(red: 0.13, green: 0.13, blue: 0.13) : ARCTheme.color(from: titleHex)

                            RoundedRectangle(cornerRadius: 3)
                                .fill(titleDisplayColor.opacity(graphic.titleBgOpacity))
                                .frame(width: 20, height: 20)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 3)
                                        .stroke(ARCTheme.divider, lineWidth: 1)
                                )

                            TextField("#222222", text: Binding(
                                get: { graphic.titleBgColor ?? "" },
                                set: { graphic.titleBgColor = $0.isEmpty ? nil : $0 }
                            ))
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                            .controlSize(.small)
                            .frame(maxWidth: 90)
                        }

                        InspectorSlider(
                            label: "Opacity",
                            value: $graphic.titleBgOpacity,
                            range: 0...1,
                            step: 0.05,
                            unit: "%",
                            isPercent: true
                        )

                        // Quick presets for title bg
                        HStack(spacing: 4) {
                            Text("Quick")
                                .font(.system(size: 10))
                                .foregroundStyle(ARCTheme.textTertiary)
                                .frame(width: 42, alignment: .leading)
                            ForEach(["#222222", "#333333", "#444444", "#1A1A2E", "#0D0D0D"], id: \.self) { hex in
                                Button {
                                    graphic.titleBgColor = hex
                                } label: {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(ARCTheme.color(from: hex))
                                        .frame(width: 22, height: 22)
                                        .overlay(
                                            RoundedRectangle(cornerRadius: 3)
                                                .stroke(graphic.titleBgColor == hex ? ARCTheme.accent : ARCTheme.divider, lineWidth: graphic.titleBgColor == hex ? 2 : 1)
                                        )
                                }
                                .buttonStyle(.plain)
                            }
                            // Match accent button
                            Button {
                                graphic.titleBgColor = graphic.accentColor
                                graphic.titleBgOpacity = 0.7
                            } label: {
                                ZStack {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(ARCTheme.color(from: graphic.accentColor).opacity(0.7))
                                        .frame(width: 22, height: 22)
                                    Text("A")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white)
                                }
                            }
                            .buttonStyle(.plain)
                            .help("Use accent color")
                        }

                        Divider().background(ARCTheme.divider)

                        // Hard Edge (ATEM luma key optimization)
                        Toggle(isOn: $graphic.hardEdge) {
                            Text("Hard Edge")
                                .font(.system(size: 11))
                                .foregroundStyle(ARCTheme.textSecondary)
                        }
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .help("Disable gradients for clean ATEM luma key")

                        if graphic.hardEdge {
                            Text("Gradients disabled — solid edges for ATEM luma key")
                                .font(.system(size: 10))
                                .foregroundStyle(ARCTheme.textTertiary)
                        }

                        // Gradient
                        Toggle(isOn: $graphic.gradientEnabled) {
                            Text("Gradient")
                                .font(.system(size: 11))
                                .foregroundStyle(ARCTheme.textSecondary)
                        }
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .disabled(graphic.hardEdge)

                        if graphic.gradientEnabled {
                            HStack(spacing: 6) {
                                Text("End")
                                    .font(.system(size: 11))
                                    .foregroundStyle(ARCTheme.textSecondary)
                                    .frame(width: 42, alignment: .leading)

                                let gradHex = graphic.gradientEndColor ?? ""
                                let gradColor = gradHex.isEmpty ? Color.clear : ARCTheme.color(from: gradHex)

                                RoundedRectangle(cornerRadius: 3)
                                    .fill(gradColor)
                                    .frame(width: 20, height: 20)
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 3)
                                            .stroke(ARCTheme.divider, lineWidth: 1)
                                    )

                                TextField("transparent", text: Binding(
                                    get: { graphic.gradientEndColor ?? "" },
                                    set: { graphic.gradientEndColor = $0.isEmpty ? nil : $0 }
                                ))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 11, design: .monospaced))
                                .controlSize(.small)
                                .frame(maxWidth: 90)
                            }

                            Text("Leave empty for fade-to-transparent")
                                .font(.system(size: 10))
                                .foregroundStyle(ARCTheme.textTertiary)
                        }
                    }
                }

                // BACKGROUND IMAGE
                Divider().background(ARCTheme.divider)
                backgroundImageSection

                // OVERLAY IMAGE
                Divider().background(ARCTheme.divider)
                overlayImageSection

                // CUSTOM TEXT POSITION (custom template only)
                if graphic.template == .custom {
                    Divider().background(ARCTheme.divider)
                    customTextPositionSection
                }

                // ELEMENT SIZE (lower thirds only)
                if graphic.graphicType == .lowerThird {
                Divider().background(ARCTheme.divider)

                inspectorSection("ELEMENT SIZE", icon: "ruler") {
                    VStack(alignment: .leading, spacing: 10) {
                        InspectorSlider(
                            label: "Accent Bar",
                            value: $graphic.accentBarSize,
                            range: 0...20,
                            step: 1,
                            unit: "pt"
                        )

                        Text("Name Block")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(ARCTheme.textTertiary)

                        InspectorSlider(
                            label: "Pad H",
                            value: $graphic.namePaddingH,
                            range: 4...60,
                            step: 2,
                            unit: "pt"
                        )
                        InspectorSlider(
                            label: "Pad V",
                            value: $graphic.namePaddingV,
                            range: 2...40,
                            step: 2,
                            unit: "pt"
                        )

                        Text("Title Block")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(ARCTheme.textTertiary)

                        InspectorSlider(
                            label: "Pad H",
                            value: $graphic.titlePaddingH,
                            range: 4...60,
                            step: 2,
                            unit: "pt"
                        )
                        InspectorSlider(
                            label: "Pad V",
                            value: $graphic.titlePaddingV,
                            range: 2...40,
                            step: 2,
                            unit: "pt"
                        )

                        InspectorSlider(
                            label: "Gap",
                            value: $graphic.elementGap,
                            range: 0...30,
                            step: 1,
                            unit: "pt"
                        )
                    }
                }

                Divider().background(ARCTheme.divider)

                // LAYOUT (lower thirds and full titles)
                inspectorSection("LAYOUT", icon: "square.resize") {
                    VStack(alignment: .leading, spacing: 10) {
                        if graphic.graphicType == .lowerThird {
                            // Position
                            Picker("", selection: $graphic.positionPreset) {
                                ForEach(PositionPreset.allCases) { preset in
                                    Text(preset.displayName).tag(preset)
                                }
                            }
                            .pickerStyle(.segmented)
                        }

                        InspectorSlider(
                            label: "Bottom",
                            value: $graphic.bottomOffset,
                            range: 0...200,
                            step: 5,
                            unit: "pt"
                        )

                        InspectorSlider(
                            label: "Margin",
                            value: $graphic.horizontalMargin,
                            range: 0...200,
                            step: 5,
                            unit: "pt"
                        )

                        if graphic.graphicType == .lowerThird {
                            InspectorSlider(
                                label: "Max Width",
                                value: $graphic.maxWidthFraction,
                                range: 0.3...1.0,
                                step: 0.05,
                                unit: "%",
                                isPercent: true
                            )
                        }

                        InspectorSlider(
                            label: "Corners",
                            value: $graphic.cornerRadius,
                            range: 0...24,
                            step: 1,
                            unit: "pt"
                        )
                    }
                }
                } // end lower-third-only section

                Divider().background(ARCTheme.divider)

                // ANIMATION
                inspectorSection("ANIMATION", icon: "wand.and.stars") {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("Preset", selection: $graphic.animationPreset) {
                            ForEach(AnimationPreset.allCases) { preset in
                                Label(preset.displayName, systemImage: preset.sfSymbol)
                                    .tag(preset)
                            }
                        }
                        .labelsHidden()

                        // Duration overrides
                        Text("Duration Override")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(ARCTheme.textTertiary)

                        InspectorSlider(
                            label: "In",
                            value: $graphic.animationInDuration,
                            range: 0...2,
                            step: 0.05,
                            unit: "s",
                            zeroLabel: "default"
                        )

                        InspectorSlider(
                            label: "Out",
                            value: $graphic.animationOutDuration,
                            range: 0...2,
                            step: 0.05,
                            unit: "s",
                            zeroLabel: "default"
                        )
                    }
                }

                Divider().background(ARCTheme.divider)

                // LOGO
                inspectorSection("LOGO", icon: "photo") {
                    VStack(alignment: .leading, spacing: 8) {
                        if let logoData = graphic.logoData, let nsImage = NSImage(data: logoData) {
                            HStack {
                                Image(nsImage: nsImage)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(height: 40)
                                    .background(Color.black.opacity(0.3))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))

                                Spacer()

                                Button("Remove") {
                                    graphic.logoData = nil
                                }
                                .controlSize(.small)
                                .tint(.red)
                            }

                            Picker("Position", selection: $graphic.logoPosition) {
                                ForEach(LogoPosition.allCases) { pos in
                                    Text(pos.displayName).tag(pos)
                                }
                            }
                            .pickerStyle(.segmented)
                            .controlSize(.small)

                            InspectorSlider(
                                label: "Size",
                                value: $graphic.logoSize,
                                range: 16...128,
                                step: 4,
                                unit: "pt"
                            )

                            InspectorSlider(
                                label: "Offset X",
                                value: $graphic.logoOffsetX,
                                range: -200...200,
                                step: 2,
                                unit: "pt"
                            )

                            InspectorSlider(
                                label: "Offset Y",
                                value: $graphic.logoOffsetY,
                                range: -200...200,
                                step: 2,
                                unit: "pt"
                            )
                        } else {
                            Button("Choose Image...") {
                                importLogo()
                            }
                            .controlSize(.small)
                        }
                    }
                }

                Divider().background(ARCTheme.divider)

                // NOTES
                inspectorSection("NOTES", icon: "note.text") {
                    TextEditor(text: Binding(
                        get: { graphic.notes ?? "" },
                        set: { graphic.notes = $0.isEmpty ? nil : $0 }
                    ))
                    .font(.system(size: 12))
                    .frame(minHeight: 60, maxHeight: 120)
                    .scrollContentBackground(.hidden)
                    .background(ARCTheme.background)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(ARCTheme.divider, lineWidth: 1)
                    )
                }
            }
            .padding(12)
        }
        .onChange(of: scrollToElement) { _, element in
            guard let element else {
                highlightedSection = nil
                return
            }
            let sectionID = element.inspectorSectionID
            withAnimation(.easeInOut(duration: 0.3)) {
                proxy.scrollTo(sectionID, anchor: .top)
            }
            // Flash highlight
            highlightedSection = sectionID
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                withAnimation { highlightedSection = nil }
            }
        }
        } // ScrollViewReader
        .background(ARCTheme.surface)
        .fileImporter(isPresented: $showPresetImporter, allowedContentTypes: [.json], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let data = try? Data(contentsOf: url) {
                if let presets = try? decoder.decode([DesignPreset].self, from: data) {
                    for preset in presets { presetManager.save(preset) }
                } else if let preset = try? decoder.decode(DesignPreset.self, from: data) {
                    presetManager.save(preset)
                }
            }
        }
    }

    // MARK: - Ticker Controls

    private var tickerControls: some View {
        inspectorSection("TICKER", icon: "arrow.right.circle") {
            VStack(alignment: .leading, spacing: 10) {
                InspectorSlider(
                    label: "Speed",
                    value: $graphic.tickerSpeed,
                    range: 10...300,
                    step: 5,
                    unit: "pt/s"
                )

                HStack {
                    Text("Separator")
                        .font(.system(size: 11))
                        .foregroundStyle(ARCTheme.textSecondary)
                        .frame(width: 65, alignment: .leading)
                    TextField(" /// ", text: Binding(
                        get: { graphic.tickerSeparator ?? "" },
                        set: { graphic.tickerSeparator = $0.isEmpty ? nil : $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Clock Controls

    private var clockControls: some View {
        inspectorSection("CLOCK", icon: "clock") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Format", selection: $graphic.clockFormat) {
                    Text("12-hour (1:30 PM)").tag("h:mm a")
                    Text("24-hour (13:30)").tag("HH:mm")
                    Text("12-hour short (1:30p)").tag("h:mma")
                }
                .controlSize(.small)

                Toggle(isOn: $graphic.clockShowSeconds) {
                    Text("Show Seconds")
                        .font(.system(size: 11))
                        .foregroundStyle(ARCTheme.textSecondary)
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)

                Picker("Corner", selection: $graphic.bugCorner) {
                    ForEach(BugCorner.allCases) { corner in
                        Text(corner.displayName).tag(corner)
                    }
                }
                .controlSize(.small)

                InspectorSlider(
                    label: "Margin H",
                    value: $graphic.bugMarginH,
                    range: 0...200,
                    step: 5,
                    unit: "pt"
                )
                InspectorSlider(
                    label: "Margin V",
                    value: $graphic.bugMarginV,
                    range: 0...200,
                    step: 5,
                    unit: "pt"
                )
            }
        }
    }

    // MARK: - Bug Corner Controls

    private var bugCornerControls: some View {
        inspectorSection("POSITION", icon: "arrow.up.left.and.arrow.down.right") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Corner", selection: $graphic.bugCorner) {
                    ForEach(BugCorner.allCases) { corner in
                        Text(corner.displayName).tag(corner)
                    }
                }
                .controlSize(.small)

                InspectorSlider(
                    label: "Margin H",
                    value: $graphic.bugMarginH,
                    range: 0...200,
                    step: 5,
                    unit: "pt"
                )
                InspectorSlider(
                    label: "Margin V",
                    value: $graphic.bugMarginV,
                    range: 0...200,
                    step: 5,
                    unit: "pt"
                )
            }
        }
    }

    // MARK: - Preset Section

    private var presetSection: some View {
        inspectorSection("PRESETS", icon: "square.grid.2x2") {
            VStack(alignment: .leading, spacing: 8) {
                // Browse + Save row
                HStack(spacing: 8) {
                    Button {
                        showPresetBrowser = true
                    } label: {
                        Label("Browse Presets...", systemImage: "square.grid.2x2")
                            .font(.system(size: 11))
                    }
                    .controlSize(.small)
                    .sheet(isPresented: $showPresetBrowser) {
                        PresetBrowserView(graphic: graphic)
                    }

                    Button {
                        presetName = "\(graphic.template.displayName) — \(graphic.line1)"
                        showSavePreset = true
                    } label: {
                        Label("Save as Preset...", systemImage: "plus.square")
                            .font(.system(size: 11))
                    }
                    .controlSize(.small)
                }
                .alert("Save Preset", isPresented: $showSavePreset) {
                    TextField("Preset name", text: $presetName)
                    Button("Save") {
                        let preset = DesignPreset.from(graphic, name: presetName)
                        presetManager.save(preset)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Name this design preset:")
                }

                HStack(spacing: 8) {
                    Button {
                        showPresetImporter = true
                    } label: {
                        Label("Import", systemImage: "square.and.arrow.down")
                            .font(.system(size: 11))
                    }
                    .controlSize(.small)

                    if !presetManager.presets.isEmpty {
                        Button {
                            let encoder = JSONEncoder()
                            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                            encoder.dateEncodingStrategy = .iso8601
                            guard let data = try? encoder.encode(presetManager.presets) else { return }
                            let panel = NSSavePanel()
                            panel.allowedContentTypes = [.json]
                            panel.nameFieldStringValue = "ARC_Presets.json"
                            if panel.runModal() == .OK, let url = panel.url {
                                try? data.write(to: url)
                            }
                        } label: {
                            Label("Export All", systemImage: "square.and.arrow.up")
                                .font(.system(size: 11))
                        }
                        .controlSize(.small)
                    }
                }

                // Preset list
                if presetManager.presets.isEmpty {
                    Text("No saved presets")
                        .font(.system(size: 10))
                        .foregroundStyle(ARCTheme.textTertiary)
                } else {
                    ForEach(presetManager.presets) { preset in
                        HStack(spacing: 6) {
                            Button {
                                presetManager.apply(preset, to: graphic)
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(preset.name)
                                        .font(.system(size: 11, weight: .medium))
                                        .foregroundStyle(ARCTheme.textPrimary)
                                        .lineLimit(1)
                                    Text(GraphicTemplate(rawValue: preset.template)?.displayName ?? preset.template)
                                        .font(.system(size: 9))
                                        .foregroundStyle(ARCTheme.textTertiary)
                                }
                            }
                            .buttonStyle(.plain)

                            Spacer()

                            Button {
                                presetManager.delete(preset)
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.red.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    // MARK: - Section Builder

    @ViewBuilder
    private func inspectorSection(_ title: String, icon: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10))
                    .foregroundStyle(ARCTheme.accent)
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ARCTheme.textSecondary)
            }
            content()
        }
        .padding(highlightedSection == title ? 4 : 0)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(highlightedSection == title ? ARCTheme.accent.opacity(0.1) : Color.clear)
        )
        .id(title)
    }

    // MARK: - Typography Row (size + weight for one line)

    @ViewBuilder
    private func lineTypographyRow(
        label: String,
        size: Binding<Double>,
        sizeRange: ClosedRange<Double>,
        weight: Binding<FontWeightOption>
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(.system(size: 11))
                    .foregroundStyle(ARCTheme.textSecondary)
                    .frame(width: 50, alignment: .leading)
                Slider(value: size, in: sizeRange, step: 1)
                    .controlSize(.small)
                Text("\(Int(size.wrappedValue))pt")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(ARCTheme.textTertiary)
                    .frame(width: 36, alignment: .trailing)
            }
            HStack {
                Spacer().frame(width: 50)
                Picker("", selection: weight) {
                    ForEach(FontWeightOption.allCases) { w in
                        Text(w.displayName).tag(w)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
            }
        }
    }

    // MARK: - Per-Line Color Row

    @ViewBuilder
    private func lineColorRow(label: String, color: Binding<String?>, opacity: Binding<Double>) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(ARCTheme.textSecondary)
                .frame(width: 42, alignment: .leading)

            // Color swatch + hex
            let hex = color.wrappedValue ?? ""
            let displayColor = hex.isEmpty ? Color.white : ARCTheme.color(from: hex)

            RoundedRectangle(cornerRadius: 3)
                .fill(displayColor.opacity(opacity.wrappedValue))
                .frame(width: 20, height: 20)
                .overlay(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(ARCTheme.divider, lineWidth: 1)
                )

            TextField("white", text: Binding(
                get: { color.wrappedValue ?? "" },
                set: { color.wrappedValue = $0.isEmpty ? nil : $0 }
            ))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 11, design: .monospaced))
            .controlSize(.small)
            .frame(maxWidth: 80)

            Slider(value: opacity, in: 0...1, step: 0.05)
                .controlSize(.small)
                .frame(maxWidth: 60)

            Text("\(Int(opacity.wrappedValue * 100))%")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(ARCTheme.textTertiary)
                .frame(width: 30, alignment: .trailing)
        }
    }

    // MARK: - Logo Import

    private func importLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .svg]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            if let data = try? Data(contentsOf: url) {
                graphic.logoData = data
            }
        }
    }

    // MARK: - Background Image Section

    private var backgroundImageSection: some View {
        inspectorSection("BACKGROUND IMAGE", icon: "photo.fill") {
            VStack(alignment: .leading, spacing: 8) {
                if let bgData = graphic.backgroundData, let nsImage = NSImage(data: bgData) {
                    HStack {
                        Image(nsImage: nsImage)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 40)
                            .background(Color.black.opacity(0.3))
                            .clipShape(RoundedRectangle(cornerRadius: 4))

                        Spacer()

                        Button("Remove") {
                            graphic.backgroundData = nil
                        }
                        .controlSize(.small)
                        .tint(.red)
                    }

                    Picker("Fit", selection: $graphic.backgroundFitMode) {
                        ForEach(ImageFitMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .controlSize(.small)

                    InspectorSlider(
                        label: "Scale",
                        value: $graphic.backgroundScale,
                        range: 0.5...3.0,
                        step: 0.05,
                        unit: "x"
                    )

                    InspectorSlider(
                        label: "Opacity",
                        value: $graphic.backgroundImageOpacity,
                        range: 0...1,
                        step: 0.05,
                        unit: "%",
                        isPercent: true
                    )
                } else {
                    Button("Choose Image...") {
                        importBackgroundImage()
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Overlay Image Section

    private var overlayImageSection: some View {
        inspectorSection("OVERLAY IMAGE", icon: "square.on.square") {
            VStack(alignment: .leading, spacing: 8) {
                if let ovData = graphic.overlayData, let nsImage = NSImage(data: ovData) {
                    HStack {
                        Image(nsImage: nsImage)
                            .resizable()
                            .scaledToFit()
                            .frame(height: 40)
                            .background(Color.black.opacity(0.3))
                            .clipShape(RoundedRectangle(cornerRadius: 4))

                        Spacer()

                        Button("Remove") {
                            graphic.overlayData = nil
                        }
                        .controlSize(.small)
                        .tint(.red)
                    }

                    InspectorSlider(
                        label: "Scale",
                        value: $graphic.overlayScale,
                        range: 0.1...3.0,
                        step: 0.05,
                        unit: "x"
                    )

                    InspectorSlider(
                        label: "Opacity",
                        value: $graphic.overlayOpacity,
                        range: 0...1,
                        step: 0.05,
                        unit: "%",
                        isPercent: true
                    )

                    InspectorSlider(
                        label: "Offset X",
                        value: $graphic.overlayOffsetX,
                        range: -500...500,
                        step: 5,
                        unit: "pt"
                    )

                    InspectorSlider(
                        label: "Offset Y",
                        value: $graphic.overlayOffsetY,
                        range: -500...500,
                        step: 5,
                        unit: "pt"
                    )
                } else {
                    Button("Choose Image...") {
                        importOverlayImage()
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - Custom Text Position Section

    private var customTextPositionSection: some View {
        inspectorSection("TEXT POSITION", icon: "arrow.up.and.down.and.arrow.left.and.right") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("Align", selection: $graphic.customTextAlignment) {
                    ForEach(TextAlignmentOption.allCases) { opt in
                        Text(opt.displayName).tag(opt)
                    }
                }
                .pickerStyle(.segmented)
                .controlSize(.small)

                InspectorSlider(
                    label: "Offset X",
                    value: $graphic.customTextOffsetX,
                    range: 0...1800,
                    step: 10,
                    unit: "pt"
                )

                InspectorSlider(
                    label: "Offset Y",
                    value: $graphic.customTextOffsetY,
                    range: 0...1000,
                    step: 10,
                    unit: "pt"
                )
            }
        }
    }

    // MARK: - Background Image Import

    private func importBackgroundImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            if let data = try? Data(contentsOf: url) {
                graphic.backgroundData = data
            }
        }
    }

    // MARK: - Overlay Image Import

    private func importOverlayImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            if let data = try? Data(contentsOf: url) {
                graphic.overlayData = data
            }
        }
    }
}

// MARK: - Reusable Inspector Slider

struct InspectorSlider: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    var unit: String = ""
    var isPercent: Bool = false
    var zeroLabel: String? = nil

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(ARCTheme.textSecondary)
                .frame(width: 65, alignment: .leading)
            Slider(value: $value, in: range, step: step)
                .controlSize(.small)
            Group {
                if let zeroLabel, value == 0 {
                    Text(zeroLabel)
                } else if isPercent {
                    Text("\(Int(value * 100))%")
                } else if unit == "s" {
                    Text(String(format: "%.2f%@", value, unit))
                } else {
                    Text("\(Int(value))\(unit)")
                }
            }
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(ARCTheme.textTertiary)
            .frame(width: 48, alignment: .trailing)
        }
    }
}

// MARK: - Inspector Text Field

private struct InspectorTextField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        TextField(label, text: $text)
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 13))
            .controlSize(.small)
    }
}

// MARK: - Font Family Picker

struct FontFamilyPicker: View {
    @Binding var selection: String

    private var fontFamilies: [String] {
        let families = NSFontManager.shared.availableFontFamilies.sorted()
        return [""] + families
    }

    var body: some View {
        HStack {
            Text("Font")
                .font(.system(size: 11))
                .foregroundStyle(ARCTheme.textSecondary)
                .frame(width: 50, alignment: .leading)
            Picker("", selection: $selection) {
                Text("System Default").tag("")
                ForEach(fontFamilies.filter { !$0.isEmpty }, id: \.self) { family in
                    Text(family).tag(family)
                }
            }
            .labelsHidden()
            .controlSize(.small)
        }
    }
}
