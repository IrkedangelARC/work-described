//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import CoreGraphics

/// What an output shows (2026-09-20: "choose what is on those outputs. selectable speaker, gallery,
/// sharing or combinations of those elements. the more customisable the better"). A scene is a list of
/// regions; each region is one ELEMENT in a unit rectangle of the output. Presets cover the shows we run;
/// the model takes any list, so a custom scene is data, not code.
struct OutputScene: Equatable, Sendable, Identifiable {
    enum Element: String, CaseIterable, Sendable {
        /// The one participant PROGRAM points at (spotlight or manual).
        case speaker
        /// Every remote with video, tiled as large as they fit.
        case gallery
        /// Every remote with video in one row.
        case strip
        /// The meeting's active screen share. A placeholder until the share subscription lands.
        case share
        /// Our own camera, what the call sees of the room.
        case selfView
        /// Every participant spotlit in the MEETING, tiled, in spotlight order: Zoom's own multi-spotlight
        /// view, for the room (2026-09-21: "no layout that shows the spotlight screen").
        case spotlight
    }

    struct Region: Equatable, Sendable {
        let element: Element
        /// Unit rectangle, top-left origin: x, y, w, h in 0...1 of the output.
        let unit: CGRect
        /// Regions are drawn in order; a PiP goes last so it sits on top.
        func rect(in bounds: CGRect) -> CGRect {
            CGRect(x: bounds.minX + unit.minX * bounds.width, y: bounds.minY + unit.minY * bounds.height,
                   width: unit.width * bounds.width, height: unit.height * bounds.height)
        }
    }

    let name: String
    let regions: [Region]
    var id: String { name }
    var elements: [Element] { regions.map(\.element) }

    static let full = CGRect(x: 0, y: 0, width: 1, height: 1)

    static let presets: [OutputScene] = [
        OutputScene(name: "SPEAKER", regions: [Region(element: .speaker, unit: full)]),
        OutputScene(name: "GALLERY", regions: [Region(element: .gallery, unit: full)]),
        OutputScene(name: "STRIP", regions: [Region(element: .strip, unit: full)]),
        OutputScene(name: "SPEAKER + STRIP", regions: [
            Region(element: .strip, unit: CGRect(x: 0, y: 0, width: 1, height: 0.2)),
            Region(element: .speaker, unit: CGRect(x: 0, y: 0.2, width: 1, height: 0.8)),
        ]),
        OutputScene(name: "SPEAKER + GALLERY", regions: [
            Region(element: .speaker, unit: CGRect(x: 0, y: 0, width: 0.72, height: 1)),
            Region(element: .gallery, unit: CGRect(x: 0.72, y: 0, width: 0.28, height: 1)),
        ]),
        OutputScene(name: "SHARE", regions: [Region(element: .share, unit: full)]),
        OutputScene(name: "SHARE + SPEAKER", regions: [
            Region(element: .share, unit: full),
            Region(element: .speaker, unit: CGRect(x: 0.74, y: 0.02, width: 0.24, height: 0.24)),
        ]),
        OutputScene(name: "SHARE + SPEAKER SIDE", regions: [
            Region(element: .share, unit: CGRect(x: 0, y: 0, width: 0.75, height: 1)),
            Region(element: .speaker, unit: CGRect(x: 0.75, y: 0, width: 0.25, height: 1)),
        ]),
        OutputScene(name: "SELF VIEW", regions: [Region(element: .selfView, unit: full)]),
        OutputScene(name: "SPOTLIGHT", regions: [Region(element: .spotlight, unit: full)]),
        OutputScene(name: "SPOTLIGHT + STRIP", regions: [
            Region(element: .strip, unit: CGRect(x: 0, y: 0, width: 1, height: 0.2)),
            Region(element: .spotlight, unit: CGRect(x: 0, y: 0.2, width: 1, height: 0.8)),
        ]),
        OutputScene(name: "SHARE + SPOTLIGHT SIDE", regions: [
            Region(element: .share, unit: CGRect(x: 0, y: 0, width: 0.75, height: 1)),
            Region(element: .spotlight, unit: CGRect(x: 0.75, y: 0, width: 0.25, height: 1)),
        ]),
        OutputScene(name: "SHARE + STRIP", regions: [
            Region(element: .strip, unit: CGRect(x: 0, y: 0, width: 1, height: 0.18)),
            Region(element: .share, unit: CGRect(x: 0, y: 0.18, width: 1, height: 0.82)),
        ]),
    ]

    /// "SPEAKER + GALLERY", "speaker+gallery", "speaker gallery" (a `+` in a query string arrives as a
    /// space) and "speaker_gallery" all name the same preset: compare with spaces, plus, dashes and
    /// underscores removed (audit P2: `/scene?name=speaker+gallery` matched by accident, then not at all).
    static func named(_ name: String) -> OutputScene? {
        func fold(_ s: String) -> String { s.uppercased().filter { !" +-_".contains($0) } }
        let key = fold(name)
        return presets.first { fold($0.name) == key }
    }

    /// The tiles for this scene: pure, so it is tested. `people(element)` is who fills an element;
    /// `aspect` is the participant tile aspect. A region with nobody draws nothing, except SHARE, which
    /// draws its placeholder so the operator can see the slot.
    func tiles(in bounds: CGRect, aspect: CGFloat, people: (Element) -> [UInt32], names: [UInt32: String]) -> [TileHostView.Entry] {
        var out: [TileHostView.Entry] = []
        for (ri, region) in regions.enumerated() {
            let r = region.rect(in: bounds)
            switch region.element {
            case .speaker:
                if let id = people(.speaker).first {
                    out.append(.init(key: "\(ri).speaker.\(id)", participant: id, frame: TileLayout.fill(r, aspect: aspect), label: names[id] ?? "\(id)"))
                }
            case .gallery:
                let ids = people(.gallery)
                for (id, rect) in zip(ids, TileLayout.grid(count: ids.count, in: r, aspect: aspect)) {
                    out.append(.init(key: "\(ri).gallery.\(id)", participant: id, frame: rect, label: names[id] ?? "\(id)"))
                }
            case .strip:
                let ids = people(.strip)
                for (id, rect) in zip(ids, TileLayout.strip(count: ids.count, in: r, aspect: aspect)) {
                    out.append(.init(key: "\(ri).strip.\(id)", participant: id, frame: rect, label: names[id] ?? "\(id)"))
                }
            case .spotlight:
                let ids = people(.spotlight)
                for (id, rect) in zip(ids, TileLayout.grid(count: ids.count, in: r, aspect: aspect)) {
                    out.append(.init(key: "\(ri).spotlight.\(id)", participant: id, frame: rect, label: names[id] ?? "\(id)"))
                }
            case .selfView:
                if let id = people(.selfView).first {
                    out.append(.init(key: "\(ri).self.\(id)", participant: id, frame: TileLayout.fill(r, aspect: aspect), label: "ARC Zoom (self)"))
                } else {
                    out.append(.init(key: "\(ri).self", participant: nil, frame: r, label: "SELF VIEW  (camera off)"))
                }
            case .share:
                if let id = people(.share).first {
                    out.append(.init(key: "\(ri).share", participant: id, frame: r.insetBy(dx: 0, dy: 0), label: "SHARE"))
                } else {
                    out.append(.init(key: "\(ri).share", participant: nil, frame: r, label: "SHARE  (nobody is sharing)"))
                }
            }
        }
        return out
    }
}
