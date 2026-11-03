import Foundation

/// Every alert the scheduler sends, as data rather than text. The app turns
/// it into a title and body in the language picked in Settings
/// (`AlertTextLocalizing`); Core has no string catalog of its own, so it
/// only knows the English text (`EnglishAlertText`).
public enum AlertMessage: Sendable, Equatable {
    /// `freed` is already formatted (`ByteCountFormatter`).
    case cleanupFinished(freed: String, locations: Int, skipped: [String])
    case systemHot(celsius: Int, thresholdCelsius: Int)
    case batteryLow(percent: Int)
}

/// Turns an alert into the title and body of a notification.
public protocol AlertTextLocalizing: Sendable {
    func text(for message: AlertMessage) -> (title: String, body: String)
}

/// The English text, used wherever the host injects nothing else (tests).
public struct EnglishAlertText: AlertTextLocalizing {
    public init() {}

    public func text(for message: AlertMessage) -> (title: String, body: String) {
        switch message {
        case .cleanupFinished(let freed, let locations, let skipped):
            ("Scheduled cleanup finished",
             "Moved \(freed) to the Trash from \(locations) locations."
                + (skipped.isEmpty ? "" : " Not fully cleared: \(skipped.joined(separator: ", ")).")
            )
        case .systemHot(let celsius, let thresholdCelsius):
            ("Your Mac is running hot", "\(celsius)°C (threshold \(thresholdCelsius)°C)")
        case .batteryLow(let percent):
            ("Battery low", "\(percent)% left — plug in the charger")
        }
    }
}
