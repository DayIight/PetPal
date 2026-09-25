import SwiftUI

// MARK: - 建档表单（PRD §1：物种必选、品种预设列表+自定义；支持新建与编辑复用）
struct PetFormView: View {
    @StateObject var vm: PetFormViewModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Picker("物种", selection: $vm.draft.species) {
                    ForEach(PetSpecies.allCases) { Text($0.rawValue).tag($0) }
                }
                .accessibilityIdentifier("pet.species")
                TextField("昵称", text: $vm.draft.nickname)
                    .accessibilityIdentifier("pet.nickname")
                breedField
                DatePicker("生日", selection: $vm.draft.birthday, in: ...Date(),
                           displayedComponents: .date)
                Stepper("体重 \(vm.draft.weightKg, specifier: "%.1f") kg",
                        value: $vm.draft.weightKg, in: 0.1...100.0, step: 0.1)
                Picker("绝育状态", selection: $vm.draft.neuterStatus) {
                    ForEach(NeuterStatus.allCases) { Text($0.rawValue).tag($0) }
                }
                ForEach(Array(vm.errors.values), id: \.self) {
                    Text($0).font(.footnote).foregroundStyle(.red)
                }
            }
            .navigationTitle("宠物档案")
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("保存") { if vm.save() { dismiss() } }
                    .accessibilityIdentifier("pet.save")
            } }
        }
    }

    /// PRD §1「品种从预设列表选择或自定义」：预设 Menu 填充 + 自由输入兜底
    @ViewBuilder private var breedField: some View {
        let presets = BreedCatalog.breeds(for: vm.draft.species)
        if !presets.isEmpty {
            Menu("从常见\(vm.draft.species.rawValue)品种选择") {
                ForEach(presets, id: \.self) { b in Button(b) { vm.draft.breed = b } }
            }
            .accessibilityIdentifier("pet.breedPresets")
        }
        TextField("品种（可选择预设或自定义）", text: $vm.draft.breed)
            .accessibilityIdentifier("pet.breed")
    }
}
