//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI

/// Miniature thumbnail preview of a template for the template picker.
/// Uses sample text to show what each template looks like.
struct TemplateThumbnail: View {
    let template: GraphicTemplate
    var isSelected: Bool = false
    var accentColor: String = "#33D9F5"

    private var sampleGraphic: Graphic {
        Graphic(
            line1: "Speaker Name",
            line2: "Title / Position",
            line3: "Organization",
            accentColor: accentColor,
            template: template
        )
    }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            // 16:9 black frame
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.black)

            // Scaled template renderer
            TemplateRendererView(graphic: sampleGraphic, scale: 0.22)
                .padding(.leading, 6)
                .padding(.bottom, 4)
                .allowsHitTesting(false)
        }
        .frame(width: 160, height: 90)
        .overlay(
            RoundedRectangle(cornerRadius: 4)
                .stroke(
                    isSelected ? ARCTheme.accent : ARCTheme.divider,
                    lineWidth: isSelected ? 2 : 1
                )
        )
    }
}

/// Grid of template thumbnails for selection
struct TemplatePickerGrid: View {
    @Binding var selected: GraphicTemplate
    var accentColor: String = "#33D9F5"

    var body: some View {
        LazyVGrid(columns: [
            GridItem(.flexible(), spacing: 8),
            GridItem(.flexible(), spacing: 8)
        ], spacing: 8) {
            ForEach(GraphicTemplate.allCases) { template in
                Button {
                    selected = template
                } label: {
                    VStack(spacing: 4) {
                        TemplateThumbnail(
                            template: template,
                            isSelected: selected == template,
                            accentColor: accentColor
                        )

                        Text(template.displayName)
                            .font(.system(size: 11, weight: selected == template ? .semibold : .regular))
                            .foregroundStyle(selected == template ? ARCTheme.accent : ARCTheme.textSecondary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }
}
