import AppKit
import SwiftUI

struct ConnectionView: View {
    @ObservedObject var model: AppModel
    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focusedField: Field?

    private enum Field { case server, token }

    private var logo: NSImage? {
        guard let url = AppResources.bundle.url(forResource: "readeck-upstream", withExtension: "png", subdirectory: "Branding") else { return nil }
        return NSImage(contentsOf: url)
    }

    var body: some View {
        GeometryReader { geometry in
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 36)
                VStack(spacing: 16) {
                    Group {
                        if let logo {
                            Image(nsImage: logo).resizable().interpolation(.high).scaledToFit()
                        } else {
                            Image(systemName: "bookmark.square.fill").resizable().scaledToFit().foregroundStyle(.tint)
                        }
                    }
                    .frame(width: 64, height: 64)
                    .accessibilityHidden(true)
                    VStack(spacing: 6) {
                        Text("连接你的 Readeck").font(.title.weight(.semibold))
                        Text("连接自建服务，继续你的阅读。")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("服务端地址").font(.callout.weight(.medium))
                        TextField("服务端地址", text: $model.serverText, prompt: Text("http://192.168.1.10:8000/"))
                            .labelsHidden().textFieldStyle(.roundedBorder)
                            .textContentType(.URL).focused($focusedField, equals: .server)
                            .onSubmit { focusedField = .token }
                    }
                    VStack(alignment: .leading, spacing: 7) {
                        Text("API Token").font(.callout.weight(.medium))
                        SecureField("API Token", text: $model.tokenText, prompt: Text("输入 API Token"))
                            .labelsHidden().textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .token)
                            .onSubmit { if !model.isBusy { Task { await model.connect() } } }
                    }
                    if let error = model.errorMessage {
                        Label(error, systemImage: AppSymbol.warning.rawValue)
                            .font(.callout).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(Text(error))
                    }
                    HStack {
                        Spacer()
                        Button {
                            Task { await model.connect() }
                        } label: {
                            HStack(spacing: 8) {
                                if model.isBusy { ProgressView().controlSize(.small) }
                                Text(model.isBusy ? "正在连接…" : "连接")
                            }.frame(minWidth: 90)
                        }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                        .disabled(model.isBusy).keyboardShortcut(.defaultAction)
                    }
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(.primary.opacity(colorScheme == .dark ? 0.10 : 0.06)))

                Label("支持 HTTP 和 HTTPS。HTTP 请仅用于可信网络。", systemImage: "lock.shield")
                    .font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                Spacer(minLength: 36)
            }
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity, minHeight: max(540, geometry.size.height))
            .padding(.horizontal, 24)
        }
        .background(LibraryAppearance.windowBackground(in: colorScheme))
        }
    }
}
