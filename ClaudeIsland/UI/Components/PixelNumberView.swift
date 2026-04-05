import SwiftUI

struct PixelNumberView: View {
    let value: Int
    var color: Color = .white
    var fontSize: CGFloat = 9
    var weight: Font.Weight = .semibold
    var tracking: CGFloat = 0

    private var displayValue: String {
        String(max(0, min(value, 99)))
    }

    var body: some View {
        Text(verbatim: displayValue)
            .font(.system(size: fontSize, weight: weight, design: .default))
            .foregroundStyle(color)
            .tracking(tracking)
            .lineLimit(1)
            .fixedSize()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(displayValue)
    }
}
