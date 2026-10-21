import SwiftUI

struct PipelineAddPlaceholder: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "plus").font(.title3).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 58)
                .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
                .contentShape(Rectangle())
        }.buttonStyle(QuietButtonStyle())
    }
}
