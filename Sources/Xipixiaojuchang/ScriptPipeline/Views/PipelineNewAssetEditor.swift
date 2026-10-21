import SwiftUI

struct PipelineNewAssetEditor: View {
    let kind: String
    let onSave: (String, String) -> Void
    let onClose: () -> Void
    @State private var name = ""
    @State private var prompt = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("新增\(kind)").font(.title3.weight(.semibold))
            TextField("名称", text: $name).textFieldStyle(.roundedBorder)
            TextEditor(text: $prompt).font(.system(size: 14)).scrollContentBackground(.hidden).frame(height: 300)
            HStack {
                Spacer()
                Button("取消", action: onClose)
                Button("保存") { onSave(name, prompt) }.buttonStyle(AccentButtonStyle())
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(16)
    }
}
