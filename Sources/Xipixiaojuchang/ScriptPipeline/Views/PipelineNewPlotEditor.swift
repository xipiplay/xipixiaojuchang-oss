import SwiftUI

struct PipelineNewPlotEditor: View {
    let onSave: (String) -> Void
    let onClose: () -> Void
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新增段落剧情").font(.title3.weight(.semibold))
            TextEditor(text: $text).font(.system(size: 14))
                .scrollContentBackground(.hidden).frame(height: 300)
            HStack {
                Spacer()
                Button("取消", action: onClose)
                Button("保存") { onSave(text) }.buttonStyle(AccentButtonStyle())
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(16)
    }
}
