import Foundation

/// What was copied, as stored: one of text (with its rich forms), an image,
/// or files.
public struct ClipboardContent: Codable, Equatable, Sendable {
    public var text: String?
    public var rtf: Data?
    public var html: Data?
    public var png: Data?
    /// File paths, for files copied in the Finder.
    public var filePaths: [String]?

    public init(text: String? = nil, rtf: Data? = nil, html: Data? = nil, png: Data? = nil, filePaths: [String]? = nil) {
        self.text = text
        self.rtf = rtf
        self.html = html
        self.png = png
        self.filePaths = filePaths
    }

    public var kind: ClipboardKind {
        if filePaths?.isEmpty == false { return .files }
        if png != nil { return .image }
        return .text
    }

    public var byteCount: Int {
        (text?.utf8.count ?? 0) + (rtf?.count ?? 0) + (html?.count ?? 0) + (png?.count ?? 0)
            + (filePaths?.reduce(0) { $0 + $1.utf8.count } ?? 0)
    }

    /// What two copies of the same thing have in common, for spotting a
    /// repeat: the rich forms differ between apps for the same words.
    var identity: Data {
        switch kind {
        case .files: Data(("files:" + (filePaths ?? []).joined(separator: "\n")).utf8)
        case .image: png ?? Data()
        case .text: Data(("text:" + (text ?? "")).utf8)
        }
    }
}

public enum ClipboardKind: String, Codable, Sendable {
    case text, image, files
}

/// The small part of an item the list shows and searches, sealed apart from
/// the content so opening the list never decrypts whole images.
public struct ClipboardPreview: Codable, Equatable, Sendable {
    /// The text, cut to `maxTextLength`; for files, their names.
    public var text: String
    /// A small PNG of an image.
    public var thumbnail: Data?

    public static let maxTextLength = 2000

    public init(text: String, thumbnail: Data? = nil) {
        self.text = String(text.prefix(Self.maxTextLength))
        self.thumbnail = thumbnail
    }
}

/// One entry of the history, as the list shows it.
public struct ClipboardItem: Equatable, Sendable, Identifiable {
    public var id: Int64
    public var kind: ClipboardKind
    /// When it was last copied or pasted from the history.
    public var lastUsed: Date
    public var sourceApp: String?
    public var isPinned: Bool
    public var byteCount: Int
    public var preview: ClipboardPreview
}
