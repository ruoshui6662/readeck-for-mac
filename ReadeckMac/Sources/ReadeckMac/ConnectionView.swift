import SwiftUI

struct ConnectionView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "bookmark.square.fill")
                .font(.system(size: 38))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 6) {
                Text("连接你的 Readeck")
                    .font(.largeTitle.weight(.semibold))
                Text("输入 NAS 上 Readeck 的地址和 API Token。")
                    .foregroundStyle(.secondary)
            }
            Form {
                TextField("服务端地址", text: $model.serverText, prompt: Text("http://192.168.1.10:8000/"))
                    .textContentType(.URL)
                SecureField("API Token", text: $model.tokenText)
            }
            .formStyle(.grouped)
            if let error = model.errorMessage {
                Label(error, systemImage: AppSymbol.warning.rawValue)
                    .foregroundStyle(.red)
            }
            HStack {
                Text("支持 HTTP 和 HTTPS。HTTP 请仅用于可信网络。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("连接") { Task { await model.connect() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isBusy)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
        .frame(width: 560)
    }
}
