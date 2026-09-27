import SwiftUI

// MARK: - 体重录入（M5 CoreDataWeightRepository.add 的 UI 落点；入口在首页「记体重」）

struct WeightFormView: View {
    let petID: UUID
    @State private var kg = 5.0
    @State private var date = Date()
    @State private var error: String?
    private let repo = CoreDataWeightRepository()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                // 直接输入 + ±0.1 微调双通道：TextField 数字键盘直填，Stepper 保留原锚点
                HStack {
                    TextField("体重", value: $kg, format: .number)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("weight.kgInput")
                    Text("kg").foregroundStyle(.secondary)
                    Stepper("", value: $kg, in: WeightValidator.kgRange, step: 0.1)
                        .labelsHidden()
                        .a11y("微调体重", hint: "每次增减0.1kg")
                        .accessibilityIdentifier("weight.kg")
                }
                DatePicker("日期", selection: $date, in: ...Date(), displayedComponents: .date)
                    .a11y("体重日期", hint: "只能录入今天或更早的体重")
                    .accessibilityIdentifier("weight.date")
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                        .accessibilityIdentifier("weight.error")
                }
            }
            .navigationTitle("记体重")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .accessibilityIdentifier("weight.save")
                }
            }
        }
    }

    private func save() {
        // 双保险：DatePicker 已限制 ≤ 今天，仍兜底拦截未来日期
        guard date <= Date() else { error = "日期不能晚于今天"; return }
        // TextField 直输可绕过 Stepper 的范围钳制，保存前拦截越界值
        guard WeightValidator.isValid(kg) else { error = "体重需在0.1-100.0kg之间"; return }
        do {
            try repo.add(WeightSample(petID: petID, kg: kg, date: date))
            dismiss()
        } catch {
            self.error = "保存失败，请重试"
        }
    }
}
