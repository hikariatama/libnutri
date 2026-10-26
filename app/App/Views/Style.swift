import NutritionCore
import SwiftUI

enum AppFont {
    static let body = Font.custom("Huninn-Regular", size: 17, relativeTo: .body)
    static let title = Font.custom("Huninn-Regular", size: 24, relativeTo: .title2)
    static let caption = Font.custom("Huninn-Regular", size: 14, relativeTo: .caption)
    static let metric = Font.custom("Huninn-Regular", size: 36, relativeTo: .largeTitle)
    static let calorie = Font.custom("Huninn-Regular", size: 112, relativeTo: .largeTitle)
}
extension Color { static let appBackground = Color(red: 8 / 255, green: 8 / 255, blue: 8 / 255) }

struct NutrientView: View {
    var value: String
    var label: String
    var large = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        VStack(spacing: 4) {
            Text(value).font(large ? AppFont.calorie : AppFont.metric)
                .minimumScaleFactor(0.45).lineLimit(1)
                .contentTransition(.numericText())
            Text(label).font(AppFont.body).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .snappy, value: value)
        .accessibilityElement(children: .ignore).accessibilityLabel("\(value) \(label)")
    }
}

struct ErrorNotice: View {
    let message: String
    var title: String?
    var actionTitle: String?
    var action: (() -> Void)?
    var font: Font = AppFont.body
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).padding(.top, 2)
            VStack(alignment: .leading, spacing: 12) {
                if let title { Text(title).font(font.weight(.semibold)) }
                Text(message).foregroundStyle(.secondary).fixedSize(
                    horizontal: false, vertical: true
                )
                .accessibilityAddTraits(.updatesFrequently)
                if let actionTitle, let action {
                    Button(actionTitle, action: action).buttonStyle(.glass)
                }
            }
        }
        .font(font).frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }
}

struct ProcessingStatus: View {
    let label: String
    var waitingUntil: Date?
    var cancel: () -> Void
    var body: some View {
        HStack(spacing: 12) {
            ProgressView().accessibilityLabel(label)
            if let waitingUntil {
                VStack(alignment: .leading) {
                    Text("Waiting to retry")
                    Text(waitingUntil, style: .relative).font(AppFont.caption).foregroundStyle(
                        .secondary)
                }
            } else {
                Text(label)
            }
            Spacer()
            Button("Cancel", action: cancel).buttonStyle(.glass)
        }.font(AppFont.body).transition(.opacity)
    }
}
