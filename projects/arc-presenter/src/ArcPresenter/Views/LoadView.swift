//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import AVFoundation
import UniformTypeIdentifiers
import ARCShowFormat

/// The screen with no deck open (2026-09-23: "lets make a better first impression"). Built in
/// the console's language: the header bar, then a grid of ARC modules. OPEN (show folder first, the
/// real workflow), RECENT (a table, one row per item), THIS MAC (status tiles, FIX, PRE-SHOW CHECK).
/// The whole window takes a drop. Presentation only: every open path is the one it always was.
struct LoadView: View {
    @Environment(SlideEngine.self) private var engine
    @Environment(PageCache.self) private var cache
    @Environment(DisplayManager.self) private var displayManager
    @Environment(RecentFiles.self) private var recentFiles
    @Environment(DeckManager.self) private var deckManager
    @Environment(\.openWindow) private var openWindow

    nonisolated static let videoTypes: [UTType] = [.movie, .mpeg4Movie, .quickTimeMovie, .avi]
    private static let arcdeckType = UTType("com.example.arc.arcdeck") ?? .folder
    private static let allDropTypes: [UTType] = [.pdf, .movie, .mpeg4Movie, .quickTimeMovie, .avi, .folder, .zip, .fileURL]

    @State private var isDragOver = Self.dropPreview
    @State private var readiness = Readiness()
    @State private var history = WelcomeHistory()

    /// Stacked below this width: OPEN, RECENT, THIS MAC one above the other, scrolling.
    private static let stackBelow: CGFloat = 1000

    var body: some View {
        VStack(spacing: 0) {
            WelcomeHeader()
            Rectangle().fill(ARCTheme.line).frame(height: 1)
            GeometryReader { geo in
                if geo.size.width < Self.stackBelow {
                    ScrollView {
                        VStack(spacing: ARCTheme.paddingSmall) {
                            openModule.frame(height: 330)
                            recentModule.frame(height: 360)
                            ReadinessView(readiness: readiness)
                        }
                        .padding(ARCTheme.paddingMedium)
                    }
                } else {
                    VStack(spacing: ARCTheme.paddingSmall) {
                        HStack(alignment: .top, spacing: ARCTheme.paddingSmall) {
                            openModule
                                .frame(width: min(520, max(380, geo.size.width * 0.32)))
                            recentModule
                        }
                        .frame(maxHeight: .infinity)
                        ReadinessView(readiness: readiness)
                    }
                    .padding(ARCTheme.paddingMedium)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ARCTheme.background)
        .overlay { if isDragOver { DropOverlay() } }
        .animation(.easeOut(duration: 0.12), value: isDragOver)
        .onDrop(of: Self.allDropTypes, isTargeted: $isDragOver) { providers in
            handleDrop(providers)
        }
        .onReceive(NotificationCenter.default.publisher(for: .openPDFFile)) { notification in
            if let url = notification.object as? URL {
                loadFile(url: url)
            } else {
                openFile()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .showFolderAttached)) { note in
            if let folder = note.object as? URL { history.noteShow(folder) }
        }
    }

    // MARK: - Modules

    private var openModule: some View {
        OpenModule(isDragOver: isDragOver,
                   openShow: { NotificationCenter.default.post(name: .openShowFolder, object: nil) },
                   openDeck: openFile)
            .frame(maxHeight: .infinity)
            .arcModule(title: "OPEN", tint: ARCTheme.secBlue)
    }

    private var recentModule: some View {
        RecentModule(files: recentFiles.paths, history: history, open: loadFile(url:))
            .frame(maxHeight: .infinity)
    }

    // MARK: - Open paths (unchanged behaviour)

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf, Self.arcdeckType, .zip] + Self.videoTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = "Select a PDF, video, .arcdeck, or a zipped .arcdeck"

        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            loadFile(url: url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        // Try PDF first, then video types
        let types = [UTType.pdf.identifier, UTType.zip.identifier, UTType.fileURL.identifier] + Self.videoTypes.map(\.identifier)
        for typeID in types {
            if provider.hasItemConformingToTypeIdentifier(typeID) {
                provider.loadItem(forTypeIdentifier: typeID, options: nil) { data, _ in
                    if let url = data as? URL {
                        DispatchQueue.main.async { loadFile(url: url) }
                    }
                }
                return true
            }
        }
        return false
    }

    private func loadFile(url: URL) {
        // A show folder (show.json inside) opens as the show (V5).
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("show.json").path) {
            NotificationCenter.default.post(name: .openShowFolder, object: url)
            return
        }
        // A zip or a folder of one deck becomes the bundle first (DeckArchive);
        // unpacking a 300 MB deck takes seconds, so not on the main thread.
        if DeckArchive.isZip(url) || (!DeckArchive.isArcdeck(url) && !isVideoFile(url) && url.pathExtension.lowercased() != "pdf") {
            DispatchQueue.global(qos: .userInitiated).async {
                let resolved = try? DeckArchive.resolve(url)
                DispatchQueue.main.async {
                    guard let resolved else { NSSound.beep(); return }
                    loadFile(url: resolved)
                }
            }
            return
        }
        recentFiles.add(url)
        history.noteOpened(url)
        let targetSize = displayManager.externalScreenSize ?? CGSize(width: 1920, height: 1080)
        let kind: DeckKind = detectKind(url)
        deckManager.addDeck(url: url, targetSize: targetSize, kind: kind)
    }

    private func detectKind(_ url: URL) -> DeckKind {
        if url.pathExtension.lowercased() == "arcdeck" { return .arcdeck }
        if isVideoFile(url) { return .video }
        return .pdf
    }

    private func isVideoFile(_ url: URL) -> Bool { Self.isVideo(url) }

    nonisolated static func isVideo(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return videoTypes.contains(where: { type.conforms(to: $0) })
    }

    /// Debug builds only: `-ARCWelcomeDropPreview YES` holds the drop state up for a screenshot
    /// (a drag cannot be scripted into a window).
    private static var dropPreview: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "ARCWelcomeDropPreview")
        #else
        false
        #endif
    }
}

// MARK: - Header

/// The console's header bar: the mark, the app's name, its version, the clock.
private struct WelcomeHeader: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String
        return b.map { "\(v) (\($0))" } ?? v
    }

    var body: some View {
        HStack(spacing: 14) {
            Image("ARCLogo")
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fit)
                .frame(height: 56)
                .blendMode(.screen)     // the mark's black ground drops out on the bar: no tile
            Rectangle().fill(ARCTheme.line).frame(width: 1, height: 30)
            Text("ARC PRESENTER")
                .font(ARCTheme.headerBar)
                .tracking(2)
                .foregroundStyle(ARCTheme.textPrimary)
                .lineLimit(1).fixedSize()
            Text("V\(version)")
                .font(ARCTheme.mono(11, .bold))
                .foregroundStyle(ARCTheme.textSecondary)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(ARCTheme.line, lineWidth: 1))
                .lineLimit(1).fixedSize()
            #if DEBUG
            Text("DEBUG")
                .font(ARCTheme.mono(10, .heavy))
                .foregroundStyle(ARCTheme.ink)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(ARCTheme.warn)
                .cornerRadius(3)
                .fixedSize()
            #endif
            Spacer(minLength: 12)
            Text("NO DECK OPEN")
                .font(ARCTheme.mono(11, .heavy))
                .tracking(1.2)
                .foregroundStyle(ARCTheme.textTertiary)
                .lineLimit(1).fixedSize()
            ViewThatFits(in: .horizontal) {
                ClockView()
                ClockView(compact: true)
            }
            .help("Current system time")
        }
        .padding(.horizontal, ARCTheme.paddingMedium + 4)
        .frame(height: 66)
        .background(ARCTheme.surface)
        .compositingGroup()
    }
}

// MARK: - OPEN

private struct OpenModule: View {
    let isDragOver: Bool
    let openShow: () -> Void
    let openDeck: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            WelcomeButton(title: "OPEN SHOW FOLDER…", icon: "folder.fill", shortcut: "⌥⌘O", primary: true, action: openShow)
                .help("A show folder from ARC Capture: decks in run order, cues, and the show's own state (Cmd+Option+O)")
            ARCModuleCaption("Decks in run order, cues and the show's saved state, as ARC Capture wrote them.")
                .padding(.bottom, 6)
            WelcomeButton(title: "OPEN DECK…", icon: "doc.fill", shortcut: "⌘O", primary: false, action: openDeck)
                .help("One deck: an .arcdeck, a zipped .arcdeck, a PDF or a video file (Cmd+O)")
            ARCModuleCaption(".arcdeck, zipped .arcdeck, PDF or video.")
            DropWell(active: isDragOver)
                .frame(minHeight: 90, maxHeight: .infinity)
                .padding(.top, 6)
        }
    }
}

/// A full-width console button. `primary` is THE action on the screen: solid ARC red.
private struct WelcomeButton: View {
    let title: String
    let icon: String
    let shortcut: String
    let primary: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: primary ? 17 : 15, weight: .semibold))
                    .frame(width: 22)
                Text(title)
                    .font(ARCTheme.mono(primary ? 16 : 14, .heavy))
                    .tracking(1)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Text(shortcut)
                    .font(ARCTheme.mono(12, .bold))
                    .foregroundStyle(primary ? Color.white.opacity(0.7) : ARCTheme.textTertiary)
                    .lineLimit(1).fixedSize()
            }
            .foregroundStyle(primary ? Color.white : ARCTheme.textPrimary)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .frame(height: primary ? 54 : 44)
            .background(primary ? (hover ? ARCTheme.arcRed.opacity(0.88) : ARCTheme.arcRed)
                                : (hover ? ARCTheme.subGroup : ARCTheme.surfaceLight))
            .overlay(RoundedRectangle(cornerRadius: ARCTheme.cornerRadius)
                .strokeBorder(primary ? ARCTheme.arcRed : (hover ? ARCTheme.text2 : ARCTheme.line), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: ARCTheme.cornerRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

/// The drop target, drawn: the whole window takes the drop, this says so.
private struct DropWell: View {
    let active: Bool

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(active ? ARCTheme.arcRed : ARCTheme.textTertiary)
                .padding(.bottom, 4)
            Text("DROP ANYWHERE IN THIS WINDOW")
                .font(ARCTheme.mono(13, .heavy))
                .tracking(1)
                .foregroundStyle(active ? ARCTheme.textPrimary : ARCTheme.textSecondary)
                .multilineTextAlignment(.center)
            Text("SHOW FOLDER  ·  .ARCDECK  ·  PDF  ·  VIDEO")
                .font(ARCTheme.mono(11, .bold))
                .foregroundStyle(ARCTheme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(active ? ARCTheme.arcRed.opacity(0.08) : ARCTheme.ink.opacity(0.35))
        .overlay(RoundedRectangle(cornerRadius: ARCTheme.cornerRadius)
            .strokeBorder(active ? ARCTheme.arcRed : ARCTheme.line, style: StrokeStyle(lineWidth: active ? 2 : 1.5, dash: [6, 5])))
        .clipShape(RoundedRectangle(cornerRadius: ARCTheme.cornerRadius))
    }
}

/// Over the whole window while a drag is on it.
private struct DropOverlay: View {
    var body: some View {
        ZStack {
            ARCTheme.ink.opacity(0.78)
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(ARCTheme.arcRed, style: StrokeStyle(lineWidth: 3, dash: [14, 8]))
                .padding(14)
            VStack(spacing: 14) {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(ARCTheme.arcRed)
                Text("DROP TO OPEN")
                    .font(.system(size: 30, weight: .heavy, design: .monospaced))
                    .tracking(3)
                    .foregroundStyle(ARCTheme.textPrimary)
                Text("SHOW FOLDER  ·  .ARCDECK  ·  ZIPPED .ARCDECK  ·  PDF  ·  VIDEO")
                    .font(ARCTheme.mono(13, .bold))
                    .foregroundStyle(ARCTheme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }
}

// MARK: - RECENT

/// When things were opened from here, and which show folders were attached: the welcome
/// screen's own notes. RecentFiles (the menu's list) is untouched; a show folder is kept
/// here and not there, because the operator's Open Recent would try to open it as a deck.
@MainActor @Observable final class WelcomeHistory {
    private static let showsKey = "welcomeRecentShows"
    private static let openedKey = "welcomeOpenedAt"
    private static let maxShows = 4

    private(set) var shows: [URL] = []
    private(set) var openedAt: [String: Date] = [:]
    private let persisting = !AppEnvironment.isTestHost

    init() {
        let d = UserDefaults.standard
        shows = (d.stringArray(forKey: Self.showsKey) ?? []).map { URL(fileURLWithPath: $0) }
        if let raw = d.dictionary(forKey: Self.openedKey) as? [String: Double] {
            openedAt = raw.mapValues { Date(timeIntervalSince1970: $0) }
        }
    }

    func noteShow(_ folder: URL) {
        shows.removeAll { $0.standardizedFileURL == folder.standardizedFileURL }
        shows.insert(folder, at: 0)
        shows = Array(shows.prefix(Self.maxShows))
        noteOpened(folder)
    }

    func noteOpened(_ url: URL) {
        openedAt[url.standardizedFileURL.path] = Date()
        save()
    }

    private func save() {
        guard persisting else { return }
        let d = UserDefaults.standard
        d.set(shows.map(\.path), forKey: Self.showsKey)
        // Only what is still listed somewhere is worth a date; the rest ages out.
        if openedAt.count > 40 {
            openedAt = Dictionary(uniqueKeysWithValues: openedAt.sorted { $0.value > $1.value }.prefix(40).map { ($0.key, $0.value) })
        }
        d.set(openedAt.mapValues(\.timeIntervalSince1970), forKey: Self.openedKey)
    }
}

/// One RECENT row, read off the disk once (off the main thread): what it is, whether it is there.
struct RecentItem: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case show = "SHOW", arcdeck = "ARCDECK", pdf = "PDF", video = "VIDEO", zip = "ZIP", folder = "FOLDER" }
    let url: URL
    var id: String { url.path }
    var kind: Kind
    var name: String
    var folder: String
    var exists: Bool
    var content: String?
    var opened: Date?

    var icon: String {
        switch kind {
        case .show: "rectangle.stack.fill"
        case .arcdeck: "square.stack.3d.up.fill"
        case .pdf: "doc.richtext.fill"
        case .video: "film.fill"
        case .zip: "doc.zipper"
        case .folder: "folder.fill"
        }
    }

    static func kind(of url: URL) -> Kind {
        let ext = url.pathExtension.lowercased()
        if ext == "arcdeck" { return .arcdeck }
        if ext == "pdf" { return .pdf }
        if ext == "zip" { return .zip }
        if LoadView.isVideo(url) { return .video }
        if FileManager.default.fileExists(atPath: url.appendingPathComponent("show.json").path) { return .show }
        return .folder
    }

    /// A quick guess from the path alone, shown until the disk has been read.
    static func placeholder(_ url: URL, opened: Date?) -> RecentItem {
        let ext = url.pathExtension.lowercased()
        let kind: Kind = ext == "arcdeck" ? .arcdeck : ext == "pdf" ? .pdf : ext == "zip" ? .zip : LoadView.isVideo(url) ? .video : .folder
        return RecentItem(url: url, kind: kind, name: displayName(url), folder: parentPath(url), exists: true, content: nil, opened: opened)
    }

    static func inspect(_ url: URL, opened: Date?) async -> RecentItem {
        var item = placeholder(url, opened: opened)
        let fm = FileManager.default
        item.exists = fm.fileExists(atPath: url.path)
        guard item.exists else { return item }
        item.kind = kind(of: url)
        if item.opened == nil {
            item.opened = (try? url.resourceValues(forKeys: [.contentAccessDateKey]))?.contentAccessDate
        }
        switch item.kind {
        case .show:
            if let spec = try? ShowSpec.load(from: url) {
                if !spec.name.isEmpty { item.name = spec.name }
                item.content = "\(spec.items.count) ITEM\(spec.items.count == 1 ? "" : "S")"
            }
        case .pdf:
            item.content = pages(url)
        case .arcdeck:
            item.content = pages(url.appendingPathComponent("slides.pdf"))
        case .video:
            if let d = try? await AVURLAsset(url: url).load(.duration), d.seconds.isFinite, d.seconds > 0 {
                let s = Int(d.seconds.rounded())
                item.content = s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
            }
        case .zip, .folder:
            break
        }
        return item
    }

    private static func pages(_ pdf: URL) -> String? {
        guard let doc = CGPDFDocument(pdf as CFURL) else { return nil }
        let n = doc.numberOfPages
        return "\(n) SLIDE\(n == 1 ? "" : "S")"
    }

    static func displayName(_ url: URL) -> String {
        let ext = url.pathExtension.lowercased()
        return ["arcdeck", "pdf", "zip"].contains(ext) ? url.deletingPathExtension().lastPathComponent : url.lastPathComponent
    }

    static func parentPath(_ url: URL) -> String {
        let p = url.deletingLastPathComponent().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

    /// "JUST NOW", "12 MIN AGO", "3 H AGO", "YESTERDAY", "4 DAYS AGO", then the date.
    static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let s = now.timeIntervalSince(date)
        if s < 60 { return "JUST NOW" }
        if s < 3600 { return "\(Int(s / 60)) MIN AGO" }
        if s < 86_400 { return "\(Int(s / 3600)) H AGO" }
        let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: date), to: Calendar.current.startOfDay(for: now)).day ?? 0
        if days <= 1 { return "YESTERDAY" }
        if days < 7 { return "\(days) DAYS AGO" }
        let f = DateFormatter(); f.dateFormat = Calendar.current.isDate(date, equalTo: now, toGranularity: .year) ? "MMM d" : "MMM d yyyy"
        return f.string(from: date).uppercased()
    }
}

private struct RecentModule: View {
    let files: [URL]
    let history: WelcomeHistory
    let open: (URL) -> Void

    @State private var items: [RecentItem] = []
    @State private var hovered: String?
    static let rowH: CGFloat = 42

    /// Shows first-class: the listed shows and the listed files, newest first where the date is known.
    private var sources: [URL] {
        var seen = Set<String>()
        return (history.shows + files).filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    var body: some View {
        VStack(spacing: 0) {
            if items.isEmpty {
                emptyState
            } else {
                GeometryReader { geo in
                    let cols = Columns(width: geo.size.width)
                    VStack(spacing: 0) {
                        headerRow(cols)
                        Rectangle().fill(ARCTheme.line).frame(height: 1)
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                                    row(item, index: i, cols: cols)
                                    Rectangle().fill(ARCTheme.line.opacity(0.6)).frame(height: 1)
                                }
                                // Ruled, empty rows to the foot of the table: a ledger, not a void.
                                let free = geo.size.height - 29 - 30 - CGFloat(items.count) * (Self.rowH + 1)
                                ForEach(0..<max(0, Int(free / (Self.rowH + 1))), id: \.self) { _ in
                                    Color.clear.frame(height: Self.rowH)
                                    Rectangle().fill(ARCTheme.line.opacity(0.35)).frame(height: 1)
                                }
                            }
                        }
                        .scrollBounceBehavior(.basedOnSize)
                        Spacer(minLength: 0)
                        footer
                    }
                }
            }
        }
        .background(shortcuts)
        .arcModule(title: "RECENT", tint: ARCTheme.line,
                   badge: items.isEmpty ? nil : ARCBandBadge(text: "\(items.count)", fill: ARCTheme.ink))
        .task(id: sources) { await reload() }
    }

    private func reload() async {
        let urls = sources
        let dates = history.openedAt
        if items.map(\.url) != urls {
            items = urls.map { RecentItem.placeholder($0, opened: dates[$0.standardizedFileURL.path]) }
        }
        var read: [RecentItem] = []
        for url in urls {
            read.append(await Task.detached(priority: .utility) {
                await RecentItem.inspect(url, opened: dates[url.standardizedFileURL.path])
            }.value)
        }
        // Newest first where a date is known; undated keep their order after.
        let order = Dictionary(uniqueKeysWithValues: read.enumerated().map { ($1.id, $0) })
        items = read.sorted { a, b in
            switch (a.opened, b.opened) {
            case let (x?, y?): return x != y ? x > y : order[a.id]! < order[b.id]!
            case (_?, nil): return true
            case (nil, _?): return false
            default: return order[a.id]! < order[b.id]!
            }
        }
    }

    private func openRow(_ i: Int) {
        guard items.indices.contains(i) else { return }
        let item = items[i]
        guard FileManager.default.fileExists(atPath: item.url.path) else { NSSound.beep(); return }
        open(item.url)
    }

    // MARK: Table

    /// Columns drop from the right as the table narrows: folder, then opened, then content.
    struct Columns {
        let width: CGFloat
        var kind: CGFloat { 88 }
        var content: CGFloat? { width >= 520 ? 96 : nil }
        var opened: CGFloat? { width >= 640 ? 110 : nil }
        var folder: CGFloat? { width >= 800 ? min(280, max(170, width * 0.2)) : nil }
        var key: CGFloat { 44 }
    }

    private func headerRow(_ c: Columns) -> some View {
        HStack(spacing: 12) {
            Color.clear.frame(width: 22)
            cell("NAME").frame(maxWidth: .infinity, alignment: .leading)
            cell("KIND").frame(width: c.kind, alignment: .leading)
            if let w = c.content { cell("CONTENT").frame(width: w, alignment: .leading) }
            if let w = c.opened { cell("OPENED").frame(width: w, alignment: .leading) }
            if let w = c.folder { cell("FOLDER").frame(width: w, alignment: .leading) }
            cell("KEY").frame(width: c.key, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
    }

    private func cell(_ s: String) -> some View {
        Text(s).font(ARCTheme.mono(10, .heavy)).tracking(1).foregroundStyle(ARCTheme.textTertiary).lineLimit(1)
    }

    private func row(_ item: RecentItem, index: Int, cols c: Columns) -> some View {
        let on = hovered == item.id && item.exists
        let dim = !item.exists
        return Button { openRow(index) } label: {
            HStack(spacing: 12) {
                Image(systemName: dim ? "questionmark.folder" : item.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(dim ? ARCTheme.textTertiary : (item.kind == .show ? ARCTheme.secBlue : ARCTheme.textSecondary))
                    .frame(width: 22)
                Text(item.name)
                    .font(ARCTheme.mono(13, .bold))
                    .foregroundStyle(dim ? ARCTheme.textTertiary : ARCTheme.textPrimary)
                    .strikethrough(dim, color: ARCTheme.textTertiary)
                    .lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                kindTag(item).frame(width: c.kind, alignment: .leading)
                if let w = c.content {
                    Text(item.content ?? "—").font(ARCTheme.mono(12, .bold))
                        .foregroundStyle(dim ? ARCTheme.textTertiary : ARCTheme.textSecondary)
                        .lineLimit(1).frame(width: w, alignment: .leading)
                }
                if let w = c.opened {
                    Text(RecentItem.relative(item.opened)).font(ARCTheme.mono(12, .bold))
                        .foregroundStyle(dim ? ARCTheme.textTertiary : ARCTheme.textSecondary)
                        .lineLimit(1).frame(width: w, alignment: .leading)
                }
                if let w = c.folder {
                    Text(item.folder).font(ARCTheme.mono(12, .regular))
                        .foregroundStyle(ARCTheme.textTertiary)
                        .lineLimit(1).truncationMode(.head)
                        .frame(width: w, alignment: .leading)
                }
                Text(index < 9 ? "⌘\(index + 1)" : "")
                    .font(ARCTheme.mono(11, .bold))
                    .foregroundStyle(on ? ARCTheme.textPrimary : ARCTheme.textTertiary)
                    .frame(width: c.key, alignment: .trailing)
            }
            .padding(.horizontal, 10)
            .frame(height: Self.rowH)
            .background(on ? ARCTheme.subGroup : Color.clear)
            .overlay(alignment: .leading) {
                if on { Rectangle().fill(ARCTheme.arcRed).frame(width: 3) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 ? item.id : (hovered == item.id ? nil : hovered) }
        .help(item.exists ? "\(item.url.path)\nClick to open\(index == 0 ? " (Return)" : "")\(index < 9 ? " (Cmd+\(index + 1))" : "")"
                          : "Not found at \(item.url.path). Moved, renamed or on a drive that is not mounted.")
    }

    private func kindTag(_ item: RecentItem) -> some View {
        Text(item.exists ? item.kind.rawValue : "MISSING")
            .font(ARCTheme.mono(10, .heavy))
            .tracking(0.8)
            .foregroundStyle(!item.exists ? ARCTheme.warn : (item.kind == .show ? ARCTheme.ink : ARCTheme.textPrimary))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(!item.exists ? Color.clear : (item.kind == .show ? ARCTheme.secBlue : ARCTheme.surfaceLight))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(!item.exists ? ARCTheme.warn.opacity(0.7) : (item.kind == .show ? ARCTheme.secBlue : ARCTheme.line), lineWidth: 1))
            .cornerRadius(3)
            .lineLimit(1).fixedSize()
    }

    private var footer: some View {
        HStack(spacing: 18) {
            Text("RETURN  opens the top row").lineLimit(1)
            Text("⌘1–⌘9  open a row").lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(ARCTheme.mono(10, .bold))
        .foregroundStyle(ARCTheme.textTertiary)
        .padding(.horizontal, 10)
        .padding(.top, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 30, weight: .regular))
                .foregroundStyle(ARCTheme.textTertiary)
            Text("NOTHING OPENED YET")
                .font(ARCTheme.mono(13, .heavy))
                .tracking(1.2)
                .foregroundStyle(ARCTheme.textSecondary)
            Text("Show folders and decks you open are listed here, newest first.")
                .font(ARCTheme.mono(11, .regular))
                .foregroundStyle(ARCTheme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Return opens the top row, Cmd+1 to Cmd+9 a row by number.
    private var shortcuts: some View {
        ZStack {
            if let first = items.first, first.exists {
                Button("") { openRow(0) }.keyboardShortcut(.return, modifiers: [])
            }
            ForEach(0..<min(9, items.count), id: \.self) { i in
                Button("") { openRow(i) }.keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
        }
        .buttonStyle(.plain)
        .opacity(0)
        .frame(width: 0, height: 0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
