import Foundation

/// One mounted, browsable volume. `SystemStats.diskUsedGB`/`diskTotalGB`
/// only ever describe `/`; this covers external drives and extra internal
/// partitions, which a monitoring app on a machine with an external SSD
/// attached was previously blind to.
public struct VolumeUsage: Sendable, Equatable, Identifiable {
    public var id: String { path }
    public let path: String
    public let name: String
    public let totalBytes: UInt64
    public let freeBytes: UInt64
    public let isInternal: Bool

    public init(path: String, name: String, totalBytes: UInt64, freeBytes: UInt64, isInternal: Bool) {
        self.path = path
        self.name = name
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.isInternal = isInternal
    }

    public var usedBytes: UInt64 { totalBytes > freeBytes ? totalBytes - freeBytes : 0 }

    public var usedPercent: Double {
        totalBytes == 0 ? 0 : Double(usedBytes) / Double(totalBytes) * 100
    }
}

extension VolumeUsage {
    /// How worried to be about a volume's free space, for the bar's color.
    /// Mostly an amount, as macOS needs gigabytes free whatever the disk's
    /// size; a small share as well, so a large drive still warns before its
    /// last percent. A share like 20% alone would flag 800 GB free on 4 TB.
    public enum SpaceLevel: Sendable, Equatable { case plenty, low, critical }

    private static let gibibyte: UInt64 = 1_073_741_824

    public static func spaceLevel(freeBytes: UInt64, totalBytes: UInt64) -> SpaceLevel {
        guard totalBytes > 0 else { return .plenty }
        let freeShare = Double(freeBytes) / Double(totalBytes)
        if freeBytes < 10 * gibibyte || freeShare < 0.02 { return .critical }
        if freeBytes < 30 * gibibyte || freeShare < 0.05 { return .low }
        return .plenty
    }

    public var spaceLevel: SpaceLevel { Self.spaceLevel(freeBytes: freeBytes, totalBytes: totalBytes) }
}
