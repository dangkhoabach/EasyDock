import Foundation

/// The archives EasyDock makes, all with 7-Zip. RAR is not one of them:
/// 7-Zip has no RAR encoder and the unRAR licence forbids making one from
/// its code. Nor is ZST: 7-Zip only reads it.
public enum CompressFormat: String, Sendable, CaseIterable {
    case zip
    case sevenZip = "7z"
    case tarGz = "tar.gz"
    case tarXz = "tar.xz"
    case tarBz2 = "tar.bz2"
    case tar

    public var fileExtension: String { rawValue }

    /// ZIP with AES-256, 7z with AES-256 and its file names hidden too.
    public var takesPassword: Bool { self == .zip || self == .sevenZip }

    /// 7-Zip refuses a ZIP password with anything but ASCII in it, an
    /// accent included; a 7z takes any.
    public func accepts(password: String) -> Bool {
        self == .zip ? password.allSatisfy(\.isASCII) : true
    }

    /// Made by two 7-Zip runs: a tar written to a pipe, compressed by the
    /// second. 7-Zip can't write a compressed tar in one.
    public var isCompressedTar: Bool { self == .tarGz || self == .tarXz || self == .tarBz2 }

    /// ZIP and 7z can rename what they hold after the fact, so their names
    /// can be made NFC; a compressed tar can't.
    public var canRename: Bool { self == .zip || self == .sevenZip }

    /// 7-Zip's name for the writer of the file EasyDock saves.
    public var sevenZipType: String {
        switch self {
        case .zip: "zip"
        case .sevenZip: "7z"
        case .tarGz: "gzip"
        case .tarXz: "xz"
        case .tarBz2: "bzip2"
        case .tar: "tar"
        }
    }

    /// 7-Zip's `-mx`, chosen on 363 MB of headers and programs and on 200 MB
    /// that doesn't compress. Above 5, 7z and XZ took twice the time and
    /// memory to come out 4 % smaller. GZIP at 5 makes several passes: 6.6
    /// times as long as at 1 to save 6 %, so Balanced stays at 1. A plain
    /// tar isn't compressed.
    public func sevenZipLevel(_ level: CompressLevel) -> Int? {
        switch (self, level) {
        case (.tar, _): nil
        case (_, .fast): 1
        case (.tarGz, .balanced): 1
        case (_, .balanced): 5
        case (.sevenZip, .smallest), (.tarXz, .smallest): 7
        case (_, .smallest): 9
        }
    }
}

public enum CompressLevel: String, Sendable, CaseIterable {
    case fast, balanced, smallest
}

public enum CompressSplit {
    /// Part sizes offered, in bytes; 0 doesn't split. 20 MB fits a mail
    /// once encoded for sending, 4 GB is a FAT32 file's limit.
    public static let presets: [Int] = [0, 20_000_000, 100_000_000, 1_000_000_000, 4_294_967_295]

    /// The name of part `index` (from 1), as 7-Zip writes them.
    public static func partName(_ archiveName: String, index: Int) -> String {
        archiveName + "." + String(format: "%03d", index)
    }
}
