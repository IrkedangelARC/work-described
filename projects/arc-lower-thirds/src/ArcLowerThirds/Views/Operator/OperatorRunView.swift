//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Main operator control surface for running lower thirds during a live show.
/// Layout: sidebar (graphic list) | main area (preview + controls + FIRE/CLEAR)
struct OperatorRunView: View {
    @Environment(GraphicsEngine.self) private var engine
    @Environment(ExternalDisplayManager.self) private var displayManager
    @Environment(HTTPRemoteServer.self) private var httpServer
    @Environment(DeckLinkOutputManager.self) private var deckLink
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            GraphicListSidebar()

            Divider()
                .background(ARCTheme.divider)

            // Main control area
            VStack(spacing: 0) {
                // HDMI status banner
                hdmiBanner

                // DeckLink Fill+Key banner (Thunderbolt/ATEM)
                deckLinkBanner

                // Layer status strip
                layerStatusStrip

                // Preview + Controls
                ScrollView {
                    VStack(spacing: ARCTheme.paddingMedium) {
                        // Preview panel
                        PreviewPanel()
                            .frame(height: 280)

                        // Program monitor (what's currently on air)
                        programMonitor

                        // Transport controls
                        transportControls

                        // FIRE / CLEAR buttons
                        fireAndClearButtons

                        // Navigation
                        navigationButtons
                    }
                    .padding(ARCTheme.paddingMedium)
                }
            }
            .frame(maxWidth: .infinity)
            .background(ARCTheme.background)
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Close") {
                    engine.unloadShow()
                    dismiss()
                }
            }
            ToolbarItem(placement: .principal) {
                headerBar
            }
            ToolbarItemGroup(placement: .primaryAction) {
                toolbarMenu
            }
        }
        .navigationBarBackButtonHidden(true)
        .onKeyPress(.space) {
            if engine.selectedGraphic != nil { engine.fire() }
            return .handled
        }
        .onKeyPress(.escape) {
            if engine.selectedGraphic.map({ engine.isLayerOnAir($0.effectiveLayer) }) ?? false {
                engine.clear()
            }
            return .handled
        }
        .onKeyPress(.rightArrow) {
            if engine.hasNext { engine.next() }
            return .handled
        }
        .onKeyPress(.leftArrow) {
            if engine.hasPrevious { engine.previous() }
            return .handled
        }
        .overlay(alignment: .bottom) {
            if let msg = displayManager.statusMessage {
                Text(msg)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(ARCTheme.arcRed.opacity(0.9), in: RoundedRectangle(cornerRadius: 8))
                    .padding(.bottom, 20)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .animation(.easeInOut(duration: 0.3), value: displayManager.statusMessage)
            }
        }
        .onAppear {
            // Open the stage output (fill) window
            openWindow(id: "stage-output")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                displayManager.openOnExternalScreen()
            }
            // If fill+key mode, also open the key output window
            if engine.show?.keyMode == .fillAndKey {
                openWindow(id: "key-output")
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                    displayManager.openKeyOnExternalScreen()
                }
            }
        }
    }

    // MARK: - Header Bar

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "tv.fill")
                .foregroundStyle(ARCTheme.arcRed)

            if let arcNumber = engine.show?.arcNumber {
                Text(arcNumber)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(ARCTheme.accent)
            }

            Text(engine.show?.name ?? "Lower Thirds")
                .font(ARCTheme.headerBar)
                .foregroundStyle(ARCTheme.textPrimary)
                .lineLimit(1)

            if !engine.graphics.isEmpty {
                Text("\(engine.selectedIndex + 1) of \(engine.graphics.count)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(ARCTheme.textTertiary)
            }

            Spacer()

            // State indicator
            stateIndicator
        }
    }

    private var stateIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(engine.isOnAir ? ARCTheme.liveRed : ARCTheme.readyGreen)
                .frame(width: 8, height: 8)
            Text(engine.isOnAir ? "ON AIR" : "STANDBY")
                .font(.system(size: 12, weight: .heavy, design: .monospaced))
                .foregroundStyle(engine.isOnAir ? ARCTheme.liveRed : ARCTheme.readyGreen)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill((engine.isOnAir ? ARCTheme.liveRed : ARCTheme.readyGreen).opacity(0.15))
        )
    }

    // MARK: - HDMI Banner

    private var hdmiBanner: some View {
        HStack(spacing: 8) {
            // Fill output status
            Image(systemName: displayManager.isConnected ? "display" : "display.trianglebadge.exclamationmark")
                .foregroundStyle(displayManager.isConnected ? ARCTheme.readyGreen : ARCTheme.textTertiary)

            if engine.show?.keyMode == .fillAndKey {
                // Fill + Key mode
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text("FILL")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(displayManager.isConnected ? ARCTheme.readyGreen : ARCTheme.textTertiary)
                        Text("KEY")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(displayManager.isKeyConnected ? ARCTheme.readyGreen : ARCTheme.textTertiary)
                    }
                    Text("Linear Key Mode")
                        .font(.system(size: 10))
                        .foregroundStyle(ARCTheme.accent)
                }
            } else {
                Text(displayManager.isConnected ? "HDMI Connected" : "No External Display")
                    .font(ARCTheme.caption)
                    .foregroundStyle(displayManager.isConnected ? ARCTheme.readyGreen : ARCTheme.textTertiary)
            }

            Spacer()

            if !displayManager.isConnected {
                Button("Open Fill") {
                    openWindow(id: "stage-output")
                }
                .font(ARCTheme.caption)
                .tint(ARCTheme.accent)
            }

            if engine.show?.keyMode == .fillAndKey && !displayManager.isKeyConnected {
                Button("Open Key") {
                    openWindow(id: "key-output")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        displayManager.openKeyOnExternalScreen()
                    }
                }
                .font(ARCTheme.caption)
                .tint(ARCTheme.accent)
            }

            if httpServer.isRunning {
                HStack(spacing: 4) {
                    Circle()
                        .fill(ARCTheme.readyGreen)
                        .frame(width: 6, height: 6)
                    Text("HTTP :\(httpServer.port)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(ARCTheme.textTertiary)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(ARCTheme.surface)
    }

    // MARK: - DeckLink Banner

    private var deckLinkEnabled: Binding<Bool> {
        Binding(
            get: { deckLink.isEnabled },
            set: { $0 ? deckLink.enable() : deckLink.disable() }
        )
    }

    private var deckLinkDevice: Binding<Int64> {
        Binding(
            get: { deckLink.selectedDeviceID },
            set: { deckLink.selectDevice($0) }
        )
    }

    private var deckLinkBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: deckLink.isActive ? "bolt.horizontal.circle.fill" : "bolt.horizontal.circle")
                .foregroundStyle(deckLink.isActive ? ARCTheme.readyGreen : ARCTheme.textTertiary)

            VStack(alignment: .leading, spacing: 2) {
                Text("DECKLINK FILL+KEY")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(deckLink.isActive ? ARCTheme.readyGreen : ARCTheme.textTertiary)
                Text("One Thunderbolt cable to the ATEM G2 — replaces both HDMI key feeds")
                    .font(.system(size: 10))
                    .foregroundStyle(ARCTheme.textTertiary)
            }

            Spacer()

            if let message = deckLink.statusMessage {
                Text(message)
                    .font(.system(size: 10))
                    .foregroundStyle(ARCTheme.liveRed)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            } else if deckLink.isActive {
                Text("SENT \(deckLink.sentFrames)  DROP \(deckLink.droppedFrames)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(ARCTheme.textTertiary)
                if let lastError = deckLink.lastError {
                    Text(lastError)
                        .font(.system(size: 10))
                        .foregroundStyle(ARCTheme.liveRed)
                        .lineLimit(1)
                }
            }

            if !deckLink.isEnabled {
                Picker("DeckLink Device", selection: deckLinkDevice) {
                    Text("First Available").tag(Int64(0))
                    ForEach(deckLink.devices) { device in
                        Text(device.name).tag(device.persistentID)
                    }
                    if deckLink.selectedDeviceID != 0,
                       !deckLink.devices.contains(where: { $0.persistentID == deckLink.selectedDeviceID }) {
                        Text("Saved Device (offline)").tag(deckLink.selectedDeviceID)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(maxWidth: 180)
            }

            Toggle("DeckLink Output", isOn: deckLinkEnabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .tint(ARCTheme.readyGreen)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(ARCTheme.surface)
        .onAppear {
            deckLink.refreshDevices()
        }
    }

    // MARK: - Program Monitor

    private var programMonitor: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "play.rectangle.fill")
                    .foregroundStyle(engine.isOnAir ? ARCTheme.liveRed : ARCTheme.textTertiary)
                Text("PROGRAM")
                    .font(ARCTheme.caption)
                    .foregroundStyle(engine.isOnAir ? ARCTheme.liveRed : ARCTheme.textSecondary)
                Spacer()
                if engine.isOnAir {
                    Text("ON AIR")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(ARCTheme.liveRed)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            // Mini output representation
            GeometryReader { geo in
                let miniScale = geo.size.width / 1920
                ZStack(alignment: .bottomLeading) {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.black)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(engine.isOnAir ? ARCTheme.liveRed : ARCTheme.divider, lineWidth: engine.isOnAir ? 2 : 1)
                        )

                    if let graphic = engine.liveGraphic, engine.isOnAir {
                        TemplateRendererView(graphic: graphic, scale: miniScale)
                            .padding(.leading, 10)
                            .padding(.bottom, 8)
                            .frame(maxWidth: geo.size.width * ARCTheme.ltMaxWidth, alignment: .leading)
                    } else {
                        Text("BLACK")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(ARCTheme.textTertiary)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .frame(height: 80)
            .padding(.horizontal, 8)
            .padding(.bottom, 8)
        }
        .background(ARCTheme.surface)
        .clipShape(RoundedRectangle(cornerRadius: ARCTheme.cornerRadius))
    }

    // MARK: - Transport Controls

    private var transportControls: some View {
        HStack(spacing: 12) {
            Button {
                engine.previous()
            } label: {
                Image(systemName: "backward.fill")
                    .font(.title3)
                    .frame(width: 50, height: 44)
            }
            .disabled(!engine.hasPrevious)
            .tint(ARCTheme.textPrimary)

            Button {
                engine.next()
            } label: {
                Image(systemName: "forward.fill")
                    .font(.title3)
                    .frame(width: 50, height: 44)
            }
            .disabled(!engine.hasNext)
            .tint(ARCTheme.textPrimary)
        }
        .buttonStyle(.bordered)
    }

    // MARK: - FIRE / CLEAR Buttons

    private var fireAndClearButtons: some View {
        HStack(spacing: 16) {
            // FIRE
            Button {
                engine.fire()
            } label: {
                VStack(spacing: 4) {
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 32))
                    Text("FIRE")
                        .font(ARCTheme.fireButton)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 100)
                .foregroundStyle(.white)
                .background(
                    RoundedRectangle(cornerRadius: ARCTheme.cornerRadius)
                        .fill(engine.selectedGraphic != nil ? ARCTheme.readyGreen : ARCTheme.surface)
                )
            }
            .buttonStyle(.plain)
            .disabled(engine.selectedGraphic == nil)

            // CLEAR — clears the selected graphic's layer
            Button {
                engine.clear()
            } label: {
                let selectedLayerOnAir = engine.selectedGraphic.map { engine.isLayerOnAir($0.effectiveLayer) } ?? false
                VStack(spacing: 4) {
                    Image(systemName: "stop.circle.fill")
                        .font(.system(size: 32))
                    Text("CLEAR")
                        .font(ARCTheme.fireButton)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 100)
                .foregroundStyle(.white)
                .background(
                    RoundedRectangle(cornerRadius: ARCTheme.cornerRadius)
                        .fill(selectedLayerOnAir ? ARCTheme.liveRed : ARCTheme.surface)
                )
            }
            .buttonStyle(.plain)
            .disabled(!(engine.selectedGraphic.map { engine.isLayerOnAir($0.effectiveLayer) } ?? false))
        }
    }

    // MARK: - Navigation Buttons

    private var navigationButtons: some View {
        HStack(spacing: 8) {
            ForEach(Array(engine.graphics.enumerated()), id: \.element.id) { index, graphic in
                Button {
                    engine.selectGraphic(at: index)
                } label: {
                    Text("\(index + 1)")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .frame(width: 36, height: 36)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(index == engine.selectedIndex ? ARCTheme.color(from: graphic.accentColor).opacity(0.3) : ARCTheme.surface)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(
                                            engine.isOnAir && engine.liveGraphic?.id == graphic.id
                                                ? ARCTheme.liveRed
                                                : index == engine.selectedIndex
                                                    ? ARCTheme.color(from: graphic.accentColor)
                                                    : ARCTheme.divider,
                                            lineWidth: engine.isOnAir && engine.liveGraphic?.id == graphic.id ? 2 : 1
                                        )
                                )
                        )
                        .foregroundStyle(ARCTheme.textPrimary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Layer Status Strip

    private var layerStatusStrip: some View {
        HStack(spacing: 12) {
            ForEach(GraphicLayer.allCases.sorted()) { layer in
                let active = engine.isLayerOnAir(layer)
                HStack(spacing: 4) {
                    Circle()
                        .fill(active ? ARCTheme.liveRed : ARCTheme.textTertiary.opacity(0.3))
                        .frame(width: 6, height: 6)
                    Text(layer.displayName)
                        .font(.system(size: 10, weight: active ? .bold : .medium, design: .monospaced))
                        .foregroundStyle(active ? ARCTheme.liveRed : ARCTheme.textTertiary)
                }
            }

            Spacer()

            if engine.anyLayerOnAir {
                Button {
                    engine.cutAllToBlack()
                } label: {
                    Text("CLEAR ALL")
                        .font(.system(size: 10, weight: .heavy, design: .monospaced))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(ARCTheme.liveRed)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(ARCTheme.background.opacity(0.5))
    }

    // MARK: - Toolbar Menu

    private var toolbarMenu: some View {
        Menu {
            Toggle("HTTP Remote", isOn: Binding(
                get: { httpServer.isRunning },
                set: { $0 ? httpServer.start() : httpServer.stop() }
            ))

            Divider()

            Button("Cut to Black") {
                engine.cutToBlack()
            }

            Button("Open Stage Window") {
                openWindow(id: "stage-output")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    displayManager.openOnExternalScreen()
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
    }
}
