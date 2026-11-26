// follow-eyes: the detector for ARC Follow (docs/plans/PLAN_auto_tracking_module.txt section 3.1).
// Reads a concatenated JPEG stream (ffmpeg -f mjpeg pipe:1) on standard input and writes one JSON
// line per frame on standard output: {"n":frame,"t":unixMs,"ms":detectMs,"w":px,"h":px,
// "boxes":[{"x":0.41,"y":0.12,"w":0.09,"h":0.55,"c":0.93}]} with x,y the TOP LEFT corner as
// fractions of the frame. People come from Apple's Vision framework on the Neural Engine; nothing
// is downloaded and no model file ships. Options: --upper (upper body boxes, faster lock on a
// lectern), --every N (detect every Nth frame, the others are passed through with no boxes),
// --min C (confidence floor, default 0.3).
import Foundation
import Vision
import ImageIO

var upperBody = false
var every = 1
var minConf: Float = 0.3
var args = CommandLine.arguments.dropFirst().makeIterator()
while let a = args.next() {
    switch a {
    case "--upper": upperBody = true
    case "--every": every = max(1, Int(args.next() ?? "1") ?? 1)
    case "--min": minConf = Float(args.next() ?? "0.3") ?? 0.3
    default:
        FileHandle.standardError.write("follow-eyes: unknown option \(a)\n".data(using: .utf8)!)
        exit(2)
    }
}

let out = FileHandle.standardOutput
let input = FileHandle.standardInput
var buf = Data()
var frameNo = 0
let soi: [UInt8] = [0xFF, 0xD8]
let eoi: [UInt8] = [0xFF, 0xD9]

func emit(_ s: String) { out.write((s + "\n").data(using: .utf8)!) }

func detect(_ jpeg: Data) {
    frameNo += 1
    let t = Int64(Date().timeIntervalSince1970 * 1000)
    var w = 0, h = 0
    if let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
       let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
        w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
    }
    if frameNo % every != 0 {
        emit("{\"n\":\(frameNo),\"t\":\(t),\"ms\":0,\"w\":\(w),\"h\":\(h),\"boxes\":[],\"skipped\":true}")
        return
    }
    let t0 = DispatchTime.now()
    let req = VNDetectHumanRectanglesRequest()
    req.upperBodyOnly = upperBody
    let handler = VNImageRequestHandler(data: jpeg, options: [:])
    var boxes: [String] = []
    do {
        try handler.perform([req])
        for r in req.results ?? [] where r.confidence >= minConf {
            let b = r.boundingBox  // normalised, origin bottom left
            boxes.append(String(format: "{\"x\":%.4f,\"y\":%.4f,\"w\":%.4f,\"h\":%.4f,\"c\":%.3f}",
                                b.origin.x, 1.0 - b.origin.y - b.size.height, b.size.width, b.size.height, r.confidence))
        }
    } catch {
        FileHandle.standardError.write("follow-eyes: frame \(frameNo) \(error)\n".data(using: .utf8)!)
    }
    let ms = Double(DispatchTime.now().uptimeNanoseconds - t0.uptimeNanoseconds) / 1e6
    emit(String(format: "{\"n\":%d,\"t\":%lld,\"ms\":%.1f,\"w\":%d,\"h\":%d,\"boxes\":[%@]}", frameNo, t, ms, w, h, boxes.joined(separator: ",")))
}

// Split the byte stream on JPEG start and end markers. A frame is SOI ... EOI inclusive.
while true {
    let chunk = input.availableData
    if chunk.isEmpty { break }
    buf.append(chunk)
    while true {
        guard let s = buf.range(of: Data(soi)) else { buf.removeAll(keepingCapacity: true); break }
        guard let e = buf.range(of: Data(eoi), in: s.upperBound..<buf.endIndex) else {
            if s.lowerBound > 0 { buf.removeSubrange(0..<s.lowerBound) }
            break
        }
        let frame = buf.subdata(in: s.lowerBound..<e.upperBound)
        buf.removeSubrange(0..<e.upperBound)
        detect(frame)
    }
}
