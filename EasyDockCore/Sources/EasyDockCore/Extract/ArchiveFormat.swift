import Foundation

/// The archive formats EasyDock extracts, told apart by the bytes a file
/// starts with rather than by its name. Each maps to the one 7-Zip reader
/// allowed to open it, so a file in disguise never reaches the many rarely
/// used readers 7-Zip also has, where most of its security fixes land.
public enum ArchiveFormat: String, Sendable, CaseIterable {
    case rar, rar5, sevenZip, zip, gzip, bzip2, xz, zstd, tar, cab, iso, arj, lzh

    /// How many bytes `detect` reads: an ISO 9660 image names itself at 0x8001.
    public static let headerLength = 0x8006

    public static func detect(_ header: Data) -> ArchiveFormat? {
        let bytes = [UInt8](header.prefix(headerLength))
        func has(_ signature: [UInt8], at offset: Int = 0) -> Bool {
            bytes.count >= offset + signature.count && Array(bytes[offset..<offset + signature.count]) == signature
        }
        let rar: [UInt8] = [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]
        if has(rar + [0x01, 0x00]) { return .rar5 }
        if has(rar + [0x00]) { return .rar }
        if has([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return .sevenZip }
        // A local file, an empty archive, or the first part of a spanned one.
        if has([0x50, 0x4B, 0x03, 0x04]) || has([0x50, 0x4B, 0x05, 0x06]) || has([0x50, 0x4B, 0x07, 0x08]) { return .zip }
        if has([0x1F, 0x8B]) { return .gzip }
        if has([0x42, 0x5A, 0x68]) { return .bzip2 }
        if has([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .xz }
        if has([0x28, 0xB5, 0x2F, 0xFD]) { return .zstd }
        if has(Array("ustar".utf8), at: 257) { return .tar }
        if has(Array("MSCF".utf8)) { return .cab }
        if has(Array("CD001".utf8), at: 0x8001) { return .iso }
        if has([0x60, 0xEA]) { return .arj }
        if has(Array("-lh".utf8), at: 2) && has(Array("-".utf8), at: 6) { return .lzh }
        return nil
    }

    /// 7-Zip's name for the reader, as `7zz i` lists it.
    public var sevenZipType: String {
        switch self {
        case .rar: "Rar"
        case .rar5: "Rar5"
        case .sevenZip: "7z"
        case .zip: "zip"
        case .gzip: "gzip"
        case .bzip2: "bzip2"
        case .xz: "xz"
        case .zstd: "zstd"
        case .tar: "tar"
        case .cab: "Cab"
        case .iso: "Iso"
        case .arj: "Arj"
        case .lzh: "Lzh"
        }
    }

    /// A compressed stream holds one file, not a list of them.
    public var isStream: Bool {
        switch self {
        case .gzip, .bzip2, .xz, .zstd: true
        default: false
        }
    }
}
