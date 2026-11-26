//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import AppKit
import ARCShowFormat

/// Whether a captured slide is a static image or an animated video clip.
enum SlideType: String, Codable {
    case image
    case video
}

/// A single captured slide, either a static image or a video clip.
///
/// The full-size bitmap is the expensive part: a 2x window frame is ~27 MB,
/// and holding one per slide for a whole show is what put a 53-slide run at
/// 1.9 GB (MEASURED_memory_2026-09). Once `CaptureCheckpoint` has written the
/// slide to the `.partial` deck, `held` is dropped and `pageFile` takes over:
/// the page is read back from disk only when the deck is written, and the
/// filmstrip draws `thumb`, a ~320 pt copy that costs a fifth of a megabyte.
struct CaptureResult: Identifiable {
    var id: Int              // 1-based page in the deck (renumbered when the logo pages go on)
    let pptxSlide: Int?      // PowerPoint's slide number at the time, when known
    let slideType: SlideType
    /// The full bitmap while it is still in memory: nil once checkpointed.
    private var held: NSImage?
    /// Small copy for the filmstrip. Never nil after a checkpoint.
    var thumb: NSImage?
    /// The page JPEG inside the `.partial` deck, at PDF size.
    var pageFile: URL?
    var videoURL: URL?       // temp clip for .video slides until the deck is written
    let capturedAt: Date
    let settleMs: Int        // advance -> settle
    let motionFrames: Int    // changed frames seen while recording
    let endedBy: String      // settled | timeout | duplicate | error
    /// The movie on this slide is set to "Loop until Stopped": the clip
    /// holds one pass and the manifest tells Presenter to loop it.
    var loop: Bool = false
    /// Seconds into the clip where the looping movie starts (the slide's
    /// entry transition and click wait come before it). Presenter loops
    /// from here to the end, not from the clip's first frame (Sample Deck
    /// slide 4 looped back to the previous slide's test card, 2026-09-12).
    var loopStart: Double? = nil
    /// The clip is only the way INTO the slide (no movie, no clicks): a
    /// transition. Presenter plays it on entry and shows the page as the
    /// slide, drawn as a thin separator in the filmstrip (2026-09-12).
    var transition: Bool = false
    /// Seconds into the clip at which each click fired while it was
    /// recording: the previous slide's build clicks first, then the click
    /// that left it (`entryClick` is its index), then this slide's own
    /// clicks (movie start). Presenter plays one segment per click so the
    /// operator's clicks land where PowerPoint's did (2026-09-12:
    /// "the transition between slide 1 and 2 was combined with the video").
    var clicks: [Double] = []
    /// Index into `clicks` of the click that moved the show onto this
    /// slide; nil when the clip started on the slide itself (slide 1, or
    /// an automatic advance).
    var entryClick: Int? = nil
    /// The way INTO this slide as its own clip (the previous slide's builds
    /// at its head, then the transition), split off the moment the
    /// transition settled on the poster; the main clip then starts at the
    /// slide's first own click (2026-09-12: transitions must be
    /// discrete objects). `entryClicks` are that clip's click marks, the
    /// last one being the click that left the previous slide.
    /// Clip time where playback was last heard or seen moving, when the
    /// movie stopped before its end (PowerPoint gave up); Presenter holds
    /// or wraps the loop there instead of playing the frozen tail.
    var stopAt: Double? = nil
    /// The pptx slide defines a transition into it (drawn as a TRN box even
    /// when the transition lives inside this slide's own clip).
    var transitionIn: Bool = false
    /// PowerPoint advances this slide by itself after this many seconds
    /// (advTm; 0 = as soon as its animations and media finish). The exit
    /// transition sits at the tail of this slide's clip, so Presenter plays
    /// the clip out and moves on (every-transition baseline slide 72).
    var autoAdvance: Double? = nil
    var entryClipURL: URL? = nil
    /// nil = a slide of the source; otherwise a logo page.
    var role: DeckManifest.Role? = nil
    var entryClicks: [Double] = []

    init(id: Int, pptxSlide: Int?, slideType: SlideType, image: NSImage?, videoURL: URL?,
         capturedAt: Date, settleMs: Int, motionFrames: Int, endedBy: String) {
        self.id = id
        self.pptxSlide = pptxSlide
        self.slideType = slideType
        self.held = image
        self.videoURL = videoURL
        self.capturedAt = capturedAt
        self.settleMs = settleMs
        self.motionFrames = motionFrames
        self.endedBy = endedBy
    }

    /// The page at full size: in memory before the checkpoint, off disk after.
    /// Only the deck writer asks for this; nothing holds the result.
    var image: NSImage {
        if let held { return held }
        if let pageFile, let img = NSImage(contentsOf: pageFile) { return img }
        return thumb ?? NSImage(size: NSSize(width: 16, height: 9))
    }

    /// What the filmstrip draws. Never touches disk, so scrolling a captured
    /// deck does not read 50 JPEGs per frame.
    var thumbnail: NSImage { thumb ?? held ?? NSImage(size: NSSize(width: 16, height: 9)) }

    /// True once the page lives on disk and the big bitmap has been let go.
    var isCheckpointed: Bool { held == nil && pageFile != nil }

    /// Hand the page over to the checkpoint: keep a small copy for the
    /// filmstrip, point at the written JPEG, release the bitmap.
    mutating func checkpointed(pageFile: URL, thumbnail: NSImage?) {
        self.pageFile = pageFile
        self.thumb = thumbnail ?? self.thumb
        self.held = nil
    }

    var label: String {
        switch slideType {
        case .image: return "Slide \(id)"
        case .video: return "Slide \(id) (video)"
        }
    }

    var isVideo: Bool { slideType == .video }

    /// For manifest/output naming.
    var filename: String {
        let padded = String(format: "%03d", id)
        switch slideType {
        case .image: return "slide_\(padded).png"
        case .video: return "slide_\(padded).mov"
        }
    }
}
