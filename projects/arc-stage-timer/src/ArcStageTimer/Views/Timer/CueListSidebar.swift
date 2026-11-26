//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import SwiftUI
import SwiftData

struct CueListSidebar: View {
    let engine: TimerEngine
    let onSelect: (Int) -> Void
    var onCueMutation: (() -> Void)?
    var width: CGFloat = ARCTheme.sidebarWidth

    @Environment(\.modelContext) private var modelContext
    @State private var expandedCueID: UUID? = nil
    /// The cue open in the full CUE EDITOR sheet.
    @State private var fullEditorCue: Cue? = nil
    /// Bumped when a cue changes outside the inline editor, so it reloads its fields.
    @State private var editRevision = 0
    @State private var showShiftConfirm = false
    @State private var showQuickAdd = false
    @State private var showCompressSheet = false
    @State private var compressionResult: (proposals: [TimerEngine.CompressionProposal], targetEnd: Date, originalEnd: Date, deficit: Int)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            // The bracket's band: RUN ORDER is OPERATE (orange), the operator's hands.
            HStack(spacing: 0) {
                Text("RUN ORDER")
                    .font(ARCTheme.mono(11, .heavy))
                    .tracking(1.4)
                    .foregroundStyle(ARCTheme.ink)
                    .padding(.leading, ARCTheme.modulePad)
                Spacer()
                Rectangle().fill(ARCTheme.moduleBg).frame(width: ARCTheme.capGap)
                Button {
                    showQuickAdd = true
                } label: {
                    Text("+ ADD")
                        .font(ARCTheme.mono(11, .heavy))
                        .foregroundStyle(ARCTheme.text0)
                        .padding(.horizontal, 10)
                        .frame(maxHeight: .infinity)
                        .background(ARCTheme.ink)
                }
                .buttonStyle(.plain)
                .help("Add a cue to the run order")
            }
            .frame(height: ARCTheme.moduleHeaderH + 4)
            .background(ARCTheme.secOrange)

            // Offset banner (only for scheduled shows after show has started)
            if engine.isScheduledShow && engine.showStartedAt != nil {
                offsetBanner
            }

            Divider()
                .background(ARCTheme.divider)

            // Cue list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(Array(engine.cues.enumerated()), id: \.element.id) { index, cue in
                            VStack(spacing: 0) {
                                // Row
                                HStack(spacing: 0) {
                                    // Drag handle for future cues. Every row keeps the slot, so titles line up
                                    // and a future cue's title does not lose width to the handle (2026-09-25).
                                    Image(systemName: "line.3.horizontal")
                                        .font(.system(size: 10))
                                        .foregroundStyle(ARCTheme.textTertiary.opacity(index > engine.currentCueIndex ? 0.4 : 0))
                                        .frame(width: 12)

                                    CueRowView(
                                        cue: cue,
                                        isActive: index <= engine.currentCueIndex,
                                        isCurrent: index == engine.currentCueIndex,
                                        projectedStart: engine.projectedStartTime(for: index)
                                    )

                                    // Pencil hint for upcoming (non-current, non-completed) cues, in a fixed slot
                                    Image(systemName: "pencil")
                                        .font(.system(size: 10))
                                        .foregroundStyle(ARCTheme.textTertiary.opacity(index > engine.currentCueIndex ? 0.5 : 0))
                                        .frame(width: 14)
                                }
                                .opacity(index < engine.currentCueIndex ? 0.45 : 1.0)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    handleTap(index: index, cue: cue)
                                }
                                .draggable(cue.id.uuidString) {
                                    // Drag preview
                                    Text(cue.title)
                                        .font(.system(size: 13, weight: .medium))
                                        .padding(8)
                                        .background(ARCTheme.surface, in: RoundedRectangle(cornerRadius: 6))
                                }
                                .dropDestination(for: String.self) { items, _ in
                                    guard let draggedIDString = items.first,
                                          let draggedID = UUID(uuidString: draggedIDString),
                                          let sourceIdx = engine.cues.firstIndex(where: { $0.id == draggedID }),
                                          sourceIdx != index,
                                          index > engine.currentCueIndex,
                                          sourceIdx > engine.currentCueIndex else { return false }
                                    engine.moveCue(from: sourceIdx, to: index)
                                    onCueMutation?()
                                    return true
                                }

                                // Inline editor (expanded below the row)
                                if expandedCueID == cue.id {
                                    CueInlineEditor(
                                        cue: cue,
                                        onDelete: index > engine.currentCueIndex ? {
                                            handleDeleteCue(at: index, cue: cue)
                                        } : nil,
                                        onExpand: { fullEditorCue = cue }
                                    )
                                    .id("\(cue.id)-\(editRevision)")
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                                }
                            }
                            .id(index)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .onChange(of: engine.currentCueIndex) { _, newIndex in
                    withAnimation {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                    // Auto-collapse editor if the expanded cue is now current or past
                    if let expandedID = expandedCueID,
                       let expandedIdx = engine.cues.firstIndex(where: { $0.id == expandedID }),
                       expandedIdx <= newIndex {
                        withAnimation(.easeOut(duration: 0.2)) {
                            expandedCueID = nil
                        }
                    }
                }
            }

            // Undo button
            if engine.canUndo {
                Button {
                    engine.undo()
                    editRevision += 1
                    onCueMutation?()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.uturn.backward")
                            .font(.system(size: 12, weight: .bold))
                        Text("UNDO: \(engine.undoActionName ?? "Last Action")")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                    }
                    .foregroundStyle(ARCTheme.ink)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(ARCTheme.warn, in: RoundedRectangle(cornerRadius: 4))
                    .padding(.horizontal, ARCTheme.paddingMedium)
                }
                .buttonStyle(.plain)
                .padding(.bottom, 8)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(width: width)
        .background(ARCTheme.moduleBg)
        .overlay(alignment: .leading) { Rectangle().fill(ARCTheme.secOrange).frame(width: ARCTheme.leftRule) }
        .sheet(item: $fullEditorCue) { cue in
            fullEditor(for: cue)
        }
        #if DEBUG
        // DEBUG harness (/api/debug/cue-editor?index=N): open the editor with nobody at the mouse.
        .onReceive(NotificationCenter.default.publisher(for: .openCueEditor)) { note in
            if let i = note.object as? Int, engine.cues.indices.contains(i) { fullEditorCue = engine.cues[i] }
        }
        #endif
        .sheet(isPresented: $showQuickAdd) {
            QuickAddCueSheet { title, format, duration in
                handleAddCue(title: title, format: format, duration: duration)
            }
            #if os(iOS)
            .presentationDetents([.medium])
            #endif
        }
        .sheet(isPresented: $showCompressSheet) {
            if let result = compressionResult {
                CompressConfirmationSheet(
                    proposals: result.proposals,
                    targetEnd: result.targetEnd,
                    originalEnd: result.originalEnd,
                    deficit: result.deficit
                ) {
                    engine.applyCompression(result.proposals)
                    onCueMutation?()
                }
                #if os(iOS)
                .presentationDetents([.medium, .large])
                #endif
            }
        }
        .confirmationDialog(
            "Shift Schedule",
            isPresented: $showShiftConfirm,
            titleVisibility: .visible
        ) {
            Button("Shift by +\(formatOffset(engine.showOffsetSeconds))") {
                engine.shiftScheduleToNow()
                onCueMutation?()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("All remaining cue times will move forward by \(formatOffset(engine.showOffsetSeconds)).")
        }
    }

    // MARK: - Tap Logic

    private func handleTap(index: Int, cue: Cue) {
        if index == engine.currentCueIndex {
            // Tap current (running) cue → navigate via engine, no editor
            onSelect(index)
        } else {
            // Tap any other cue → toggle editor
            withAnimation(.easeInOut(duration: 0.2)) {
                if expandedCueID == cue.id {
                    expandedCueID = nil
                } else {
                    expandedCueID = cue.id
                }
            }
        }
    }

    // MARK: - Full Editor

    @ViewBuilder
    private func fullEditor(for cue: Cue) -> some View {
        let index = engine.cues.firstIndex(where: { $0.id == cue.id }) ?? 0
        let status = index < engine.currentCueIndex ? "DONE"
            : index == engine.currentCueIndex ? "CURRENT"
            : index == engine.currentCueIndex + 1 ? "NEXT" : "UPCOMING"
        CueFullEditor(
            cue: cue,
            position: index + 1,
            count: engine.cues.count,
            status: status,
            onSave: { draft in
                if engine.updateCue(id: cue.id, with: draft) {
                    editRevision += 1
                    onCueMutation?()
                }
            },
            onDelete: index > engine.currentCueIndex ? {
                handleDeleteCue(at: index, cue: cue)
            } : nil
        )
        .id(cue.id)   // the draft is @State: another cue is another editor
    }

    // MARK: - Cue Mutation Handlers

    private func handleAddCue(title: String, format: CueFormat, duration: Int) {
        let cue = Cue(
            title: title,
            sortOrder: engine.cues.count,
            format: format,
            durationSeconds: duration
        )
        // Assign to same show as current cues
        if let show = engine.cues.first?.show {
            cue.show = show
            modelContext.insert(cue)
        }
        // Insert after last cue (append)
        let lastIndex = engine.cues.isEmpty ? nil : engine.cues.count - 1
        engine.insertCue(cue, afterIndex: lastIndex)
        onCueMutation?()
    }

    private func handleDeleteCue(at index: Int, cue: Cue) {
        withAnimation(.easeOut(duration: 0.2)) {
            expandedCueID = nil
        }
        if engine.removeCue(at: index) {
            modelContext.delete(cue)
            onCueMutation?()
        }
    }

    // MARK: - Offset Banner

    private var offsetBanner: some View {
        let status = engine.offsetStatus
        return VStack(spacing: 6) {
            Text(engine.showOffsetDisplay)
                .font(.system(size: 28, weight: .heavy, design: .monospaced))
            Text(status.label)
                .font(.system(size: 14, weight: .bold))
                .tracking(2)

            // Action buttons when behind schedule
            if engine.showOffsetSeconds > 30 {
                VStack(spacing: 4) {
                    // Shift button
                    Button {
                        showShiftConfirm = true
                    } label: {
                        Text("SHIFT SCHEDULE")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(ARCTheme.background)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(status.color, in: Capsule())
                    }
                    .buttonStyle(.plain)

                    // Compress button
                    Button {
                        compressionResult = engine.calculateCompression()
                        if compressionResult != nil {
                            showCompressSheet = true
                        }
                    } label: {
                        Text("COMPRESS TO FIT")
                            .font(.system(size: 11, weight: .bold, design: .monospaced))
                            .foregroundStyle(ARCTheme.background)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(ARCTheme.timerYellow, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 2)
            }
        }
        .foregroundStyle(status.color)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(status.color.opacity(0.18))
    }

    // MARK: - Helpers

    private func formatOffset(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        if m > 0 {
            return "\(m)m \(s)s"
        }
        return "\(s)s"
    }
}

#if DEBUG
extension Notification.Name {
    static let openCueEditor = Notification.Name("ARCStageTimerOpenCueEditor")
    static let openShowEditor = Notification.Name("ARCStageTimerOpenShowEditor")
}
#endif
