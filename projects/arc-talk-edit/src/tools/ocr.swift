// ocr: print the text Apple Vision recognises in an image (one line per detected string, top to bottom). Build:
//   swiftc -O -o tools/ocr tools/ocr.swift     Usage: tools/ocr IMAGE [IMAGE ...]
// Each image ends with a record separator line (U+001E), text or not (10/22: a blank-line separator shifted every key
// after a page with no text).
import Foundation
import Vision
import AppKit
for path in CommandLine.arguments.dropFirst() {
    guard let img = NSImage(contentsOfFile: path), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else { print("\u{1E}"); continue }
    let req = VNRecognizeTextRequest()
    req.recognitionLevel = .accurate
    req.usesLanguageCorrection = true
    try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([req])
    let obs = (req.results ?? []).sorted { $0.boundingBox.maxY > $1.boundingBox.maxY }
    for o in obs { if let c = o.topCandidates(1).first { print(c.string) } }
    print("\u{1E}")
}
