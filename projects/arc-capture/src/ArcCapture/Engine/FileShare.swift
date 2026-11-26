//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import CryptoKit

/// A slide that links to a video FILE on a sharing service (Google Drive, Dropbox, Box, OneDrive) or by a
/// direct URL. ARC Grab is for streaming players and stays out of this (2026-09-19: "ARC Grab only does
/// streaming links, make a path for the file-sharing links"): Capture downloads the file itself, reads it with
/// ffprobe, conforms it to MP4 H.264 when it is not, and the splitter places it as it places a grab
/// (OnlineVideo.swift). A link that answers with a sign-in page, or a file that is not a video, is said so.
enum FileShare {
    enum Source: Equatable {
        case googleDrive(id: String)
        case dropbox(URL)
        case box(key: String)
        case oneDrive(URL)
        case direct(URL)
    }
    struct FetchError: Error, CustomStringConvertible {
        let description: String
        /// The link is fine, but what it holds is not a video (a PDF, a deck): nothing for the review.
        let notVideo: Bool
        init(_ s: String, notVideo: Bool = false) { description = s; self.notVideo = notVideo }
    }

    static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "avi", "wmv", "mpeg", "mpg", "webm", "mkv", "mts", "m2ts", "mxf"]

    /// The sharing service and its handle, or nil when the URL is not one this path fetches. Google Docs,
    /// Sheets and Slides links are documents, not files, and are left alone.
    static func source(of url: String) -> Source? {
        guard let c = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines)), let host = c.host?.lowercased(), let u = c.url else { return nil }
        let parts = c.path.split(separator: "/").map(String.init)
        if host == "drive.google.com" || host == "docs.google.com" || host == "drive.usercontent.google.com" {
            if parts.count >= 3, parts[0] == "file", parts[1] == "d" { return .googleDrive(id: parts[2]) }
            if let id = c.queryItems?.first(where: { $0.name == "id" })?.value, ["open", "uc", "download"].contains(parts.last ?? "") || host == "drive.usercontent.google.com" { return .googleDrive(id: id) }
            return nil
        }
        if host.hasSuffix("dropbox.com") || host.hasSuffix("dropboxusercontent.com") { return .dropbox(u) }
        if host.hasSuffix("box.com"), parts.count >= 2, parts[0] == "s" { return .box(key: parts[1]) }
        if host == "1drv.ms" || host.hasSuffix("onedrive.live.com") || host.hasSuffix("sharepoint.com") { return .oneDrive(u) }
        if videoExtensions.contains((c.path as NSString).pathExtension.lowercased()) { return .direct(u) }
        return nil
    }

    /// The URL that answers with the file's bytes.
    static func downloadURL(_ s: Source) -> URL {
        switch s {
        case .googleDrive(let id):
            // The usercontent host with confirm=t skips the "too large to scan for viruses" page a big file gets.
            return URL(string: "https://drive.usercontent.google.com/download?id=\(id)&export=download&confirm=t")!
        case .dropbox(let u):
            var c = URLComponents(url: u, resolvingAgainstBaseURL: false)!
            var q = (c.queryItems ?? []).filter { $0.name != "dl" }
            q.append(URLQueryItem(name: "dl", value: "1"))
            c.queryItems = q
            return c.url ?? u
        case .box(let key):
            return URL(string: "https://app.box.com/index.php?rm=box_download_shared_file&shared_name=\(key)")!
        case .oneDrive(let u):
            // The documented shares API: u! + base64url of the sharing link, then /root/content.
            let b64 = Data(u.absoluteString.utf8).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").trimmingCharacters(in: CharacterSet(charactersIn: "="))
            return URL(string: "https://api.onedrive.com/v1.0/shares/u!\(b64)/root/content")!
        case .direct(let u):
            return u
        }
    }

    /// A stable file stem for the download.
    static func stem(_ s: Source, url: String) -> String {
        func hash() -> String { SHA256.hash(data: Data(url.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined() }
        func clean(_ t: String) -> String { String(t.filter { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }.prefix(48)) }
        switch s {
        case .googleDrive(let id): return "gdrive-" + clean(id)
        case .dropbox: return "dropbox-" + hash()
        case .box(let key): return "box-" + clean(key)
        case .oneDrive: return "onedrive-" + hash()
        case .direct(let u): return "file-" + clean(u.deletingPathExtension().lastPathComponent) + "-" + String(hash().prefix(6))
        }
    }

    static func label(_ s: Source) -> String {
        switch s {
        case .googleDrive: "Google Drive"; case .dropbox: "Dropbox"; case .box: "Box"; case .oneDrive: "OneDrive"; case .direct: "a file link"
        }
    }

    /// The video as an MP4 (H.264) in `dir`, named by the stem, or why there is none. A file already there
    /// (fetched before, or put there by hand) is used as it is.
    static func fetch(url: String, into dir: URL, log: (String) -> Void) async -> Result<URL, FetchError> {
        guard let s = source(of: url) else { return .failure(FetchError("not a file-sharing link")) }
        let stem = stem(s, url: url)
        let fm = FileManager.default
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        if let have = cached(stem: stem, in: dir) { log("online video \(stem): already here (\(have.lastPathComponent))"); return .success(have) }
        let marker = dir.appendingPathComponent(stem + ".notvideo")
        if let why = try? String(contentsOf: marker, encoding: .utf8) { return .failure(FetchError(why, notVideo: true)) }
        let t0 = Date()
        log("online video \(stem): downloading from \(label(s)) …")
        var req = URLRequest(url: downloadURL(s)); req.timeoutInterval = 120
        req.setValue("ARC Capture", forHTTPHeaderField: "User-Agent")
        let tmp: URL; let resp: URLResponse
        do { (tmp, resp) = try await URLSession.shared.download(for: req) } catch {
            return .failure(FetchError("\(label(s)) did not answer: \(error.localizedDescription)"))
        }
        defer { try? fm.removeItem(at: tmp) }
        let http = resp as? HTTPURLResponse
        let size = (try? fm.attributesOfItem(atPath: tmp.path)[.size] as? Int) ?? 0
        if let code = http?.statusCode, code >= 400 {
            let shared: Bool = { if case .direct = s { return false }; return true }()
            return .failure(FetchError("\(label(s)) answered \(code)" + (shared && (code == 401 || code == 403) ? ": the file is not shared with anyone with the link" : "")))
        }
        let head = (try? FileHandle(forReadingFrom: tmp).readData(ofLength: 512)).map { String(decoding: $0, as: UTF8.self).lowercased() } ?? ""
        let mime = (http?.mimeType ?? "").lowercased()
        if mime.contains("text/html") || head.contains("<html") || head.contains("<!doctype html") {
            return .failure(FetchError("\(label(s)) answered with a web page, not the file: the link needs a sign-in, or is not shared with anyone with the link"))
        }
        guard size > 1000 else { return .failure(FetchError("\(label(s)) answered with an empty file")) }
        // What is it? ffprobe says.
        guard let ffprobe = PPTXAnalyzer.ffprobeURL else { return .failure(FetchError("ffprobe is missing")) }
        let probe = Process(); probe.executableURL = ffprobe
        probe.arguments = ["-v", "error", "-show_entries", "stream=codec_type,codec_name:format=format_name", "-of", "csv=p=0", tmp.path]
        let out = Pipe(); probe.standardOutput = out; probe.standardError = FileHandle.nullDevice; probe.standardInput = FileHandle.nullDevice
        do { try probe.run() } catch { return .failure(FetchError("ffprobe could not be started")) }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self); probe.waitUntilExit()
        // ffprobe prints the fields in ITS order (codec_name before codec_type), whatever the entries list says.
        let lines = text.split(separator: "\n").map { $0.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
        let videoCodec = lines.first { $0.contains("video") }?.first { $0 != "video" }
        let formatName = lines.first { $0.count == 1 }?.first ?? ""
        guard probe.terminationStatus == 0, let codec = videoCodec else {
            let why = "the link holds a file that is not a video (" + (mime.isEmpty ? "\(size) bytes" : mime) + ")"
            try? why.write(to: marker, atomically: true, encoding: .utf8)
            return .failure(FetchError(why, notVideo: true))
        }
        let suggested = http?.suggestedFilename ?? ""
        let ext = (suggested as NSString).pathExtension.lowercased()
        let isMP4 = formatName.contains("mp4") || formatName.contains("mov")
        let final = dir.appendingPathComponent(stem + ".mp4")
        try? fm.removeItem(at: final)
        if codec == "h264", isMP4, ext != "mkv" {
            do { try fm.moveItem(at: tmp, to: final) } catch { return .failure(FetchError("the download could not be kept: \(error.localizedDescription)")) }
            log("online video \(stem): \(suggested.isEmpty ? "the file" : suggested) (\(size / 1_000_000) MB, H.264) in \(Int(Date().timeIntervalSince(t0))) s")
            return .success(final)
        }
        guard let ffmpeg = PPTXAnalyzer.ffmpegURL else { return .failure(FetchError("ffmpeg is missing to conform \(codec)")) }
        log("online video \(stem): \(suggested.isEmpty ? "the file" : suggested) (\(size / 1_000_000) MB, \(codec) in \(formatName)) conforming to MP4 H.264 …")
        let p = Process(); p.executableURL = ffmpeg
        p.arguments = ["-nostdin", "-v", "error", "-y", "-i", tmp.path, "-map", "0:v:0", "-map", "0:a?", "-c:v", "h264_videotoolbox", "-b:v", "16M", "-pix_fmt", "yuv420p",
                       "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", final.path]
        let err = Pipe(); p.standardError = err; p.standardOutput = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return .failure(FetchError("ffmpeg could not be started")) }
        p.waitUntilExit()
        guard p.terminationStatus == 0, (try? fm.attributesOfItem(atPath: final.path)[.size] as? Int) ?? 0 > 1000 else {
            let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            try? fm.removeItem(at: final)
            return .failure(FetchError("ffmpeg could not conform the file: \(e.suffix(160))"))
        }
        log("online video \(stem): conformed in \(Int(Date().timeIntervalSince(t0))) s")
        return .success(final)
    }

    /// A file for the stem already in the folder: `<stem>.mp4` or any movie extension (put there by hand).
    static func cached(stem: String, in dir: URL) -> URL? {
        for ext in ["mp4", "m4v", "mov"] {
            let u = dir.appendingPathComponent(stem + "." + ext)
            if (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0 > 1000 { return u }
        }
        return nil
    }
}
