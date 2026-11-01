import AppKit
import SwiftUI

struct ArtworkCreditsView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("艺术封面来源").font(.title2.weight(.semibold))
            Text("内置六幅博物馆开放作品，仅在网页无可用图片时显示；不表示艺术作品与文章内容相关。所有图片均经官方公共领域标记核对，依 CC0 1.0 使用，保留作品与来源信息。")
                .font(.callout).foregroundStyle(.secondary)
            List(ArtCoverCatalog.shared) { item in
                HStack(spacing: 14) {
                    if let url = ArtCoverCatalog.imageURL(for: item), let image = NSImage(contentsOf: url) {
                        Image(nsImage: image).resizable().scaledToFill().frame(width: 100, height: 65).clipped().clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.headline).lineLimit(2)
                        Text(item.artist).font(.caption).foregroundStyle(.secondary)
                        HStack {
                            if let url = URL(string: item.source) { Link("Art Institute of Chicago", destination: url) }
                            Text("CC0 1.0").foregroundStyle(.secondary)
                        }.font(.caption)
                    }
                }.padding(.vertical, 6)
            }.listStyle(.inset)
        }.padding(20).frame(minWidth: 520, idealWidth: 620, minHeight: 540)
    }
}

struct ArtworkCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(before: .help) {
            Button("艺术封面来源") { openWindow(id: "artwork-credits") }
            Divider()
        }
    }
}
