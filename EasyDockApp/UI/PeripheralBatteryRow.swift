import EasyDockCore
import SwiftUI

/// A connected device in the System tab and the panel's Overview: what it
/// is, its name and each battery's level, with a bolt while it charges and
/// in red once it is low.
struct PeripheralBatteryRow: View {
    let device: PeripheralBattery

    var body: some View {
        // A device with one battery fits on one line; earbuds and their case
        // go on a second line under the name, which a long name would
        // otherwise squeeze down to nothing.
        Group {
            if device.parts.count > 1 {
                VStack(alignment: .leading, spacing: 3) {
                    name
                    levels.padding(.leading, 26)
                }
            } else {
                HStack(spacing: 8) {
                    name
                    Spacer(minLength: 8)
                    levels
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var name: some View {
        HStack(spacing: 8) {
            Image(systemName: device.kind.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(verbatim: device.name)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private var levels: some View {
        HStack(spacing: 10) {
            ForEach(device.parts, id: \.role) { part in
                level(part)
            }
        }
        .monospacedDigit()
        .fixedSize()
    }

    private func level(_ part: PeripheralBattery.Part) -> some View {
        let isLow = part.percent <= (device.lowWarningPercent ?? 20) && part.isCharging != true
        return HStack(spacing: 3) {
            if let side = sideLabel(part.role) {
                Text(side).foregroundStyle(.secondary)
            }
            Text(verbatim: "\(part.percent)%")
            Image(systemName: batterySymbol(part))
                .symbolRenderingMode(.hierarchical)
        }
        .foregroundStyle(isLow ? AnyShapeStyle(.red) : AnyShapeStyle(.primary))
    }

    private func sideLabel(_ role: PeripheralBattery.Part.Role) -> LocalizedStringKey? {
        switch role {
        case .main: nil
        case .left: "L"
        case .right: "R"
        case .chargingCase: "Case"
        }
    }

    private func batterySymbol(_ part: PeripheralBattery.Part) -> String {
        if part.isCharging == true { return "battery.100percent.bolt" }
        switch part.percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }
}

extension PeripheralBattery.Kind {
    var systemImage: String {
        switch self {
        case .mouse: "computermouse"
        case .keyboard: "keyboard"
        case .trackpad: "rectangle.and.hand.point.up.left"
        case .headphones: "headphones"
        case .speaker: "hifispeaker"
        case .gamepad: "gamecontroller"
        case .other: "dot.radiowaves.left.and.right"
        }
    }
}
