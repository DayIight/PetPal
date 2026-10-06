import SwiftUI

// MARK: - 心情选择（预设 emoji + 自定义文本，记录预设表单与自定义表单共用）
// 数据契约：Record.mood 为自由 String，预设直接写入 emoji，自定义写入 ≤10 字文本
struct MoodPicker: View {
    @Binding var mood: String
    /// a11y id 前缀（"record.mood" / "custom.mood"）
    let a11yPrefix: String

    static let presets = ["😀", "😐", "😢"]
    static let maxCustomLength = 10

    @State private var customActive = false

    private var isCustom: Bool { !mood.isEmpty && !Self.presets.contains(mood) }

    var body: some View {
        VStack(alignment: .leading, spacing: DS.Spacing.sm) {
            HStack(spacing: DS.Spacing.sm) {
                ForEach(Self.presets, id: \.self) { emoji in
                    Button {
                        mood = emoji
                        customActive = false
                    } label: {
                        Text(emoji)
                            .font(.title3)
                            .frame(width: 40, height: 40)
                            .background(
                                Circle().fill(mood == emoji
                                              ? Color.accentColor.opacity(0.25)
                                              : Color.groupedBackground)
                            )
                    }
                    .buttonStyle(.plain)
                    .a11y("心情\(emoji)", hint: mood == emoji ? "当前已选" : "点击选择")
                    .accessibilityIdentifier("\(a11yPrefix).preset.\(emoji)")
                }
                Button {
                    customActive = true
                } label: {
                    Text("自定义")
                        .font(.callout)
                        .padding(.horizontal, DS.Spacing.sm)
                        .frame(height: 40)
                        .background(
                            Capsule().fill(isCustom || customActive
                                           ? Color.accentColor.opacity(0.25)
                                           : Color.groupedBackground)
                        )
                }
                .buttonStyle(.plain)
                .a11y("自定义心情", hint: "输入不超过10个字的心情标签")
                .accessibilityIdentifier("\(a11yPrefix).custom")
                if !mood.isEmpty {
                    Button {
                        mood = ""
                        customActive = false
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .a11y("清除心情")
                    .accessibilityIdentifier("\(a11yPrefix).clear")
                }
            }
            if customActive || isCustom {
                TextField("心情（≤10字）", text: customBinding)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("\(a11yPrefix).customInput")
            }
        }
    }

    /// 进入自定义编辑时保留已有自定义文本；超限截断（与 RecordValidator 的 10 字上限一致）
    private var customBinding: Binding<String> {
        Binding(
            get: { isCustom ? mood : "" },
            set: { mood = String($0.prefix(Self.maxCustomLength)) }
        )
    }
}
