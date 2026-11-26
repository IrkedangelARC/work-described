//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import SwiftUI
import Combine
#if os(iOS)
import UIKit
#endif

/// Core state machine for graphics compositing.
/// States: idle (nothing loaded), ready (show loaded, nothing on air),
/// preview (graphic selected), live (graphic on output), clearing (animating out).
///
/// Multi-layer: each GraphicLayer has independent on-air state.
/// The legacy `liveGraphic`/`isOnAir` properties delegate to the `.lowerThird` layer
/// for backward compatibility with existing UI and HTTP API.
@Observable
final class GraphicsEngine {

    // MARK: - State

    enum State: String, Codable {
        case idle
        case ready
        case preview
        case live
        case clearing
    }

    private(set) var state: State = .idle

    // MARK: - Layer State

    /// Per-layer on-air state
    struct LayerState {
        var graphic: Graphic?
        var isOnAir: Bool = false
    }

    /// Active layers — keyed by compositing layer
    private(set) var layers: [GraphicLayer: LayerState] = [:]

    // MARK: - Show Data

    private(set) var show: Show?
    private(set) var graphics: [Graphic] = []

    // MARK: - Selection & Output

    /// Currently selected graphic index (for preview)
    private(set) var selectedIndex: Int = 0

    // MARK: - Backward-Compatible Accessors

    /// The lower-third graphic currently on output (nil = clear)
    var liveGraphic: Graphic? { layers[.lowerThird]?.graphic }

    /// Whether the lower-third layer is on air
    var isOnAir: Bool { layers[.lowerThird]?.isOnAir ?? false }

    /// Whether ANY layer is currently on air
    var anyLayerOnAir: Bool { layers.values.contains { $0.isOnAir } }

    // MARK: - Computed

    var selectedGraphic: Graphic? {
        guard !graphics.isEmpty, selectedIndex >= 0, selectedIndex < graphics.count else { return nil }
        return graphics[selectedIndex]
    }

    var graphicCount: Int { graphics.count }
    var hasNext: Bool { selectedIndex < graphics.count - 1 }
    var hasPrevious: Bool { selectedIndex > 0 }

    private var sleepActivity: NSObjectProtocol?

    // MARK: - Load Show

    func loadShow(_ show: Show) {
        self.show = show
        self.graphics = show.sortedGraphics
        self.selectedIndex = graphics.isEmpty ? 0 : 0
        self.layers = [:]
        self.state = graphics.isEmpty ? .idle : .ready
        enableSleepPrevention()
    }

    func unloadShow() {
        clear()
        show = nil
        graphics = []
        selectedIndex = 0
        layers = [:]
        state = .idle
        disableSleepPrevention()
    }

    // MARK: - Navigation

    func selectGraphic(at index: Int) {
        guard index >= 0, index < graphics.count else { return }
        selectedIndex = index
        if state == .ready || state == .preview {
            state = .preview
        }
    }

    func next() {
        guard hasNext else { return }
        selectGraphic(at: selectedIndex + 1)
    }

    func previous() {
        guard hasPrevious else { return }
        selectGraphic(at: selectedIndex - 1)
    }

    func goToGraphic(at index: Int) {
        selectGraphic(at: index)
    }

    // MARK: - Fire / Clear (Layer-Aware)

    /// Send the currently selected graphic to its target layer
    func fire() {
        guard let graphic = selectedGraphic else { return }
        fire(layer: graphic.effectiveLayer, graphic: graphic)
        if graphic.effectiveLayer == .lowerThird {
            state = .live
        }
    }

    /// Fire a specific graphic by index (for HTTP API)
    func fire(at index: Int) {
        guard index >= 0, index < graphics.count else { return }
        selectedIndex = index
        fire()
    }

    /// Fire a graphic on a specific layer
    func fire(layer: GraphicLayer, graphic: Graphic) {
        // Stage with isOnAir=false so SwiftUI renders the hidden state first
        layers[layer] = LayerState(graphic: graphic, isOnAir: false)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            self?.layers[layer]?.isOnAir = true
        }
    }

    /// Clear the selected graphic's layer
    func clear() {
        let targetLayer = selectedGraphic?.effectiveLayer ?? .lowerThird
        clear(layer: targetLayer)
    }

    /// Clear a specific layer (animate out, then remove)
    func clear(layer: GraphicLayer) {
        guard layers[layer]?.isOnAir == true else { return }

        if layer == .lowerThird {
            state = .clearing
        }

        layers[layer]?.isOnAir = false

        let outDuration = layers[layer]?.graphic?.effectiveOutDuration ?? 0.3
        DispatchQueue.main.asyncAfter(deadline: .now() + outDuration + 0.05) { [weak self] in
            guard let self else { return }
            self.layers[layer]?.graphic = nil

            // Lower-third state transition
            if layer == .lowerThird, self.state == .clearing {
                self.state = self.selectedGraphic != nil ? .preview : .ready
            }
        }
    }

    /// Instant cut to black on lower-third layer
    func cutToBlack() {
        layers[.lowerThird] = nil
        state = selectedGraphic != nil ? .preview : .ready
    }

    /// Instant cut all layers to black
    func cutAllToBlack() {
        layers = [:]
        state = selectedGraphic != nil ? .preview : .ready
    }

    // MARK: - Layer Queries

    /// Get the on-air graphic for a specific layer
    func graphic(on layer: GraphicLayer) -> Graphic? {
        layers[layer]?.graphic
    }

    /// Check if a specific layer is on air
    func isLayerOnAir(_ layer: GraphicLayer) -> Bool {
        layers[layer]?.isOnAir ?? false
    }

    // MARK: - Style Clipboard

    /// Captured style properties for copy/paste across graphics
    struct StyleClipboard {
        let template: GraphicTemplate
        let animationPreset: AnimationPreset
        let accentColor: String
        let fontFamily: String?
        let line1FontSize: Double, line2FontSize: Double, line3FontSize: Double
        let line1Weight: FontWeightOption, line2Weight: FontWeightOption, line3Weight: FontWeightOption
        let line1Color: String?, line2Color: String?, line3Color: String?
        let line1Opacity: Double, line2Opacity: Double, line3Opacity: Double
        let backgroundOpacity: Double
        let titleBgColor: String?, titleBgOpacity: Double
        let gradientEnabled: Bool, gradientEndColor: String?
        let accentBarSize: Double
        let namePaddingH: Double, namePaddingV: Double
        let titlePaddingH: Double, titlePaddingV: Double
        let elementGap: Double, lineSpacing: Double
        let cornerRadius: Double, bottomOffset: Double
        let horizontalMargin: Double, maxWidthFraction: Double
        let shadowEnabled: Bool, shadowRadius: Double, shadowOpacity: Double
        let animationInDuration: Double, animationOutDuration: Double
        let hardEdge: Bool
    }

    private(set) var copiedStyle: StyleClipboard?
    var hasClipboardStyle: Bool { copiedStyle != nil }

    func copyStyle(from graphic: Graphic) {
        copiedStyle = StyleClipboard(
            template: graphic.template,
            animationPreset: graphic.animationPreset,
            accentColor: graphic.accentColor,
            fontFamily: graphic.fontFamily,
            line1FontSize: graphic.line1FontSize, line2FontSize: graphic.line2FontSize, line3FontSize: graphic.line3FontSize,
            line1Weight: graphic.line1Weight, line2Weight: graphic.line2Weight, line3Weight: graphic.line3Weight,
            line1Color: graphic.line1Color, line2Color: graphic.line2Color, line3Color: graphic.line3Color,
            line1Opacity: graphic.line1Opacity, line2Opacity: graphic.line2Opacity, line3Opacity: graphic.line3Opacity,
            backgroundOpacity: graphic.backgroundOpacity,
            titleBgColor: graphic.titleBgColor, titleBgOpacity: graphic.titleBgOpacity,
            gradientEnabled: graphic.gradientEnabled, gradientEndColor: graphic.gradientEndColor,
            accentBarSize: graphic.accentBarSize,
            namePaddingH: graphic.namePaddingH, namePaddingV: graphic.namePaddingV,
            titlePaddingH: graphic.titlePaddingH, titlePaddingV: graphic.titlePaddingV,
            elementGap: graphic.elementGap, lineSpacing: graphic.lineSpacing,
            cornerRadius: graphic.cornerRadius, bottomOffset: graphic.bottomOffset,
            horizontalMargin: graphic.horizontalMargin, maxWidthFraction: graphic.maxWidthFraction,
            shadowEnabled: graphic.shadowEnabled, shadowRadius: graphic.shadowRadius, shadowOpacity: graphic.shadowOpacity,
            animationInDuration: graphic.animationInDuration, animationOutDuration: graphic.animationOutDuration,
            hardEdge: graphic.hardEdge
        )
    }

    func pasteStyle(to graphic: Graphic) {
        guard let s = copiedStyle else { return }
        graphic.template = s.template
        graphic.animationPreset = s.animationPreset
        graphic.accentColor = s.accentColor
        graphic.fontFamily = s.fontFamily
        graphic.line1FontSize = s.line1FontSize; graphic.line2FontSize = s.line2FontSize; graphic.line3FontSize = s.line3FontSize
        graphic.line1Weight = s.line1Weight; graphic.line2Weight = s.line2Weight; graphic.line3Weight = s.line3Weight
        graphic.line1Color = s.line1Color; graphic.line2Color = s.line2Color; graphic.line3Color = s.line3Color
        graphic.line1Opacity = s.line1Opacity; graphic.line2Opacity = s.line2Opacity; graphic.line3Opacity = s.line3Opacity
        graphic.backgroundOpacity = s.backgroundOpacity
        graphic.titleBgColor = s.titleBgColor; graphic.titleBgOpacity = s.titleBgOpacity
        graphic.gradientEnabled = s.gradientEnabled; graphic.gradientEndColor = s.gradientEndColor
        graphic.accentBarSize = s.accentBarSize
        graphic.namePaddingH = s.namePaddingH; graphic.namePaddingV = s.namePaddingV
        graphic.titlePaddingH = s.titlePaddingH; graphic.titlePaddingV = s.titlePaddingV
        graphic.elementGap = s.elementGap; graphic.lineSpacing = s.lineSpacing
        graphic.cornerRadius = s.cornerRadius; graphic.bottomOffset = s.bottomOffset
        graphic.horizontalMargin = s.horizontalMargin; graphic.maxWidthFraction = s.maxWidthFraction
        graphic.shadowEnabled = s.shadowEnabled; graphic.shadowRadius = s.shadowRadius; graphic.shadowOpacity = s.shadowOpacity
        graphic.animationInDuration = s.animationInDuration; graphic.animationOutDuration = s.animationOutDuration
        graphic.hardEdge = s.hardEdge
    }

    // MARK: - Refresh

    /// Re-read graphics from the show (after edits)
    func refreshGraphics() {
        guard let show else { return }
        graphics = show.sortedGraphics
        if selectedIndex >= graphics.count {
            selectedIndex = max(0, graphics.count - 1)
        }
        if graphics.isEmpty {
            state = .idle
        }
    }

    // MARK: - Sleep Prevention

    private func enableSleepPrevention() {
        #if os(iOS)
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = true
        }
        #elseif os(macOS)
        sleepActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
            reason: "ARC Lower Thirds show in progress"
        )
        #endif
    }

    private func disableSleepPrevention() {
        #if os(iOS)
        DispatchQueue.main.async {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        #elseif os(macOS)
        if let activity = sleepActivity {
            ProcessInfo.processInfo.endActivity(activity)
            sleepActivity = nil
        }
        #endif
    }
}
