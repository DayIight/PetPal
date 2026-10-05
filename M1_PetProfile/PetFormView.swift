import SwiftUI

// MARK: - 建档表单（PRD §1：物种必选、品种预设列表+自定义；支持新建与编辑复用）
struct PetFormView: View {
    @StateObject var vm: PetFormViewModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: DS.Spacing.xs) {
                            AvatarPickerView(nickname: vm.draft.nickname,
                                             avatarFileName: vm.avatarRemoved ? nil : vm.draft.avatarFileName,
                                             pickedImage: vm.pickedAvatar,
                                             onPick: { vm.pickAvatar($0) },
                                             onRemove: { vm.removeAvatar() })
                            Text("设置头像").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }
                Picker("物种", selection: $vm.draft.species) {
                    ForEach(PetSpecies.allCases) { Text($0.rawValue).tag($0) }
                }
                .accessibilityIdentifier("pet.species")
                TextField("昵称", text: $vm.draft.nickname)
                    .accessibilityIdentifier("pet.nickname")
                breedField
                DatePicker("生日", selection: $vm.draft.birthday, in: ...Date(),
                           displayedComponents: .date)
                // 直接输入 + ±0.1 微调双通道；越界值由 PetValidator 在保存时拦截
                HStack {
                    TextField("体重", value: $vm.draft.weightKg, format: .number)
                        .keyboardType(.decimalPad)
                        .accessibilityIdentifier("pet.weightInput")
                    Text("kg").foregroundStyle(.secondary)
                    Stepper("", value: $vm.draft.weightKg, in: WeightValidator.kgRange, step: 0.1)
                        .labelsHidden()
                        .a11y("微调体重", hint: "每次增减0.1kg")
                }
                Picker("绝育状态", selection: $vm.draft.neuterStatus) {
                    ForEach(NeuterStatus.allCases) { Text($0.rawValue).tag($0) }
                }
                Section("其他信息（选填）") {
                    TextField("芯片号（15位数字）", text: optionalText(\.chipNumber))
                        .keyboardType(.numberPad)
                        .accessibilityIdentifier("pet.chipNumber")
                    TextField("兽医", text: optionalText(\.vetName))
                        .accessibilityIdentifier("pet.vetName")
                    TextField("兽医电话", text: optionalText(\.vetPhone))
                        .keyboardType(.phonePad)
                        .accessibilityIdentifier("pet.vetPhone")
                }
                ForEach(Array(vm.errors.values), id: \.self) {
                    Text($0).font(.footnote).foregroundStyle(.red)
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if let saveError = vm.saveError {
                    Text(saveError).font(.footnote).foregroundStyle(.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(Color(.systemBackground))
                        .accessibilityIdentifier("pet.saveError")
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

    /// 选填字段绑定桥：空串视为 nil（不污染可选字段），格式校验由 PetValidator 保存时拦截
    private func optionalText(_ keyPath: WritableKeyPath<Pet, String?>) -> Binding<String> {
        Binding(get: { vm.draft[keyPath: keyPath] ?? "" },
                set: { vm.draft[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }
}
