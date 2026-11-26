//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Scrollable sidebar of graphic hot buttons for quick selection.
struct GraphicListSidebar: View {
    @Environment(GraphicsEngine.self) private var engine

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "list.bullet.rectangle")
                    .foregroundStyle(ARCTheme.accent)
                Text("GRAPHICS")
                    .font(ARCTheme.caption)
                    .foregroundStyle(ARCTheme.textSecondary)
                Spacer()
                Text("\(engine.graphicCount)")
                    .font(ARCTheme.caption)
                    .foregroundStyle(ARCTheme.textTertiary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()
                .background(ARCTheme.divider)

            // Graphic list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(engine.graphics.enumerated()), id: \.element.id) { index, graphic in
                            GraphicHotButton(
                                graphic: graphic,
                                index: index,
                                isSelected: index == engine.selectedIndex,
                                isLive: engine.isOnAir && engine.liveGraphic?.id == graphic.id,
                                action: {
                                    engine.selectGraphic(at: index)
                                }
                            )
                        }
                    }
                    .padding(6)
                }
                .onChange(of: engine.selectedIndex) { _, newIndex in
                    if let graphic = engine.selectedGraphic {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            proxy.scrollTo(graphic.id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(width: ARCTheme.sidebarWidth)
        .background(ARCTheme.surface)
    }
}
