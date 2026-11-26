//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Scaled 1920x1080 canvas preview showing the selected graphic exactly as it will appear on output.
/// Shows safe area guides and real-time updates.
struct CanvasPreview: View {
    let graphic: Graphic?
    @Binding var selectedElement: CanvasElement?

    @State private var showSafeArea = false
    @State private var isDragging = false
    @State private var dragStartMargin: Double = 0
    @State private var dragStartOffset: Double = 0
    @State private var elementBounds: [ElementBounds] = []

    // Reference output resolution
    private let outputWidth: CGFloat = 1920
    private let outputHeight: CGFloat = 1080

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "tv")
                    .foregroundStyle(ARCTheme.accent)
                Text("CANVAS PREVIEW")
                    .font(ARCTheme.caption)
                    .foregroundStyle(ARCTheme.textSecondary)
                Spacer()
                Toggle("Safe Area", isOn: $showSafeArea)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .font(ARCTheme.caption)
                    .foregroundStyle(ARCTheme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            // Canvas
            GeometryReader { geo in
                let availableWidth = geo.size.width - 24  // padding
                let availableHeight = geo.size.height - 12
                let scale = min(availableWidth / outputWidth, availableHeight / outputHeight)
                let canvasWidth = outputWidth * scale
                let canvasHeight = outputHeight * scale

                ZStack {
                    // Checkerboard pattern (shows transparency)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color.black)
                        .frame(width: canvasWidth, height: canvasHeight)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            selectedElement = nil
                        }

                    // Safe area guides
                    if showSafeArea {
                        safeAreaGuides(width: canvasWidth, height: canvasHeight)
                    }

                    // Graphic overlay
                    if let graphic {
                        graphicOnCanvas(graphic: graphic, canvasWidth: canvasWidth, canvasHeight: canvasHeight, scale: scale)
                    } else {
                        Text("No graphic selected")
                            .font(ARCTheme.caption)
                            .foregroundStyle(ARCTheme.textTertiary)
                    }

                    // Element interaction overlay (tap targets + selection highlight + resize handles)
                    if graphic != nil {
                        elementInteractionOverlay(scale: scale, canvasSize: CGSize(width: canvasWidth, height: canvasHeight))
                    }

                    // Resolution label
                    Text("1920 x 1080")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(ARCTheme.textTertiary.opacity(0.5))
                        .frame(maxWidth: canvasWidth, maxHeight: canvasHeight, alignment: .topTrailing)
                        .padding(8)
                        .allowsHitTesting(false)
                }
                .coordinateSpace(name: "canvas")
                .onPreferenceChange(ElementBoundsPreferenceKey.self) { bounds in
                    elementBounds = bounds
                }
                .frame(width: canvasWidth, height: canvasHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(ARCTheme.divider, lineWidth: 1)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 12)
        }
        .background(ARCTheme.background)
        .onKeyPress(.leftArrow)  { nudge(dx: -1, dy: 0); return .handled }
        .onKeyPress(.rightArrow) { nudge(dx: 1, dy: 0); return .handled }
        .onKeyPress(.upArrow)    { nudge(dx: 0, dy: -1); return .handled }
        .onKeyPress(.downArrow)  { nudge(dx: 0, dy: 1); return .handled }
        .focusable()
    }

    // MARK: - Keyboard Nudge

    private func nudge(dx: Double, dy: Double) {
        guard let graphic else { return }
        let step: Double = NSEvent.modifierFlags.contains(.shift) ? 10 : 1

        switch graphic.graphicType {
        case .lowerThird:
            graphic.horizontalMargin = max(0, min(200, graphic.horizontalMargin + dx * step))
            graphic.bottomOffset = max(0, min(200, graphic.bottomOffset - dy * step))
        case .logoBug, .clock:
            let hSign: Double = (graphic.bugCorner == .topRight || graphic.bugCorner == .bottomRight) ? -1 : 1
            let vSign: Double = (graphic.bugCorner == .bottomLeft || graphic.bugCorner == .bottomRight) ? -1 : 1
            graphic.bugMarginH = max(0, min(400, graphic.bugMarginH + dx * step * hSign))
            graphic.bugMarginV = max(0, min(400, graphic.bugMarginV + dy * step * vSign))
        default:
            break
        }
    }

    // MARK: - Graphic on Canvas

    @ViewBuilder
    private func graphicOnCanvas(graphic: Graphic, canvasWidth: CGFloat, canvasHeight: CGFloat, scale: CGFloat) -> some View {
        switch graphic.graphicType {
        case .lowerThird:
            lowerThirdOnCanvas(graphic: graphic, canvasWidth: canvasWidth, canvasHeight: canvasHeight, scale: scale)

        case .ticker:
            VStack {
                Spacer()
                ZStack {
                    Rectangle()
                        .fill(graphic.resolvedTitleBgColor.opacity(graphic.backgroundOpacity))
                        .frame(height: 48 * scale)
                    VStack(spacing: 0) {
                        Rectangle()
                            .fill(ARCTheme.color(from: graphic.accentColor))
                            .frame(height: graphic.accentBarSize * scale)
                        Spacer()
                    }
                    .frame(height: 48 * scale)
                    Text(graphic.line1)
                        .font(.system(size: graphic.line1FontSize * scale, weight: graphic.line1Weight.fontWeight))
                        .foregroundStyle(graphic.colorForLine(1))
                        .lineLimit(1)
                }
                .frame(height: 48 * scale)
            }
            .frame(width: canvasWidth, height: canvasHeight)

        case .logoBug:
            ZStack(alignment: graphic.bugCorner.alignment) {
                Color.clear
                if let logoData = graphic.logoData, let nsImage = NSImage(data: logoData) {
                    Image(nsImage: nsImage).resizable().scaledToFit()
                        .frame(height: graphic.logoSize * scale)
                        .padding(.horizontal, graphic.bugMarginH * scale)
                        .padding(.vertical, graphic.bugMarginV * scale)
                } else {
                    Text(graphic.line1)
                        .font(.system(size: graphic.line1FontSize * scale, weight: graphic.line1Weight.fontWeight))
                        .foregroundStyle(ARCTheme.color(from: graphic.accentColor))
                        .padding(.horizontal, 12 * scale)
                        .padding(.vertical, 6 * scale)
                        .background(
                            RoundedRectangle(cornerRadius: graphic.cornerRadius * scale)
                                .fill(graphic.resolvedTitleBgColor.opacity(graphic.backgroundOpacity))
                        )
                        .padding(.horizontal, graphic.bugMarginH * scale)
                        .padding(.vertical, graphic.bugMarginV * scale)
                }
            }
            .frame(width: canvasWidth, height: canvasHeight)
            .gesture(bugMarginDragGesture(graphic: graphic, scale: scale))

        case .fullTitle:
            VStack(spacing: graphic.lineSpacing * scale) {
                Spacer()
                Text(graphic.line1)
                    .font(.system(size: graphic.line1FontSize * scale, weight: graphic.line1Weight.fontWeight))
                    .foregroundStyle(graphic.colorForLine(1).opacity(graphic.line1Opacity))
                    .multilineTextAlignment(.center)
                if let line2 = graphic.line2, !line2.isEmpty {
                    Text(line2)
                        .font(.system(size: graphic.line2FontSize * scale, weight: graphic.line2Weight.fontWeight))
                        .foregroundStyle(graphic.colorForLine(2).opacity(graphic.line2Opacity))
                        .multilineTextAlignment(.center)
                }
                if let line3 = graphic.line3, !line3.isEmpty {
                    Text(line3)
                        .font(.system(size: graphic.line3FontSize * scale, weight: graphic.line3Weight.fontWeight))
                        .foregroundStyle(graphic.colorForLine(3).opacity(graphic.line3Opacity))
                        .multilineTextAlignment(.center)
                }
                Spacer()
            }
            .frame(width: canvasWidth, height: canvasHeight)
            .background(Color.black.opacity(graphic.backgroundOpacity * 0.6))

        case .clock:
            ZStack(alignment: graphic.bugCorner.alignment) {
                Color.clear
                Text({
                    let fmt = DateFormatter()
                    fmt.dateFormat = graphic.clockShowSeconds
                        ? graphic.clockFormat.replacingOccurrences(of: "h:mm", with: "h:mm:ss")
                            .replacingOccurrences(of: "H:mm", with: "H:mm:ss")
                        : graphic.clockFormat
                    return fmt.string(from: .now)
                }())
                    .font(.system(size: graphic.line1FontSize * scale, weight: graphic.line1Weight.fontWeight))
                    .foregroundStyle(graphic.colorForLine(1).opacity(graphic.line1Opacity))
                    .monospacedDigit()
                    .padding(.horizontal, 16 * scale)
                    .padding(.vertical, 8 * scale)
                    .background(
                        RoundedRectangle(cornerRadius: graphic.cornerRadius * scale)
                            .fill(graphic.resolvedTitleBgColor.opacity(graphic.backgroundOpacity))
                    )
                    .padding(.horizontal, graphic.bugMarginH * scale)
                    .padding(.vertical, graphic.bugMarginV * scale)
            }
            .frame(width: canvasWidth, height: canvasHeight)
            .gesture(bugMarginDragGesture(graphic: graphic, scale: scale))
        }
    }

    @ViewBuilder
    private func lowerThirdOnCanvas(graphic: Graphic, canvasWidth: CGFloat, canvasHeight: CGFloat, scale: CGFloat) -> some View {
        let maxGraphicWidth = canvasWidth * graphic.maxWidthFraction
        let margin = graphic.horizontalMargin * scale
        let bottomPad = graphic.bottomOffset * scale

        switch graphic.positionPreset {
        case .bottomLeft:
            VStack {
                Spacer()
                HStack {
                    draggableTemplate(graphic: graphic, scale: scale)
                        .frame(maxWidth: graphic.template == .fullWidth ? canvasWidth : maxGraphicWidth, alignment: .leading)
                    if graphic.template != .fullWidth { Spacer() }
                }
                .padding(.leading, graphic.template == .fullWidth ? 0 : margin)
                .padding(.bottom, bottomPad)
            }
            .frame(width: canvasWidth, height: canvasHeight)

        case .bottomCenter:
            VStack {
                Spacer()
                draggableTemplate(graphic: graphic, scale: scale)
                    .frame(maxWidth: graphic.template == .fullWidth ? canvasWidth : maxGraphicWidth)
                    .padding(.bottom, bottomPad)
            }
            .frame(width: canvasWidth, height: canvasHeight)

        case .bottomRight:
            VStack {
                Spacer()
                HStack {
                    if graphic.template != .fullWidth { Spacer() }
                    draggableTemplate(graphic: graphic, scale: scale)
                        .frame(maxWidth: graphic.template == .fullWidth ? canvasWidth : maxGraphicWidth, alignment: .trailing)
                }
                .padding(.trailing, graphic.template == .fullWidth ? 0 : margin)
                .padding(.bottom, bottomPad)
            }
            .frame(width: canvasWidth, height: canvasHeight)

        case .topLeft:
            VStack {
                HStack {
                    draggableTemplate(graphic: graphic, scale: scale)
                        .frame(maxWidth: graphic.template == .fullWidth ? canvasWidth : maxGraphicWidth, alignment: .leading)
                    if graphic.template != .fullWidth { Spacer() }
                }
                .padding(.leading, graphic.template == .fullWidth ? 0 : margin)
                .padding(.top, bottomPad)
                Spacer()
            }
            .frame(width: canvasWidth, height: canvasHeight)

        case .topCenter:
            VStack {
                draggableTemplate(graphic: graphic, scale: scale)
                    .frame(maxWidth: graphic.template == .fullWidth ? canvasWidth : maxGraphicWidth)
                    .padding(.top, bottomPad)
                Spacer()
            }
            .frame(width: canvasWidth, height: canvasHeight)

        case .topRight:
            VStack {
                HStack {
                    if graphic.template != .fullWidth { Spacer() }
                    draggableTemplate(graphic: graphic, scale: scale)
                        .frame(maxWidth: graphic.template == .fullWidth ? canvasWidth : maxGraphicWidth, alignment: .trailing)
                }
                .padding(.trailing, graphic.template == .fullWidth ? 0 : margin)
                .padding(.top, bottomPad)
                Spacer()
            }
            .frame(width: canvasWidth, height: canvasHeight)

        case .center:
            draggableTemplate(graphic: graphic, scale: scale)
                .frame(maxWidth: graphic.template == .fullWidth ? canvasWidth : maxGraphicWidth)
                .frame(width: canvasWidth, height: canvasHeight)
        }
    }

    // MARK: - Draggable Template Wrapper

    @ViewBuilder
    private func draggableTemplate(graphic: Graphic, scale: CGFloat) -> some View {
        TemplateRendererView(graphic: graphic, scale: scale, reportBounds: true)
            .overlay(
                RoundedRectangle(cornerRadius: 2)
                    .stroke(isDragging ? Color.blue : Color.clear, lineWidth: isDragging ? 2 : 0)
            )
            .onHover { hovering in
                if hovering && selectedElement == nil {
                    NSCursor.openHand.push()
                } else if !hovering {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        // Only allow whole-graphic drag when no sub-element selected
                        guard selectedElement == nil || selectedElement == .wholeGraphic else { return }
                        if !isDragging {
                            isDragging = true
                            dragStartMargin = graphic.horizontalMargin
                            dragStartOffset = graphic.bottomOffset
                            NSCursor.closedHand.push()
                        }
                        let dx = value.translation.width / scale
                        let dy = value.translation.height / scale
                        let marginDir: Double = graphic.positionPreset == .bottomRight ? -1 : 1
                        graphic.horizontalMargin = min(200, max(0, dragStartMargin + dx * marginDir))
                        graphic.bottomOffset = min(200, max(0, dragStartOffset - dy))
                    }
                    .onEnded { _ in
                        isDragging = false
                        NSCursor.pop()
                    }
            )
    }

    // MARK: - Element Interaction Overlay

    @ViewBuilder
    private func elementInteractionOverlay(scale: CGFloat, canvasSize: CGSize) -> some View {
        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)

        ZStack {
            ForEach(elementBounds, id: \.element) { eb in
                // Tap target — use .offset() not .position() so hit area stays at frame size
                Rectangle()
                    .fill(Color.white.opacity(0.001))
                    .frame(width: eb.rect.width, height: eb.rect.height)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selectedElement = eb.element
                    }
                    .offset(x: eb.rect.midX - center.x, y: eb.rect.midY - center.y)

                // Selection highlight
                if selectedElement == eb.element {
                    RoundedRectangle(cornerRadius: 2)
                        .stroke(Color.blue, lineWidth: 1.5)
                        .frame(width: eb.rect.width, height: eb.rect.height)
                        .allowsHitTesting(false)
                        .offset(x: eb.rect.midX - center.x, y: eb.rect.midY - center.y)

                    // Element label
                    Text(eb.element.displayName)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.blue.opacity(0.8))
                        .clipShape(RoundedRectangle(cornerRadius: 2))
                        .allowsHitTesting(false)
                        .offset(x: eb.rect.midX - center.x, y: eb.rect.minY - 8 - center.y)

                    // Resize handles
                    if let graphic {
                        resizeHandles(for: eb, graphic: graphic, scale: scale, center: center)
                    }
                }
            }
        }
    }

    // MARK: - Resize Handles

    @ViewBuilder
    private func resizeHandles(for eb: ElementBounds, graphic: Graphic, scale: CGFloat, center: CGPoint) -> some View {
        let handleSize: CGFloat = 8

        switch eb.element {
        case .logo:
            // Bottom-right corner handle for proportional resize
            resizeHandle(at: CGPoint(x: eb.rect.maxX, y: eb.rect.maxY), size: handleSize, center: center)
                .gesture(logoDragGesture(graphic: graphic, scale: scale))
            // Body drag for repositioning
            Rectangle()
                .fill(Color.clear)
                .frame(width: eb.rect.width, height: eb.rect.height)
                .contentShape(Rectangle())
                .gesture(logoOffsetDragGesture(graphic: graphic, scale: scale))
                .offset(x: eb.rect.midX - center.x, y: eb.rect.midY - center.y)

        case .overlayImage:
            resizeHandle(at: CGPoint(x: eb.rect.maxX, y: eb.rect.maxY), size: handleSize, center: center)
                .gesture(overlayScaleDragGesture(graphic: graphic, scale: scale))
            Rectangle()
                .fill(Color.clear)
                .frame(width: eb.rect.width, height: eb.rect.height)
                .contentShape(Rectangle())
                .gesture(overlayOffsetDragGesture(graphic: graphic, scale: scale))
                .offset(x: eb.rect.midX - center.x, y: eb.rect.midY - center.y)

        case .backgroundImage:
            resizeHandle(at: CGPoint(x: eb.rect.maxX, y: eb.rect.maxY), size: handleSize, center: center)
                .gesture(backgroundScaleDragGesture(graphic: graphic, scale: scale))

        case .nameBlock:
            // Edge handles for padding
            resizeHandle(at: CGPoint(x: eb.rect.minX, y: eb.rect.midY), size: handleSize, center: center)
                .gesture(paddingDragGesture(graphic: graphic, scale: scale, property: \.namePaddingH, axis: .horizontal, invert: true))
            resizeHandle(at: CGPoint(x: eb.rect.maxX, y: eb.rect.midY), size: handleSize, center: center)
                .gesture(paddingDragGesture(graphic: graphic, scale: scale, property: \.namePaddingH, axis: .horizontal, invert: false))
            resizeHandle(at: CGPoint(x: eb.rect.midX, y: eb.rect.minY), size: handleSize, center: center)
                .gesture(paddingDragGesture(graphic: graphic, scale: scale, property: \.namePaddingV, axis: .vertical, invert: true))
            resizeHandle(at: CGPoint(x: eb.rect.midX, y: eb.rect.maxY), size: handleSize, center: center)
                .gesture(paddingDragGesture(graphic: graphic, scale: scale, property: \.namePaddingV, axis: .vertical, invert: false))

        case .titleBlock:
            resizeHandle(at: CGPoint(x: eb.rect.minX, y: eb.rect.midY), size: handleSize, center: center)
                .gesture(paddingDragGesture(graphic: graphic, scale: scale, property: \.titlePaddingH, axis: .horizontal, invert: true))
            resizeHandle(at: CGPoint(x: eb.rect.maxX, y: eb.rect.midY), size: handleSize, center: center)
                .gesture(paddingDragGesture(graphic: graphic, scale: scale, property: \.titlePaddingH, axis: .horizontal, invert: false))
            resizeHandle(at: CGPoint(x: eb.rect.midX, y: eb.rect.minY), size: handleSize, center: center)
                .gesture(paddingDragGesture(graphic: graphic, scale: scale, property: \.titlePaddingV, axis: .vertical, invert: true))
            resizeHandle(at: CGPoint(x: eb.rect.midX, y: eb.rect.maxY), size: handleSize, center: center)
                .gesture(paddingDragGesture(graphic: graphic, scale: scale, property: \.titlePaddingV, axis: .vertical, invert: false))

        case .accentBar:
            resizeHandle(at: CGPoint(x: eb.rect.midX, y: eb.rect.maxY), size: handleSize, center: center)
                .gesture(accentBarDragGesture(graphic: graphic, scale: scale))

        case .wholeGraphic:
            // Left + right edge handles for width resize (maxWidthFraction)
            let approxCanvasW = eb.rect.width / CGFloat(graphic.maxWidthFraction)
            resizeHandle(at: CGPoint(x: eb.rect.minX, y: eb.rect.midY), size: handleSize, center: center)
                .gesture(widthDragGesture(graphic: graphic, scale: scale, invert: true, canvasWidth: approxCanvasW))
            resizeHandle(at: CGPoint(x: eb.rect.maxX, y: eb.rect.midY), size: handleSize, center: center)
                .gesture(widthDragGesture(graphic: graphic, scale: scale, invert: false, canvasWidth: approxCanvasW))
        }
    }

    private func resizeHandle(at point: CGPoint, size: CGFloat, center: CGPoint) -> some View {
        Rectangle()
            .fill(Color.white)
            .frame(width: size, height: size)
            .border(Color.blue, width: 1)
            .contentShape(Rectangle())
            .onHover { hovering in
                if hovering {
                    NSCursor.crosshair.push()
                } else {
                    NSCursor.pop()
                }
            }
            .offset(x: point.x - center.x, y: point.y - center.y)
    }

    // MARK: - Resize Drag Gestures

    @State private var dragStartLogoSize: Double = 0
    @State private var dragStartLogoOffsetX: Double = 0
    @State private var dragStartLogoOffsetY: Double = 0
    @State private var dragStartOverlayScale: Double = 0
    @State private var dragStartOverlayOffsetX: Double = 0
    @State private var dragStartOverlayOffsetY: Double = 0
    @State private var dragStartBgScale: Double = 0
    @State private var dragStartPadding: Double = 0
    @State private var dragStartAccentBar: Double = 0
    @State private var dragStartMaxWidth: Double = 0
    @State private var dragStartBugMarginH: Double = 0
    @State private var dragStartBugMarginV: Double = 0

    private func logoDragGesture(graphic: Graphic, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStartLogoSize == 0 { dragStartLogoSize = graphic.logoSize }
                let delta = value.translation.height / scale
                graphic.logoSize = max(16, min(128, dragStartLogoSize + delta))
            }
            .onEnded { _ in dragStartLogoSize = 0 }
    }

    private func logoOffsetDragGesture(graphic: Graphic, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragStartLogoOffsetX == 0 && dragStartLogoOffsetY == 0 {
                    dragStartLogoOffsetX = graphic.logoOffsetX
                    dragStartLogoOffsetY = graphic.logoOffsetY
                }
                graphic.logoOffsetX = dragStartLogoOffsetX + value.translation.width / scale
                graphic.logoOffsetY = dragStartLogoOffsetY + value.translation.height / scale
            }
            .onEnded { _ in
                dragStartLogoOffsetX = 0
                dragStartLogoOffsetY = 0
            }
    }

    private func overlayScaleDragGesture(graphic: Graphic, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStartOverlayScale == 0 { dragStartOverlayScale = graphic.overlayScale }
                let delta = value.translation.height / scale / 200 // scale sensitivity
                graphic.overlayScale = max(0.1, min(3.0, dragStartOverlayScale + delta))
            }
            .onEnded { _ in dragStartOverlayScale = 0 }
    }

    private func overlayOffsetDragGesture(graphic: Graphic, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragStartOverlayOffsetX == 0 && dragStartOverlayOffsetY == 0 {
                    dragStartOverlayOffsetX = graphic.overlayOffsetX
                    dragStartOverlayOffsetY = graphic.overlayOffsetY
                }
                graphic.overlayOffsetX = dragStartOverlayOffsetX + value.translation.width / scale
                graphic.overlayOffsetY = dragStartOverlayOffsetY + value.translation.height / scale
            }
            .onEnded { _ in
                dragStartOverlayOffsetX = 0
                dragStartOverlayOffsetY = 0
            }
    }

    private func backgroundScaleDragGesture(graphic: Graphic, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStartBgScale == 0 { dragStartBgScale = graphic.backgroundScale }
                let delta = value.translation.height / scale / 200
                graphic.backgroundScale = max(0.5, min(3.0, dragStartBgScale + delta))
            }
            .onEnded { _ in dragStartBgScale = 0 }
    }

    private enum DragAxis { case horizontal, vertical }

    private func paddingDragGesture(graphic: Graphic, scale: CGFloat, property: ReferenceWritableKeyPath<Graphic, Double>, axis: DragAxis, invert: Bool) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStartPadding == 0 { dragStartPadding = graphic[keyPath: property] }
                let raw = axis == .horizontal ? value.translation.width : value.translation.height
                let delta = (invert ? -raw : raw) / scale
                graphic[keyPath: property] = max(2, min(60, dragStartPadding + delta))
            }
            .onEnded { _ in dragStartPadding = 0 }
    }

    private func accentBarDragGesture(graphic: Graphic, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStartAccentBar == 0 { dragStartAccentBar = graphic.accentBarSize }
                let delta = value.translation.height / scale
                graphic.accentBarSize = max(0, min(20, dragStartAccentBar + delta))
            }
            .onEnded { _ in dragStartAccentBar = 0 }
    }

    private func widthDragGesture(graphic: Graphic, scale: CGFloat, invert: Bool, canvasWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if dragStartMaxWidth == 0 { dragStartMaxWidth = graphic.maxWidthFraction }
                let raw = value.translation.width / canvasWidth
                let delta = invert ? -raw : raw
                graphic.maxWidthFraction = max(0.2, min(1.0, dragStartMaxWidth + delta))
            }
            .onEnded { _ in dragStartMaxWidth = 0 }
    }

    private func bugMarginDragGesture(graphic: Graphic, scale: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                if dragStartBugMarginH == 0 && dragStartBugMarginV == 0 {
                    dragStartBugMarginH = graphic.bugMarginH
                    dragStartBugMarginV = graphic.bugMarginV
                }
                let dx = value.translation.width / scale
                let dy = value.translation.height / scale
                // Flip direction based on which corner the bug is anchored to
                let hSign: Double = (graphic.bugCorner == .topRight || graphic.bugCorner == .bottomRight) ? -1 : 1
                let vSign: Double = (graphic.bugCorner == .bottomLeft || graphic.bugCorner == .bottomRight) ? -1 : 1
                graphic.bugMarginH = max(0, min(400, dragStartBugMarginH + dx * hSign))
                graphic.bugMarginV = max(0, min(400, dragStartBugMarginV + dy * vSign))
            }
            .onEnded { _ in
                dragStartBugMarginH = 0
                dragStartBugMarginV = 0
            }
    }

    // MARK: - Safe Area Guides

    private func safeAreaGuides(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            // Action safe (5%)
            RoundedRectangle(cornerRadius: 2)
                .stroke(Color.red.opacity(0.3), lineWidth: 1)
                .frame(width: width * 0.9, height: height * 0.9)

            // Title safe (10%)
            RoundedRectangle(cornerRadius: 2)
                .stroke(Color.green.opacity(0.3), lineWidth: 1)
                .frame(width: width * 0.8, height: height * 0.8)

            // Center crosshair
            Path { path in
                let cx = width / 2, cy = height / 2
                path.move(to: CGPoint(x: cx - 10, y: cy))
                path.addLine(to: CGPoint(x: cx + 10, y: cy))
                path.move(to: CGPoint(x: cx, y: cy - 10))
                path.addLine(to: CGPoint(x: cx, y: cy + 10))
            }
            .stroke(Color.white.opacity(0.2), lineWidth: 1)
        }
        .frame(width: width, height: height)
        .allowsHitTesting(false)
    }
}
