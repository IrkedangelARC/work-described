//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import UniformTypeIdentifiers

/// Setup, in the ARC PTZ console language: header bar, modules on the
/// module ground with section-coloured borders, ARC red for the one action.
struct CaptureSetupView: View {
    @Bindable var session: CaptureSession
    @State private var dwellText = "0.3"
    @State private var maxRecordText = "30"
    @State private var dropTargeted = false
    @State private var linkText = ""
    private var readiness: Readiness { CaptureLaunch.readiness }
    /// A whole show folder dropped or chosen on this tab (2026-09-12).
    @State private var folderBuild: ShowModel? = nil
    /// A run of this deck that died with slides already captured (V3, plan 1.2).
    @State private var resumable: CaptureCheckpoint.Progress? = nil

    var body: some View {
        if let fb = folderBuild {
            FolderBuildView(model: fb, onBack: { folderBuild = nil })
        } else {
            setupBody
        }
    }

    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    /// Re-read after a control window opens or closes, so its glyph lights and unlights.
    @State private var windowsTick = 0

    private var state: CaptureScreenState { session.sourceFile == nil ? .idle : (readiness.allRequiredOK ? .ready : .error) }

    private var setupBody: some View {
        VStack(spacing: 0) {
            CaptureHeader(screen: "DECK", subject: session.sourceFile?.lastPathComponent, state: state,
                          stateDetail: session.sourceFile != nil && !readiness.allRequiredOK ? "something to fix in STATUS" : nil)
            ARCTheme.divider.frame(height: 1)
            VStack(spacing: ARCTheme.paddingSmall) {
                if let r = resumable, let n = r.lastPptxSlide { unfinishedModule(r, n) }
                deckModule.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, ARCTheme.paddingMedium).padding(.vertical, ARCTheme.paddingSmall)
            .frame(maxHeight: .infinity)
            // One row when the window is wide enough for ACTION, OPTIONS and the eight STATUS tiles side by side;
            // otherwise STATUS takes a row of its own (the deck picture gives up the height), never squeezed.
            ViewThatFits(in: .horizontal) {
                CaptureFooter { actionGroup; optionsGroup; statusGroup; Spacer(minLength: 0) }
                VStack(spacing: 0) {
                    CaptureFooter { actionGroup; optionsGroup; Spacer(minLength: 0) }
                    CaptureFooter { statusGroup; Spacer(minLength: 0) }
                }
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .background(ARCTheme.background)
        .onAppear {
            resumable = session.resumable()?.progress; readiness.refresh()
            if let (url, begin) = CaptureLaunch.take() {
                session.sourceFile = url; session.outputDirectory = url.deletingLastPathComponent()
                if begin { Task { try? await Task.sleep(for: .seconds(2)); session.resumeRequested = false; await session.beginCapture() } }
            }
        }
        .onChange(of: session.sourceFile) { resumable = session.resumable()?.progress }
        .onChange(of: session.outputDirectory) { resumable = session.resumable()?.progress }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in windowsTick += 1 }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.willCloseNotification)) { _ in DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { windowsTick += 1 } }
    }

    // MARK: Footer groups

    private var actionGroup: some View {
        FooterRow {
            if let r = resumable, let n = r.lastPptxSlide {
                ARCActionButton("RESUME FROM SLIDE \(n + 1)", fill: ARCTheme.secGreen) { session.resumeRequested = true; Task { await session.beginCapture() } }
                ARCChip("START OVER", tint: ARCTheme.secOrange) { session.resumeRequested = false; resumable = nil }
            } else {
                ARCActionButton("BEGIN CAPTURE", enabled: session.sourceFile != nil) { session.resumeRequested = false; Task { await session.beginCapture() } }
            }
        }
        .arcModule(title: "ACTION", tint: ARCTheme.secOrange, hugging: true)
    }

    private var optionsGroup: some View {
        FooterRow {
            ARCStatusTile(name: "DWELL", state: String(format: "%.1f S", session.dwellTime), level: .off, widest: ("DWELL", "10.0 S"))
            ARCStatusTile(name: "MAX CLIP", state: "\(Int(session.maxRecordingTime)) S", level: .off, widest: ("MAX CLIP", "999 S"))
            ARCStatusTile(name: "KEEP PNGS", state: session.keepPNGs ? "ON" : "OFF", level: session.keepPNGs ? .warn : .off, widest: ("KEEP PNGS", "OFF"))
        }
        .arcModule(title: "OPTIONS", tint: ARCTheme.secOrange, hugging: true)
        .arcExpandButton("Dwell, max clip, keep PNGs, with what each one does", on: windowsTick >= 0 && ControlWindow.isOpen(title: CaptureWindows.options.title)) { toggle(CaptureWindows.options) }
    }

    private var statusGroup: some View {
        FooterRow { ReadinessTiles(readiness: readiness) }
            .arcModule(title: "STATUS", tint: readiness.allRequiredOK ? ARCTheme.secGreen : ARCTheme.liveRed, hugging: true)
            .arcExpandButton("Every check, its hint and the button that fixes it", on: windowsTick >= 0 && ControlWindow.isOpen(title: CaptureWindows.readiness.title)) { toggle(CaptureWindows.readiness) }
    }

    private func toggle(_ w: (id: String, title: String)) {
        ControlWindow.toggle(id: w.id, title: w.title, open: openWindow, dismiss: dismissWindow)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { windowsTick += 1 }
    }

    // MARK: DECK (blue, IN): the picture of this screen. A chosen deck shows itself; none shows the drop target.

    private var deckModule: some View {
        VStack(spacing: 8) {
            if let file = session.sourceFile {
                DeckThumb(url: file).frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black).cornerRadius(3)
                HStack(spacing: 10) {
                    Text(file.pathExtension.isEmpty ? "LINK" : file.pathExtension.uppercased()).font(ARCTheme.mono(11, .heavy)).foregroundStyle(ARCTheme.ink)
                        .padding(.horizontal, 6).padding(.vertical, 3).background(ARCTheme.secBlue).cornerRadius(3)
                    Text(file.lastPathComponent).font(ARCTheme.mono(13, .heavy)).foregroundStyle(ARCTheme.textPrimary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    ARCChip("CHANGE", tint: ARCTheme.secBlue) { openFile() }
                }
                HStack(spacing: 10) {
                    Text("OUTPUT").font(ARCTheme.mono(11, .heavy)).foregroundStyle(ARCTheme.textSecondary)
                    Text((session.outputDirectory ?? file.deletingLastPathComponent()).path).font(ARCTheme.mono(12, .regular)).foregroundStyle(ARCTheme.textSecondary).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 6)
                    ARCChip("FOLDER", tint: ARCTheme.secBlue) { chooseOutput() }
                }
            } else {
                Button(action: openFile) {
                    VStack(spacing: 8) {
                        Image(systemName: "arrow.down.doc").font(.system(size: 34)).foregroundStyle(ARCTheme.arcRed)
                        Text("SELECT A DECK, OR A WHOLE SHOW FOLDER").font(ARCTheme.mono(15, .heavy)).foregroundStyle(ARCTheme.textPrimary)
                        Text("drop a .pptx, .key, .pdf or a folder of decks and media here").font(ARCTheme.mono(12, .regular)).foregroundStyle(ARCTheme.textSecondary)
                        VStack(alignment: .leading, spacing: 6) {
                            help("A PowerPoint, Keynote, PDF or Google Slides deck becomes an ARC deck that Presenter plays as the presenter would click it: every transition, build, movie and sound, one click each.")
                            help("The deck opens in its own app and plays on the second display; this window shows every step. Hands off the mouse and keyboard until it says COMPLETE: about 3 s a slide plus every movie.")
                            help("The deck is written next to the source and opens in ARC Presenter if it is running.")
                        }
                        .frame(maxWidth: 560).padding(.top, 18)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .overlay(RoundedRectangle(cornerRadius: ARCTheme.cornerRadius).strokeBorder(dropTargeted ? ARCTheme.arcRed : ARCTheme.line, style: StrokeStyle(lineWidth: 1, dash: [6, 3])))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                HStack(spacing: 8) {
                    Text("OR A GOOGLE SLIDES LINK").font(ARCTheme.mono(11, .heavy)).foregroundStyle(ARCTheme.textSecondary)
                    TextField("https://docs.google.com/presentation/d/…", text: $linkText)
                        .textFieldStyle(.roundedBorder).focusEffectDisabled().font(ARCTheme.mono(12, .regular))
                        .onSubmit(useLink)
                    ARCChip("USE LINK", tint: ARCTheme.secBlue) { useLink() }
                }
            }
        }
        .arcModule(title: "DECK", tint: dropTargeted ? ARCTheme.arcRed : ARCTheme.secBlue,
                   badge: session.sourceFile == nil ? nil : ARCBandBadge(text: "CHOSEN", fill: ARCTheme.ink))
        // Drop a .pptx anywhere on the DECK module (the label promised it since day one; no handler existed, 2026-09-12).
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            guard let p = providers.first else { return false }
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                guard let url else { return }
                let ext = url.pathExtension.lowercased()
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue, !["arcdeck", "key"].contains(ext) {
                    Task { @MainActor in
                        if ShowRouting.isShowFolder(url) { ShowRouting.open(url) } else { let m = ShowModel(); m.chooseShowFolder(url); folderBuild = m }
                    }
                    return
                }
                if ext == "webloc", let link = Self.linkURL(in: url) {
                    Task { @MainActor in session.sourceFile = link; session.outputDirectory = url.deletingLastPathComponent() }
                    return
                }
                guard ["pptx", "ppt", "key", "pdf"].contains(ext) else { return }
                Task { @MainActor in
                    session.sourceFile = url
                    session.outputDirectory = url.deletingLastPathComponent()
                }
            }
            return true
        }
    }

    // MARK: UNFINISHED RUN (green): a crashed run is worth more than a fresh start (V3, plan 1.2).

    private func unfinishedModule(_ r: CaptureCheckpoint.Progress, _ n: Int) -> some View {
        Text("\(r.slides.count) slide\(r.slides.count == 1 ? "" : "s") of this deck are already captured, up to slide \(n), left by a run that did not finish. RESUME in the footer carries on from slide \(n + 1); START OVER forgets them.")
            .font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.textPrimary).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
            .arcModule(title: "UNFINISHED RUN", tint: ARCTheme.secGreen, badge: ARCBandBadge(text: "\(r.slides.count) SLIDES", fill: ARCTheme.ink))
    }

    private func help(_ text: String) -> some View {
        Text(text).font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.textSecondary).multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
    }

    private func useLink() {
        let t = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: t), url.scheme?.hasPrefix("http") == true else { return }
        session.sourceFile = url
        session.outputDirectory = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
    }

    /// URL inside a Finder .webloc (a plist with a URL key).
    static func linkURL(in webloc: URL) -> URL? {
        guard let data = try? Data(contentsOf: webloc),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let s = plist["URL"] as? String else { return nil }
        return URL(string: s)
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: "pptx")!, .init(filenameExtension: "ppt")!, .init(filenameExtension: "key")!, .pdf]
        panel.treatsFilePackagesAsDirectories = false
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = true
        panel.message = "Choose one deck, or a show folder to convert whole"
        if panel.runModal() == .OK, let url = panel.url {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue, url.pathExtension.lowercased() != "key" {
                if ShowRouting.isShowFolder(url) { ShowRouting.open(url); return }
                let m = ShowModel(); m.chooseShowFolder(url); folderBuild = m
                return
            }
            session.sourceFile = url
            session.outputDirectory = url.deletingLastPathComponent()
        }
    }

    private func chooseOutput() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { session.outputDirectory = url }
    }
}


/// A whole show folder on the CAPTURE tab: what is in it, the folder
/// options, one BUILD, and the log. Files go in name order; the SHOW tab is
/// for hand-ordered stacks.
struct FolderBuildView: View {
    @Bindable var model: ShowModel
    var onBack: () -> Void
    @State private var force = false
    @State private var openInPresenter = true

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("ARC CAPTURE").font(ARCTheme.caption).foregroundStyle(ARCTheme.textSecondary).tracking(1.2)
                Text(model.showFolder?.lastPathComponent ?? "show folder").font(ARCTheme.caption).foregroundStyle(ARCTheme.textPrimary).lineLimit(1)
                Spacer()
                HStack(spacing: 6) {
                    Circle().fill(model.building ? ARCTheme.liveRed : (model.builtDeck != nil ? ARCTheme.readyGreen : ARCTheme.textTertiary)).frame(width: 10, height: 10)
                    Text(model.status.uppercased()).font(ARCTheme.statusBadge).foregroundStyle(ARCTheme.textPrimary).lineLimit(1)
                }
                .padding(.horizontal, 10).padding(.vertical, 6).background(ARCTheme.surfaceLight).cornerRadius(ARCTheme.cornerRadius)
            }
            .padding(.horizontal, ARCTheme.paddingMedium).padding(.vertical, 8).background(ARCTheme.surface)
            ARCTheme.divider.frame(height: 1)

            VStack(spacing: 10) {
              // While a deck is captured the live monitor takes the page: the plan and the options are fixed by
              // then, and the four stacked did not fit a 1512 x 982 screen (2026-09-23).
              if model.currentSession == nil {
                Text("Every deck, link and media file in this folder becomes part of ONE deck, in file name order (1.01, 1.02 … sorts naturally). Decks are captured one after another; already captured items are merged as they are. Rename files to reorder, remove to drop, then build again: unchanged decks are not captured twice.")
                    .font(ARCTheme.mono(12, .regular)).foregroundStyle(ARCTheme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .background(RoundedRectangle(cornerRadius: ARCTheme.cornerRadius).fill(ARCTheme.moduleBg))

                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(Array(model.browseItems.filter { $0.kind != .folder }.enumerated()), id: \.element.id) { i, item in
                            HStack(spacing: 8) {
                                Text(String(format: "%02d", i + 1)).font(ARCTheme.mono(13, .heavy)).foregroundStyle(ARCTheme.arcRed).frame(width: 26)
                                ZStack {
                                    RoundedRectangle(cornerRadius: 3).fill(ARCTheme.surfaceLight)
                                    if let t = item.thumbnail { Image(nsImage: t).resizable().aspectRatio(contentMode: .fit) }
                                }
                                .frame(width: 64, height: 36).clipShape(RoundedRectangle(cornerRadius: 3))
                                Text(item.title).font(ARCTheme.mono(12, .heavy)).foregroundStyle(ARCTheme.textPrimary).lineLimit(1)
                                Spacer()
                                Text(item.detail).font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.textSecondary).lineLimit(1)
                                Text(item.kind.rawValue.uppercased()).font(ARCTheme.mono(9, .heavy)).foregroundStyle(ARCTheme.textSecondary).frame(width: 60, alignment: .trailing)
                            }
                            .padding(6).background(ARCTheme.moduleBg).cornerRadius(4)
                        }
                    }
                }
                .frame(minHeight: 120)
                .arcModule(title: "1  WHAT WILL BE BUILT, IN THIS ORDER", tint: ARCTheme.secBlue)

                HStack(alignment: .top, spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            Text("DECK NAME").font(ARCTheme.moduleTitle).foregroundStyle(ARCTheme.textSecondary)
                            TextField("show name", text: $model.name).textFieldStyle(.roundedBorder).focusEffectDisabled().font(ARCTheme.mono(12, .regular))
                        }
                        Text("Name of the combined deck; written into this folder.").font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: $force) { Text("RECAPTURE EVERYTHING").font(ARCTheme.moduleTitle).foregroundStyle(ARCTheme.textSecondary) }.toggleStyle(.switch).controlSize(.small)
                        Text("Off: decks captured before and unchanged since are reused. On: every deck is captured again.").font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: $openInPresenter) { Text("OPEN IN PRESENTER WHEN DONE").font(ARCTheme.moduleTitle).foregroundStyle(ARCTheme.textSecondary) }.toggleStyle(.switch).controlSize(.small)
                        Text("Loads the finished deck into ARC Presenter as a new tab if it is running.").font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .arcModule(title: "2  FOLDER OPTIONS", tint: ARCTheme.secOrange)
              }

                if let s = model.currentSession {
                    // A deck is being captured right now: the live monitor, as tall as the window allows.
                    CaptureMonitorView(session: s).frame(maxHeight: .infinity)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 1) {
                            ForEach(Array(model.log.enumerated()), id: \.offset) { i, l in
                                Text(l).font(ARCTheme.mono(11, .regular))
                                    .foregroundStyle(l.hasPrefix("wrote") ? ARCTheme.readyGreen : (l.contains("FAILED") || l.contains("Traceback") ? ARCTheme.warn : ARCTheme.textPrimary))
                                    .lineLimit(1).id(i)
                            }
                            if model.log.isEmpty { Text("the build log appears here; while a deck is captured the live monitor shows above it").font(ARCTheme.mono(11, .regular)).foregroundStyle(ARCTheme.textTertiary) }
                        }
                    }
                    .onChange(of: model.log.count) { _, n in if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) } }
                }
                .frame(minHeight: model.currentSession == nil ? 100 : 60, maxHeight: model.currentSession == nil ? .infinity : 90)
                .arcModule(title: "3  BUILD LOG", tint: model.builtDeck != nil ? ARCTheme.secGreen : ARCTheme.line)

                HStack(spacing: 10) {
                    Button(action: onBack) {
                        Text("BACK").font(ARCTheme.statusBadge).foregroundStyle(ARCTheme.textPrimary).padding(.horizontal, 16).padding(.vertical, 10)
                            .background(ARCTheme.surfaceLight).overlay(RoundedRectangle(cornerRadius: ARCTheme.cornerRadius).strokeBorder(ARCTheme.line, lineWidth: 1)).cornerRadius(ARCTheme.cornerRadius)
                    }.buttonStyle(.plain).disabled(model.building)
                    Button(action: { if let d = model.builtDeck { NSWorkspace.shared.activateFileViewerSelecting([d]) } }) {
                        Text("REVEAL DECK").font(ARCTheme.statusBadge).foregroundStyle(ARCTheme.textPrimary).padding(.horizontal, 16).padding(.vertical, 10)
                            .background(ARCTheme.surfaceLight).overlay(RoundedRectangle(cornerRadius: ARCTheme.cornerRadius).strokeBorder(ARCTheme.line, lineWidth: 1)).cornerRadius(ARCTheme.cornerRadius)
                    }.buttonStyle(.plain).disabled(model.builtDeck == nil)
                    Spacer()
                    Button(action: { model.build(useStack: false, force: force, openInPresenter: openInPresenter) }) {
                        Text(model.building ? "BUILDING…" : "BUILD SHOW FOLDER").font(ARCTheme.mono(17, .heavy)).foregroundStyle(.white)
                            .padding(.horizontal, 26).padding(.vertical, 14)
                            .background(model.building ? ARCTheme.surfaceLight : ARCTheme.arcRed).cornerRadius(ARCTheme.cornerRadius)
                    }.buttonStyle(.plain).disabled(model.building || model.browseItems.filter { $0.kind != .folder }.isEmpty)
                }
            }
            .padding(ARCTheme.paddingMedium)
        }
        .background(ARCTheme.background)
    }
}
