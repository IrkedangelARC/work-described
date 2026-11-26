//
//  Copyright (c) 2026 ARC Event Productions.
//  Published under the license in the repository root.
//
//

import Foundation
import Compression

/// Extracts text from DOCX and tabular data from XLSX files.
/// Pure Swift — no external dependencies. Uses Compression framework for deflate.
enum DocumentParser {

    /// Extract plain text from a .docx file (one paragraph per line)
    static func extractTextFromDOCX(_ data: Data) -> String? {
        let files = ZIPReader.extractFiles(from: data, matching: ["word/document.xml"])
        guard let xmlData = files["word/document.xml"] else { return nil }

        let extractor = DOCXTextExtractor()
        let xmlParser = XMLParser(data: xmlData)
        xmlParser.delegate = extractor
        guard xmlParser.parse() else { return nil }

        return extractor.text.isEmpty ? nil : extractor.text
    }

    /// Extract rows from the first sheet of an .xlsx file
    static func extractRowsFromXLSX(_ data: Data) -> [[String]]? {
        let files = ZIPReader.extractFiles(from: data, matching: [
            "xl/sharedStrings.xml",
            "xl/worksheets/sheet1.xml"
        ])

        guard let sheetData = files["xl/worksheets/sheet1.xml"] else { return nil }

        // Shared strings table (may not exist if all values are inline)
        var sharedStrings: [String] = []
        if let stringsData = files["xl/sharedStrings.xml"] {
            let strParser = XLSXSharedStringsParser()
            let xmlParser = XMLParser(data: stringsData)
            xmlParser.delegate = strParser
            xmlParser.parse()
            sharedStrings = strParser.strings
        }

        let sheetParser = XLSXSheetParser(sharedStrings: sharedStrings)
        let xmlParser = XMLParser(data: sheetData)
        xmlParser.delegate = sheetParser
        guard xmlParser.parse() else { return nil }

        return sheetParser.rows.isEmpty ? nil : sheetParser.rows
    }
}

// MARK: - Minimal ZIP Reader

/// Reads entries from a standard ZIP archive using central directory.
/// Supports Store (method 0) and Deflate (method 8).
private enum ZIPReader {

    static func extractFiles(from zipData: Data, matching filenames: Set<String>) -> [String: Data] {
        var results: [String: Data] = [:]
        let bytes = [UInt8](zipData)
        guard bytes.count > 22 else { return results }

        // Find End of Central Directory record (search backwards)
        guard let eocdOffset = findEOCD(bytes) else { return results }

        let cdOffset = Int(readUInt32(bytes, at: eocdOffset + 16))
        let cdCount = Int(readUInt16(bytes, at: eocdOffset + 10))

        var pos = cdOffset
        for _ in 0..<cdCount {
            guard pos + 46 <= bytes.count else { break }
            // Central directory signature: PK\x01\x02
            guard bytes[pos] == 0x50, bytes[pos+1] == 0x4b,
                  bytes[pos+2] == 0x01, bytes[pos+3] == 0x02 else { break }

            let compressionMethod = readUInt16(bytes, at: pos + 10)
            let compressedSize = Int(readUInt32(bytes, at: pos + 20))
            let uncompressedSize = Int(readUInt32(bytes, at: pos + 24))
            let filenameLen = Int(readUInt16(bytes, at: pos + 28))
            let extraLen = Int(readUInt16(bytes, at: pos + 30))
            let commentLen = Int(readUInt16(bytes, at: pos + 32))
            let localHeaderOffset = Int(readUInt32(bytes, at: pos + 42))

            guard pos + 46 + filenameLen <= bytes.count else { break }
            let filename = String(bytes: bytes[(pos+46)..<(pos+46+filenameLen)], encoding: .utf8) ?? ""

            if filenames.contains(filename) {
                if let data = extractFromLocalHeader(bytes, at: localHeaderOffset,
                                                     compressionMethod: compressionMethod,
                                                     compressedSize: compressedSize,
                                                     uncompressedSize: uncompressedSize) {
                    results[filename] = data
                }
            }

            pos += 46 + filenameLen + extraLen + commentLen
        }

        return results
    }

    private static func extractFromLocalHeader(_ bytes: [UInt8], at offset: Int,
                                                compressionMethod: UInt16,
                                                compressedSize: Int,
                                                uncompressedSize: Int) -> Data? {
        guard offset + 30 <= bytes.count else { return nil }
        // Local file header signature: PK\x03\x04
        guard bytes[offset] == 0x50, bytes[offset+1] == 0x4b,
              bytes[offset+2] == 0x03, bytes[offset+3] == 0x04 else { return nil }

        let localFilenameLen = Int(readUInt16(bytes, at: offset + 26))
        let localExtraLen = Int(readUInt16(bytes, at: offset + 28))
        let dataStart = offset + 30 + localFilenameLen + localExtraLen

        guard dataStart + compressedSize <= bytes.count else { return nil }
        let compressedData = Data(bytes[dataStart..<(dataStart + compressedSize)])

        if compressionMethod == 0 {
            return compressedData // stored
        } else if compressionMethod == 8 {
            return decompressDeflate(compressedData, expectedSize: uncompressedSize)
        }
        return nil
    }

    private static func decompressDeflate(_ data: Data, expectedSize: Int) -> Data? {
        let bufferSize = max(expectedSize * 2, 65536)
        var decompressed = Data(count: bufferSize)

        let result = data.withUnsafeBytes { srcPtr -> Int? in
            guard let srcBase = srcPtr.baseAddress else { return nil }
            return decompressed.withUnsafeMutableBytes { dstPtr -> Int? in
                guard let dstBase = dstPtr.baseAddress else { return nil }
                let size = compression_decode_buffer(
                    dstBase.assumingMemoryBound(to: UInt8.self), bufferSize,
                    srcBase.assumingMemoryBound(to: UInt8.self), data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
                return size > 0 ? size : nil
            }
        }

        guard let decompressedSize = result else { return nil }
        decompressed.count = decompressedSize
        return decompressed
    }

    private static func findEOCD(_ bytes: [UInt8]) -> Int? {
        let minPos = max(0, bytes.count - 65557)
        for i in stride(from: bytes.count - 22, through: minPos, by: -1) {
            if bytes[i] == 0x50, bytes[i+1] == 0x4b,
               bytes[i+2] == 0x05, bytes[i+3] == 0x06 {
                return i
            }
        }
        return nil
    }

    private static func readUInt16(_ bytes: [UInt8], at offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset+1]) << 8)
    }

    private static func readUInt32(_ bytes: [UInt8], at offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset+1]) << 8) |
        (UInt32(bytes[offset+2]) << 16) | (UInt32(bytes[offset+3]) << 24)
    }
}

// MARK: - DOCX XML Parser

/// Extracts text from word/document.xml — one paragraph per output line.
private class DOCXTextExtractor: NSObject, XMLParserDelegate {
    var text = ""
    private var inTextElement = false
    private var currentParagraphText = ""

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        if localName == "t" { inTextElement = true }
        if localName == "p" { currentParagraphText = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inTextElement { currentParagraphText += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        if localName == "t" { inTextElement = false }
        if localName == "p" {
            if !currentParagraphText.isEmpty {
                if !text.isEmpty { text += "\n" }
                text += currentParagraphText
            }
        }
    }
}

// MARK: - XLSX Shared Strings Parser

/// Parses xl/sharedStrings.xml → array of string values (index = shared string ID).
private class XLSXSharedStringsParser: NSObject, XMLParserDelegate {
    var strings: [String] = []
    private var inT = false
    private var currentString = ""
    private var inSI = false

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        if localName == "si" { inSI = true; currentString = "" }
        if localName == "t" && inSI { inT = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inT { currentString += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        if localName == "t" { inT = false }
        if localName == "si" { inSI = false; strings.append(currentString) }
    }
}

// MARK: - XLSX Sheet Parser

/// Parses xl/worksheets/sheet1.xml → array of rows, each row an array of cell values.
private class XLSXSheetParser: NSObject, XMLParserDelegate {
    let sharedStrings: [String]
    var rows: [[String]] = []

    private var currentRow: [String] = []
    private var currentValue = ""
    private var currentCellType: String?
    private var inValue = false

    init(sharedStrings: [String]) {
        self.sharedStrings = sharedStrings
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        switch localName {
        case "row":
            currentRow = []
        case "c":
            currentCellType = attributeDict["t"]
            currentValue = ""
        case "v":
            inValue = true
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inValue { currentValue += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let localName = elementName.components(separatedBy: ":").last ?? elementName
        switch localName {
        case "v":
            inValue = false
        case "c":
            if currentCellType == "s", let index = Int(currentValue), index < sharedStrings.count {
                currentRow.append(sharedStrings[index])
            } else {
                currentRow.append(currentValue)
            }
        case "row":
            if !currentRow.allSatisfy({ $0.isEmpty }) {
                rows.append(currentRow)
            }
        default: break
        }
    }
}
