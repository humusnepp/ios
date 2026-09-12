//
//  Archive.swift
//  RenPy Box
//
//  Minimal, dependency-free archive extraction for Ren'Py games:
//    - ZIP (stored + deflate) via the Compression framework
//    - TAR (ustar/pax-annotated)
//    - GZIP (single file, or tar on top)
//
//  Pure Swift + Apple Compression, no third-party libraries.
//

import Foundation
import Compression

enum ArchiveError: LocalizedError {
    case notAnArchive
    case truncated(String)
    case corrupt(String)
    case unsafePath(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .notAnArchive: return "The file is not a supported archive."
        case .truncated(let m), .corrupt(let m), .unsafePath(let m), .unsupported(let m): return m
        }
    }
}

struct Archive {
    /// Raw DEFLATE inflate (used by both ZIP and GZIP payloads).
    static func inflate(_ data: Data) -> Data? {
        let bytes = [UInt8](data)
        let bufSize = 1 << 16

        let stream = UnsafeMutablePointer<compression_stream>.allocate(capacity: 1)
        defer { stream.deallocate() }

        guard compression_stream_init(stream, COMPRESSION_STREAM_DECODE, COMPRESSION_ZLIB) == COMPRESSION_STATUS_OK else {
            return nil
        }
        defer { compression_stream_destroy(stream) }

        let srcBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        let dstBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: bufSize)
        defer { srcBuf.deallocate(); dstBuf.deallocate() }

        var out = Data(capacity: bytes.count * 2)
        var offset = 0

        while true {
            let toRead = min(bufSize, bytes.count - offset)
            if toRead > 0 {
                bytes.withUnsafeBufferPointer { bp in
                    if let base = bp.baseAddress {
                        srcBuf.update(from: base, count: toRead)
                    }
                }
            }
            offset += toRead
            let finalize = (offset >= bytes.count) ? COMPRESSION_STREAM_FINALIZE : compression_stream_flags()

            stream.pointee.src_ptr = srcBuf
            stream.pointee.src_size = toRead

            var done = false
            repeat {
                stream.pointee.dst_ptr = dstBuf
                stream.pointee.dst_size = bufSize

                let status = compression_stream_process(stream, finalize)
                if status == COMPRESSION_STATUS_ERROR { return nil }

                let produced = bufSize - stream.pointee.dst_size
                if produced > 0 { out.append(dstBuf, count: produced) }

                if status == COMPRESSION_STATUS_END { done = true; break }
                if status == COMPRESSION_STATUS_OK && stream.pointee.dst_size > 0 { break }
                if status == COMPRESSION_STATUS_OK && produced == 0 && toRead == 0 {
                    done = true
                    break
                }
            } while stream.pointee.dst_size == 0

            if done { break }
            if toRead == 0 { break }
        }
        return out
    }

    /// Drops the gzip header (and optional fields), returning the raw deflate payload.
    private static func gzipPayload(_ data: Data) -> Data? {
        let b = [UInt8](data)
        guard b.count > 10, b[0] == 0x1F, b[1] == 0x8B else { return nil }

        var p = 10
        let flg = b[3]
        if flg & 0x04 != 0 { // FEXTRA
            guard p + 2 <= b.count else { return nil }
            let xlen = Int(b[p]) | (Int(b[p + 1]) << 8)
            p += 2 + xlen
        }
        if flg & 0x08 != 0 { // FNAME
            while p < b.count && b[p] != 0 { p += 1 }
            p += 1
        }
        if flg & 0x10 != 0 { // FCOMMENT
            while p < b.count && b[p] != 0 { p += 1 }
            p += 1
        }
        if flg & 0x02 != 0 { p += 2 } // FHCRC
        guard p < b.count else { return nil }
        return Data(b[p...])
    }

    static func decompressGzip(_ data: Data) -> Data? {
        guard let payload = gzipPayload(data) else { return nil }
        return inflate(payload)
    }

    // MARK: - Public entry point

    static func extractArchive(at url: URL, to destination: URL, progress: (Double) -> Void = { _ in }) throws {
        let ext = url.pathExtension.lowercased()
        let base = url.deletingPathExtension().pathExtension.lowercased()
        switch ext {
        case "zip", "renpy": try extractZip(at: url, to: destination, progress: progress)
        case "tar": try extractTar(at: url, to: destination, progress: progress)
        case "gz" where base == "tar": try extractTarGz(at: url, to: destination, progress: progress)
        case "gz":
            let out = destination.appendingPathComponent(url.deletingPathExtension().lastPathComponent)
            let data = try Data(contentsOf: url)
            guard let dec = decompressGzip(data) else { throw ArchiveError.corrupt("Gzip decompression failed.") }
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            try dec.write(to: out)
        default:
            // Try ZIP as a last resort (itch.io uploads use .renpy/.bin etc. occasionally).
            if url.lastPathComponent.lowercased().hasSuffix("renpy") {
                try extractZip(at: url, to: destination, progress: progress)
            } else {
                throw ArchiveError.notAnArchive
            }
        }
    }

    // MARK: - ZIP

    private static func extractZip(at url: URL, to destination: URL, progress: (Double) -> Void) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let bytes = [UInt8](data)
        let count = bytes.count

        // EOCD (End of Central Directory) at the end.
        guard count >= 22 else { throw ArchiveError.truncated("Archive is too small.") }
        var eocd = -1
        let searchStart = max(0, count - 65_557)
        for i in stride(from: count - 22, through: searchStart, by: -1) {
            if bytes[i] == 0x50, bytes[i + 1] == 0x4B, bytes[i + 2] == 0x05, bytes[i + 3] == 0x06 {
                eocd = i
                break
            }
        }
        guard eocd >= 0 else { throw ArchiveError.corrupt("ZIP end-of-central-directory not found.") }

        let entryCount = Int(bytes[eocd + 10]) | (Int(bytes[eocd + 11]) << 8)
        let cdStart = Int(bytes[eocd + 16]) | (Int(bytes[eocd + 17]) << 8) | (Int(bytes[eocd + 18]) << 16) | (Int(bytes[eocd + 19]) << 24)

        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        var p = cdStart
        for index in 0..<entryCount {
            progress(Double(index) / Double(max(1, entryCount)))
            guard p + 46 <= count, bytes[p] == 0x50, bytes[p + 1] == 0x4B,
                  bytes[p + 2] == 0x01, bytes[p + 3] == 0x02 else {
                throw ArchiveError.corrupt("ZIP central directory is corrupt.")
            }
            let method = Int(bytes[p + 10])
            let compSize = Int(bytes[p + 20]) | (Int(bytes[p + 21]) << 8) | (Int(bytes[p + 22]) << 16) | (Int(bytes[p + 23]) << 24)
            let nameLen = Int(bytes[p + 28]) | (Int(bytes[p + 29]) << 8)
            let extraLen = Int(bytes[p + 30]) | (Int(bytes[p + 31]) << 8)
            let commentLen = Int(bytes[p + 32]) | (Int(bytes[p + 33]) << 8)
            let localOff = Int(bytes[p + 42]) | (Int(bytes[p + 43]) << 8) | (Int(bytes[p + 44]) << 16) | (Int(bytes[p + 45]) << 24)

            guard p + 46 + nameLen <= count else { throw ArchiveError.truncated("ZIP entry truncated.") }
            let name = String(bytes: bytes[p + 46..<p + 46 + nameLen], encoding: .utf8)
                ?? String(bytes: bytes[p + 46..<p + 46 + nameLen], encoding: .isoLatin1)!
            p += 46 + nameLen + extraLen + commentLen

            let target = try safeDestination(base: destination, name: name)
            let isDir = name.hasSuffix("/")

            if isDir {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }

            // Local file header → data start.
            guard localOff + 30 <= count, bytes[localOff] == 0x50, bytes[localOff + 1] == 0x4B,
                  bytes[localOff + 2] == 0x03, bytes[localOff + 3] == 0x04 else {
                throw ArchiveError.corrupt("ZIP local header missing for \(name).")
            }
            let lNameLen = Int(bytes[localOff + 26]) | (Int(bytes[localOff + 27]) << 8)
            let lExtraLen = Int(bytes[localOff + 28]) | (Int(bytes[localOff + 29]) << 8)
            let dataStart = localOff + 30 + lNameLen + lExtraLen
            guard dataStart + compSize <= count else { throw ArchiveError.truncated("ZIP data truncated for \(name).") }

            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            let raw = Data(bytes[dataStart..<dataStart + compSize])
            let content: Data
            switch method {
            case 0: content = raw
            case 8:
                guard let dec = inflate(raw) else { throw ArchiveError.corrupt("ZIP deflate failed for \(name).") }
                content = dec
            default:
                throw ArchiveError.unsupported("ZIP compression method \(method) for \(name).")
            }
            try content.write(to: target, options: .atomic)
        }
        progress(1.0)
    }

    // MARK: - TAR

    private static func extractTar(at url: URL, to destination: URL, progress: (Double) -> Void) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let fh = try FileHandle(forReadingFrom: url)
        defer { try? fh.close() }

        var header = [UInt8](repeating: 0, count: 512)
        var position: UInt64 = 0
        let total = (try? fm.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0

        while true {
            guard position + 512 <= total else { break }
            let block = try fh.read(upToCount: 512) ?? Data()
            if block.count < 512 {
                header = [UInt8](block) + [UInt8](repeating: 0, count: 512 - block.count)
            } else {
                header = [UInt8](block)
            }
            position += 512

            if header.allSatisfy({ $0 == 0 }) { break } // end marker

            let name = parseTarString(header, 0, 100)
            let prefix = parseTarString(header, 345, 155)
            let typeflag = header[156]
            let size = parseOctal(header, 124, 12)
            let fullName = prefix.isEmpty ? name : "\(prefix)/\(name)"
            if fullName.isEmpty { continue }

            let target = try safeDestination(base: destination, name: fullName)
            progress(Double(position) / Double(max(1, total)))

            switch typeflag {
            case 0x00, 0x30: // '0' regular file
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let body = try fh.read(upToCount: size) ?? Data()
                position += UInt64(body.count)
                try body.write(to: target, options: .atomic)
                let pad = (512 - (size % 512)) % 512
                if pad > 0 { _ = try fh.read(upToCount: pad); position += UInt64(pad) }
            case 0x35: // '5' directory
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
            case 0x78, 0x67: // pax extended (x, X, g) headers
                if size > 0 { _ = try fh.read(upToCount: size); position += UInt64(size) }
                let pad = (512 - (size % 512)) % 512
                if pad > 0 { _ = try fh.read(upToCount: pad); position += UInt64(pad) }
            case 0x4C: // 'L' GNU long name
                if size > 0 { _ = try fh.read(upToCount: size); position += UInt64(size) }
                let pad = (512 - (size % 512)) % 512
                if pad > 0 { _ = try fh.read(upToCount: pad); position += UInt64(pad) }
            case 0x2F, 0x2E: // GNU long link, '.' etc.
                if size > 0 { _ = try fh.read(upToCount: size); position += UInt64(size) }
                let pad = (512 - (size % 512)) % 512
                if pad > 0 { _ = try fh.read(upToCount: pad); position += UInt64(pad) }
            default:
                // Symlinks / hardlinks / devices: skip body.
                if size > 0 { _ = try fh.read(upToCount: size); position += UInt64(size) }
                let pad = (512 - (size % 512)) % 512
                if pad > 0 { _ = try fh.read(upToCount: pad); position += UInt64(pad) }
            }
        }
        progress(1.0)
    }

    private static func extractTarGz(at url: URL, to destination: URL, progress: (Double) -> Void) throws {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard let payload = gzipPayload(data), let plain = inflate(payload) else {
            throw ArchiveError.corrupt("Gzip decompression failed.")
        }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("rpb-\(UUID().uuidString).tar")
        try plain.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try extractTar(at: tmp, to: destination, progress: progress)
    }

    // MARK: - Helpers

    private static func safeDestination(base: URL, name: String) throws -> URL {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        var safe: [String] = []
        for part in parts {
            let s = String(part)
            if s == ".." || s == "." || s.isEmpty { continue }
            guard !s.contains(":") && !s.contains("\\") else { throw ArchiveError.unsafePath("Illegal path component in \(name).") }
            safe.append(s)
        }
        guard !safe.isEmpty else { throw ArchiveError.unsafePath("Empty path in archive.") }
        return safe.reduce(base) { $0.appendingPathComponent($1) }
    }

    private static func parseTarString(_ b: [UInt8], _ o: Int, _ len: Int) -> String {
        var end = o
        while end < o + len && (end - o) < len && b[end] != 0 { end += 1 }
        return String(bytes: b[o..<end], encoding: .utf8) ?? ""
    }

    private static func parseOctal(_ b: [UInt8], _ o: Int, _ len: Int) -> Int {
        var value = 0
        for i in o..<(o + len) {
            let c = b[i]
            if c == 0x20 || c == 0x30 { continue }
            if c >= 0x31 && c <= 0x37 { value = value * 8 + Int(c - 0x30); continue }
            if c == 0x00 { break }
            break
        }
        return value
    }
}