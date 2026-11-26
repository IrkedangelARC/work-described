//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import AppKit
import PDFKit
import AVFoundation
import UniformTypeIdentifiers

/// One thing that can go into a show: an arcdeck, a deck to capture, a
/// Slides link, a PDF, an image, a movie, or a folder to browse into.
struct ShowItem: Identifiable, Hashable {
    enum Kind: String { case arcdeck, deck, link, pdf, image, movie, folder }
    let id = UUID()
    let url: URL
    let kind: Kind
    let title: String
    let detail: String
    var thumbnail: NSImage?
    static func == (a: ShowItem, b: ShowItem) -> Bool { a.id == b.id }
    func hash(into h: inout Hasher) { h.combine(id) }

    static func kind(of url: URL) -> Kind? {
        let ext = url.pathExtension.lowercased()
        if ext == "arcdeck" { return .arcdeck }
        if ["pptx", "ppt", "key"].contains(ext) { return .deck }
        if ["webloc", "url"].contains(ext) { return .link }
        if ext == "pdf" { return .pdf }
        if ["png", "jpg", "jpeg", "heic", "tif", "tiff"].contains(ext) { return .image }
        if ["mp4", "mov", "m4v"].contains(ext) { return .movie }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue, !ext.isEmpty == false { return .folder }
        return nil
    }

    /// Build with the facts a card shows: slides, pages, length.
    static func make(_ url: URL) -> ShowItem? {
        guard let kind = kind(of: url) else { return nil }
        let name = url.lastPathComponent
        var detail = ""; var thumb: NSImage? = nil
        switch kind {
        case .arcdeck:
            if let data = try? Data(contentsOf: url.appendingPathComponent("manifest.json")),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let slides = json["slides"] as? [[String: Any]] {
                let v = slides.filter { ($0["type"] as? String) == "video" }.count
                detail = "\(slides.count) slides" + (v > 0 ? ", \(v) with video" : "")
            }
            thumb = PDFDocument(url: url.appendingPathComponent("slides.pdf"))?.page(at: 0)?.thumbnail(of: NSSize(width: 256, height: 144), for: .cropBox)
        case .pdf:
            if let d = PDFDocument(url: url) { detail = "\(d.pageCount) pages"; thumb = d.page(at: 0)?.thumbnail(of: NSSize(width: 256, height: 144), for: .cropBox) }
        case .image:
            detail = "still"; thumb = NSImage(contentsOf: url)
        case .movie:
            let asset = AVURLAsset(url: url)
            let secs = CMTimeGetSeconds(asset.duration)
            detail = secs.isFinite ? String(format: "%d:%02d", Int(secs) / 60, Int(secs) % 60) : "movie"
            let gen = AVAssetImageGenerator(asset: asset); gen.appliesPreferredTrackTransform = true; gen.maximumSize = CGSize(width: 256, height: 144)
            if let cg = try? gen.copyCGImage(at: CMTime(seconds: 0.5, preferredTimescale: 600), actualTime: nil) { thumb = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height)) }
        case .deck:
            detail = url.pathExtension.lowercased() == "key" ? "Keynote, captured at build" : "PowerPoint, captured at build"
        case .link:
            detail = "Google Slides link, captured at build"
        case .folder:
            detail = "folder"
        }
        return ShowItem(url: url, kind: kind, title: name, detail: detail, thumbnail: thumb)
    }
}

/// The SHOW tab's state: a folder being browsed, the stack, and the build.
@MainActor @Observable final class ShowModel {
    var showFolder: URL?
    var browseFolder: URL?
    var browseItems: [ShowItem] = []
    var stack: [ShowItem] = []
    var name: String = ""
    var log: [String] = []
    var building = false
    var builtDeck: URL?
    var status = "choose a show folder"

    private static let lastFolderKey = "lastShowFolder"
    /// Reopen the last show folder on launch (V2 hardening, 2026-09-12).
    func restoreLastFolder() {
        guard showFolder == nil, let p = UserDefaults.standard.string(forKey: Self.lastFolderKey),
              FileManager.default.fileExists(atPath: p) else { return }
        chooseShowFolder(URL(fileURLWithPath: p))
    }

    func chooseShowFolder(_ url: URL) {
        showFolder = url
        UserDefaults.standard.set(url.path, forKey: Self.lastFolderKey)
        if name.isEmpty { name = url.lastPathComponent }
        load()
        browse(url)
    }

    func browse(_ url: URL) {
        browseFolder = url
        let fm = FileManager.default
        let names = ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).filter { !$0.hasPrefix(".") && !$0.hasPrefix("~$") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let own = Set([name + ".arcdeck", url.lastPathComponent + ".arcdeck", "show.json"])
        browseItems = names.filter { !own.contains($0) && $0 != ".arcbuild" }.compactMap { n in
            let u = url.appendingPathComponent(n)
            if let k = ShowItem.kind(of: u) { return ShowItem.make(u) }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue { return ShowItem(url: u, kind: .folder, title: n, detail: "folder", thumbnail: nil) }
            return nil
        }
        status = "\(browseItems.count) item(s) in \(url.lastPathComponent)"
    }

    func browseUp() { if let b = browseFolder { browse(b.deletingLastPathComponent()) } }
    func add(_ item: ShowItem) { if item.kind == .folder { browse(item.url) } else { stack.append(item); status = "added \(item.title)" } }
    func remove(_ item: ShowItem) { stack.removeAll { $0.id == item.id } }
    func move(from: IndexSet, to: Int) { stack.move(fromOffsets: from, toOffset: to) }

    var showJSON: URL? { showFolder?.appendingPathComponent("show.json") }

    func save() {
        guard let showJSON else { status = "choose a show folder first"; return }
        let spec: [String: Any] = ["name": name, "items": stack.map { ["path": $0.url.path, "kind": $0.kind.rawValue] }]
        if let data = try? JSONSerialization.data(withJSONObject: spec, options: [.prettyPrinted]) {
            try? data.write(to: showJSON); status = "saved \(stack.count) item(s) to show.json"
        }
    }

    func load() {
        guard let showJSON, let data = try? Data(contentsOf: showJSON),
              let spec = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        if let n = spec["name"] as? String, !n.isEmpty { name = n }
        let items = (spec["items"] as? [[String: Any]]) ?? []
        stack = items.compactMap { ($0["path"] as? String).flatMap { ShowItem.make(URL(fileURLWithPath: $0)) } }
        status = "loaded \(stack.count) item(s) from show.json"
    }

    /// The capture running inside a build, for the monitor.
    var currentSession: CaptureSession? { builder?.currentSession }
    private var builder: ShowBuilder?

    /// `useStack` writes show.json from the stack first (SHOW tab); a folder
    /// build from the CAPTURE tab takes the folder's files in name order.
    /// Runs the Swift ShowBuilder in-process (V2 refactor: no Python).
    func build(useStack: Bool = true, force: Bool = false, openInPresenter: Bool = true) {
        guard let showFolder else { status = "choose a show folder first"; return }
        if useStack { save() }
        building = true; log = []; builtDeck = nil; status = "building…"
        let b = ShowBuilder(folder: showFolder, name: name.isEmpty ? nil : name, items: useStack ? stack.map(\.url) : nil)
        b.force = force; b.openInPresenter = openInPresenter
        b.log = { [weak self] line in Task { @MainActor in self?.log.append(line); if (self?.log.count ?? 0) > 400 { self?.log.removeFirst(100) } } }
        builder = b
        Task { @MainActor in
            do {
                let r = try await b.build()
                builtDeck = r.deck; status = "built " + r.deck.lastPathComponent
            } catch {
                log.append("FAILED: \(error.localizedDescription)"); status = "build failed; see the log"
            }
            building = false; builder = nil
        }
    }
}

struct ShowBuilderView: View {
    @Bindable var model: ShowModel
    private let browseW: CGFloat = 380

    var body: some View {
        VStack(spacing: 0) {
            header
            ARCTheme.divider.frame(height: 1)
            Text("1  SHOW FOLDER picks where the show lives.   2  Add items from BROWSE in show order; drag the handle to reorder.   3  BUILD SHOW makes one deck from them and opens it in Presenter. Captured decks merge as they are; PowerPoint, Keynote, PDF and Slides links are captured during the build.")
                .font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.textSecondary)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, ARCTheme.paddingMedium).padding(.top, 8)
            HStack(spacing: 10) {
                browsePane.frame(width: browseW)
                stackPane.frame(maxWidth: .infinity)
            }
            .padding(ARCTheme.paddingMedium)
            ARCTheme.divider.frame(height: 1)
            logPane
        }
        .background(ARCTheme.background)
        .onAppear { model.restoreLastFolder() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("ARC CAPTURE").font(ARCTheme.caption).foregroundStyle(ARCTheme.textSecondary).tracking(1.2)
            Text("SHOW").font(ARCTheme.caption).foregroundStyle(ARCTheme.textPrimary)
            Spacer()
            HStack(spacing: 6) {
                Circle().fill(model.building ? ARCTheme.liveRed : (model.builtDeck != nil ? ARCTheme.readyGreen : ARCTheme.textTertiary)).frame(width: 10, height: 10)
                Text(model.status.uppercased()).font(ARCTheme.statusBadge).foregroundStyle(ARCTheme.textPrimary).lineLimit(1)
            }
            .padding(.horizontal, 10).padding(.vertical, 6).background(ARCTheme.surfaceLight).cornerRadius(ARCTheme.cornerRadius)
        }
        .padding(.horizontal, ARCTheme.paddingMedium).padding(.vertical, 8).background(ARCTheme.surface)
    }

    // MARK: Browse

    private var browsePane: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                ARCChip("SHOW FOLDER") { chooseShowFolder() }.help("Choose the folder the show lives in: show.json and the built deck are written here")
                ARCChip("ADD FILES…") { chooseShowFolder() }.help("Pick arcdecks, decks, links or media from anywhere and add them to the stack")
                ARCChip("UP") { model.browseUp() }.disabled(model.browseFolder == nil).help("Browse the folder above")
                Spacer()
            }
            Text(model.browseFolder?.path ?? "choose the show folder: it holds show.json and the built deck")
                .font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.textSecondary).lineLimit(2).truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(model.browseItems) { item in
                        HStack(spacing: 8) {
                            thumb(item, w: 64, h: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(ARCTheme.mono(12, .heavy)).foregroundStyle(ARCTheme.textPrimary).lineLimit(1)
                                Text(item.detail).font(ARCTheme.mono(10, .regular)).foregroundStyle(ARCTheme.textSecondary).lineLimit(1)
                            }
                            Spacer()
                            ARCChip(item.kind == .folder ? "OPEN" : "ADD") { model.add(item) }
                        }
                        .padding(6).background(ARCTheme.moduleBg).cornerRadius(4)
                        .onTapGesture(count: 2) { model.add(item) }
                    }
                }
            }
        }
        .arcModule(title: "BROWSE", tint: ARCTheme.secBlue)
    }

    // MARK: Stack

    private var stackPane: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Text("NAME").font(ARCTheme.moduleTitle).foregroundStyle(ARCTheme.textSecondary)
                TextField("show name", text: $model.name).textFieldStyle(.roundedBorder).focusEffectDisabled().font(ARCTheme.mono(12, .regular))
                Text("\(model.stack.count) item(s), \(totalSlides) slide(s)").font(ARCTheme.caption).foregroundStyle(ARCTheme.textSecondary)
            }
            if model.stack.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "square.stack.3d.up").font(.system(size: 28)).foregroundStyle(ARCTheme.textTertiary)
                    Text("ADD ITEMS FROM BROWSE; DRAG TO REORDER").font(ARCTheme.statusBadge).foregroundStyle(ARCTheme.textTertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(Array(model.stack.enumerated()), id: \.element.id) { i, item in
                        HStack(spacing: 10) {
                            Text(String(format: "%02d", i + 1)).font(ARCTheme.mono(16, .heavy)).foregroundStyle(ARCTheme.arcRed).frame(width: 30)
                            thumb(item, w: 128, h: 72)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(item.title).font(ARCTheme.mono(13, .heavy)).foregroundStyle(ARCTheme.textPrimary).lineLimit(1)
                                Text(item.detail).font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.textSecondary)
                                Text(item.kind.rawValue.uppercased()).font(ARCTheme.mono(9, .heavy)).foregroundStyle(badgeColor(item.kind))
                            }
                            Spacer()
                            Image(systemName: "line.3.horizontal").foregroundStyle(ARCTheme.textTertiary)
                            ARCChip("REMOVE") { model.remove(item) }
                        }
                        .padding(6).background(ARCTheme.moduleBg).cornerRadius(4)
                        .listRowBackground(Color.clear).listRowSeparator(.hidden).listRowInsets(EdgeInsets(top: 2, leading: 0, bottom: 2, trailing: 0))
                    }
                    .onMove { from, to in model.move(from: from, to: to) }
                }
                .listStyle(.plain).scrollContentBackground(.hidden)
            }
            HStack(spacing: 8) {
                ARCChip("SAVE") { model.save() }.disabled(model.showFolder == nil).help("Write the stack to show.json in the show folder (BUILD does this too)")
                ARCChip("REVEAL DECK") { if let d = model.builtDeck { NSWorkspace.shared.activateFileViewerSelecting([d]) } }.disabled(model.builtDeck == nil)
                Spacer()
                Button(action: { model.build() }) {
                    Text(model.building ? "BUILDING…" : "BUILD SHOW")
                        .font(ARCTheme.mono(15, .heavy)).foregroundStyle(.white)
                        .padding(.horizontal, 22).padding(.vertical, 10)
                        .background(model.stack.isEmpty || model.building || model.showFolder == nil ? ARCTheme.surfaceLight : ARCTheme.arcRed)
                        .cornerRadius(ARCTheme.cornerRadius)
                }
                .buttonStyle(.plain).disabled(model.stack.isEmpty || model.building || model.showFolder == nil)
            }
        }
        .arcModule(title: "STACK", tint: ARCTheme.secOrange)
    }

    private var totalSlides: Int {
        model.stack.reduce(0) { acc, i in
            if let n = Int(i.detail.split(separator: " ").first ?? ""), i.kind == .arcdeck || i.kind == .pdf { return acc + n }
            return acc + (i.kind == .image || i.kind == .movie ? 1 : 0)
        }
    }

    // MARK: Log

    private var logPane: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { i, l in
                        Text(l).font(ARCTheme.mono(11, .regular))
                            .foregroundStyle(l.hasPrefix("wrote") ? ARCTheme.readyGreen : (l.contains("FAILED") || l.contains("Traceback") ? ARCTheme.warn : ARCTheme.textPrimary))
                            .lineLimit(1).id(i)
                    }
                }
                .padding(8)
            }
            .frame(height: 140)
            .onChange(of: model.log.count) { _, n in if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) } }
        }
        .background(ARCTheme.moduleBg)
    }

    // MARK: Bits

    private func thumb(_ item: ShowItem, w: CGFloat, h: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3).fill(ARCTheme.surfaceLight)
            if let t = item.thumbnail {
                Image(nsImage: t).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: icon(item.kind)).font(.system(size: h * 0.45)).foregroundStyle(ARCTheme.textSecondary)
            }
        }
        .frame(width: w, height: h).clipShape(RoundedRectangle(cornerRadius: 3))
        .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(badgeColor(item.kind), lineWidth: 1))
    }

    private func icon(_ k: ShowItem.Kind) -> String {
        switch k {
        case .folder: return "folder"
        case .deck: return "rectangle.on.rectangle"
        case .link: return "link"
        case .movie: return "film"
        case .image: return "photo"
        case .pdf: return "doc"
        case .arcdeck: return "square.stack"
        }
    }
    private func badgeColor(_ k: ShowItem.Kind) -> Color {
        switch k {
        case .arcdeck: return ARCTheme.arcRed
        case .movie: return ARCTheme.secCrimson
        case .deck, .link: return ARCTheme.secBlue
        case .pdf, .image: return ARCTheme.secGreen
        case .folder: return ARCTheme.line
        }
    }


    /// One panel for both jobs: a plain folder becomes the show folder;
    /// arcdecks (packages), decks, links and media go onto the stack. The
    /// folder-only panel greyed every arcdeck out (2026-09-12).
    private func chooseShowFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = true; panel.allowsMultipleSelection = true
        panel.treatsFilePackagesAsDirectories = false
        panel.message = "Choose the show folder, or pick arcdecks and media to add to the stack"
        guard panel.runModal() == .OK else { return }
        var addedAny = false
        for url in panel.urls {
            if let item = ShowItem.make(url), item.kind != .folder {
                if model.showFolder == nil { model.chooseShowFolder(url.deletingLastPathComponent()) }
                model.add(item); addedAny = true
            } else {
                model.chooseShowFolder(url)
            }
        }
        if addedAny { model.status = "\(model.stack.count) item(s) on the stack" }
    }
}
