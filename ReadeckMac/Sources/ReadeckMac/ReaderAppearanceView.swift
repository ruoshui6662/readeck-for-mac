import AppKit
import SwiftUI

struct ReaderAppearanceView: View {
    @EnvironmentObject private var preferences: ReaderPreferences
    @State private var showFonts = false
    @State private var showLayout = false

    private var fontName: String {
        switch preferences.style.fontFamily {
        case "pingfang": "苹方"
        case "songti": "宋体"
        case "serif": "衬线"
        case "mono": "等宽"
        default: preferences.style.fontFamily.hasPrefix("custom:")
            ? ReaderFontCatalog.displayName(for: String(preferences.style.fontFamily.dropFirst(7))) : "系统默认"
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("阅读设置").font(.system(size: 13, weight: .semibold))

                ReaderPresetControl(selection: preferences.presetName) { preferences.applyPreset($0) }
                    .frame(height: 22)

                VStack(spacing: 7) {
                    HStack(spacing: 8) {
                        Text("字体").frame(width: 52, alignment: .leading)
                        Menu {
                            fontButton("系统默认", value: "system")
                            fontButton("苹方", value: "pingfang")
                            fontButton("宋体", value: "songti")
                            fontButton("衬线", value: "serif")
                            fontButton("等宽", value: "mono")
                            Divider()
                            Button("其他已安装字体…") { showFonts = true }
                        } label: {
                            Text(AppLanguage.text(fontName)).lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .menuStyle(.borderedButton)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel("阅读字体")
                    }
                    .frame(height: 26)
                    ReaderAdjustmentRow(title: "字号", value: $preferences.style.fontSize, range: 12...30, step: 1, decimals: 0, unit: "pt")
                    ReaderAdjustmentRow(title: "行距", value: $preferences.style.lineHeight, range: 1.2...2.2, step: 0.1, decimals: 1, unit: "倍")
                    ReaderAdjustmentRow(title: "正文宽度", value: $preferences.style.contentWidth, range: 480...980, step: 20, decimals: 0, unit: "pt")
                }

                DisclosureGroup(isExpanded: $showLayout) {
                    VStack(spacing: 7) {
                        ReaderAdjustmentRow(title: "段距", value: $preferences.style.paragraphSpacing, range: 0.4...1.8, step: 0.05, decimals: 2, unit: "倍")
                        ReaderAdjustmentRow(title: "字距", value: $preferences.style.letterSpacing, range: 0...0.12, step: 0.01, decimals: 2, unit: "em")
                        ReaderAdjustmentRow(title: "图片间距", value: $preferences.style.imageSpacing, range: 0.4...2, step: 0.1, decimals: 1, unit: "倍")
                        ReaderAdjustmentRow(title: "图片宽度", value: $preferences.style.imageWidth, range: 50...100, step: 5, decimals: 0, unit: "%")
                        HStack(spacing: 8) {
                            Text("对齐方式").frame(width: 52, alignment: .leading)
                            Picker("对齐方式", selection: $preferences.style.alignment) {
                                Text("左对齐").tag("left")
                                Text("两端对齐").tag("justify")
                            }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: .infinity)
                        }.frame(height: 26)
                        HStack {
                            Text("正文首行缩进")
                            Spacer()
                            Toggle("正文首行缩进", isOn: $preferences.style.firstLineIndent)
                                .labelsHidden().toggleStyle(.switch)
                        }.frame(height: 26)
                    }.padding(.top, 9)
                } label: {
                    Text("更多排版").foregroundStyle(.secondary)
                }
                .disclosureGroupStyle(ReaderLayoutDisclosureStyle())

                Divider()

                HStack(spacing: 8) {
                    Text("主题").frame(width: 52, alignment: .leading)
                    Picker("主题", selection: $preferences.style.theme) {
                        Text("系统").tag("system")
                        Text("浅色").tag("light")
                        Text("暖纸").tag("sepia")
                        Text("深色").tag("dark")
                    }.pickerStyle(.segmented).labelsHidden()
                }

                HStack(spacing: 8) {
                    Text("目录样式").frame(width: 52, alignment: .leading)
                    Picker("目录样式", selection: $preferences.outlinePresentation) {
                        Text("沉浸式").tag(ReaderOutlinePresentation.immersive)
                        Text("经典面板").tag(ReaderOutlinePresentation.classic)
                    }.pickerStyle(.segmented).labelsHidden()
                }

                HStack {
                    Spacer()
                    Button("恢复默认") { preferences.reset() }
                        .font(.system(size: 11)).buttonStyle(.borderless)
                }
            }
            .font(.system(size: 12))
            .controlSize(.small)
            .padding(16)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 300)
        .frame(maxHeight: 540)
        .fixedSize(horizontal: false, vertical: true)
        .background(.background)
        .sheet(isPresented: $showFonts) { installedFonts }
    }

    private func fontButton(_ title: String, value: String) -> some View {
        Button { preferences.style.fontFamily = value } label: {
            if preferences.style.fontFamily == value { Label(AppLanguage.text(title), systemImage: "checkmark") }
            else { Text(AppLanguage.text(title)) }
        }
    }

    private var installedFonts: some View {
        InstalledReaderFonts(selection: $preferences.style.fontFamily)
    }
}

/// macOS's default disclosure only activates its small arrow. Make the entire
/// heading a native button, including its label and otherwise empty trailing area.
private struct ReaderLayoutDisclosureStyle: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) {
                    configuration.isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .rotationEffect(.degrees(configuration.isExpanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    configuration.label
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 22, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityValue(AppLanguage.text(configuration.isExpanded ? "已展开" : "已收起"))
            if configuration.isExpanded {
                configuration.content
            }
        }
    }
}

private struct ReaderPresetControl: NSViewRepresentable {
    let selection: String
    let onSelect: (String) -> Void
    private let presets = ["compact", "comfortable", "large"]

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: ["紧凑", "舒适", "大字"].map { AppLanguage.text($0) }, trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.selectPreset(_:)))
        control.controlSize = .small
        control.segmentDistribution = .fillEqually
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setAccessibilityLabel(AppLanguage.text("排版预设"))
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.onSelect = onSelect
        control.selectedSegment = presets.firstIndex(of: selection) ?? -1
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    final class Coordinator: NSObject {
        var onSelect: (String) -> Void

        init(onSelect: @escaping (String) -> Void) { self.onSelect = onSelect }

        @objc func selectPreset(_ sender: NSSegmentedControl) {
            let presets = ["compact", "comfortable", "large"]
            guard presets.indices.contains(sender.selectedSegment) else { return }
            onSelect(presets[sender.selectedSegment])
        }
    }
}

private struct ReaderAdjustmentRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let step: Double
    let decimals: Int
    let unit: String

    private var bounded: Binding<Double> {
        Binding(get: { value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : range.lowerBound },
                set: { value = $0.isFinite ? min(max($0, range.lowerBound), range.upperBound) : range.lowerBound })
    }

    // A continuous native track avoids tick dots; only dragging snaps to the existing steps.
    // Numeric input keeps its original precision (for example, a paragraph spacing of 1.25).
    private var stepped: Binding<Double> {
        Binding(get: { bounded.wrappedValue }, set: { proposed in
            let clamped = proposed.isFinite ? min(max(proposed, range.lowerBound), range.upperBound) : range.lowerBound
            bounded.wrappedValue = range.lowerBound + ((clamped - range.lowerBound) / step).rounded() * step
        })
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(AppLanguage.text(title)).frame(width: 52, alignment: .leading)
            Slider(value: stepped, in: range)
                .accessibilityLabel(AppLanguage.text(title))
                .accessibilityValue("\(value.formatted(.number.precision(.fractionLength(decimals)))) \(AppLanguage.text(unit))")
                .accessibilityAdjustableAction { direction in
                    switch direction {
                    case .increment: bounded.wrappedValue += step
                    case .decrement: bounded.wrappedValue -= step
                    @unknown default: break
                    }
                }
            TextField(AppLanguage.text(title), value: bounded, format: .number.precision(.fractionLength(decimals)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 45)
                .accessibilityLabel(AppLanguage.text(title) + " " + AppLanguage.text("数值"))
            Text(AppLanguage.text(unit)).font(.caption2).foregroundStyle(.secondary)
                .frame(width: 18, alignment: .leading)
        }
        .frame(height: 26)
    }

}

private struct InstalledReaderFonts: View {
    @Binding var selection: String
    @State private var query = ""
    @State private var fonts: [InstalledReaderFont] = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text("本机字体").font(.title3.weight(.semibold)); Spacer(); Button("完成") { dismiss() } }
            TextField("搜索字体名称", text: $query).textFieldStyle(.roundedBorder)
            List(fonts.filter { $0.matches(query) }) { font in
                Button { selection = font.selectionValue; dismiss() } label: {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: font.displayName)
                            if font.displayName != font.familyName {
                                Text(verbatim: font.familyName).font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text("阅读 Aa").font(.custom(font.previewName, size: 15))
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.semibold)).foregroundStyle(.tint)
                            .opacity(selection == font.selectionValue ? 1 : 0)
                            .accessibilityHidden(true)
                    }
                        .padding(.vertical, 4).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(font.displayName)
                    .accessibilityAddTraits(selection == font.selectionValue ? .isSelected : [])
            }
            Text("使用已安装字体，不需要下载。").font(.caption).foregroundStyle(.secondary)
        }
        .padding(22).frame(width: 440, height: 480)
        .onAppear { fonts = ReaderFontCatalog.installed() }
        .onReceive(NotificationCenter.default.publisher(for: NSFont.fontSetChangedNotification)) { _ in
            fonts = ReaderFontCatalog.installed()
        }
    }
}
