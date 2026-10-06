import SwiftUI

// MARK: - 建档表单（PRD §1：物种必选、品种预设列表+自定义；支持新建与编辑复用）
struct PetFormView: View {
    @StateObject var vm: PetFormViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var customAllergen = ""
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
                Text("修改体重会新增今日体重记录；当前体重采用最新日期的体重记录。")
                    .font(.footnote).foregroundStyle(.secondary)
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
                    allergenField
                }
                if let error = vm.saveError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                        .accessibilityIdentifier("pet.saveError")
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

    /// 选填字段绑定桥：空串视为 nil（不污染可选字段），格式校验由 PetValidator 保存时拦截
    private func optionalText(_ keyPath: WritableKeyPath<Pet, String?>) -> Binding<String> {
        Binding(get: { vm.draft[keyPath: keyPath] ?? "" },
                set: { vm.draft[keyPath: keyPath] = $0.isEmpty ? nil : $0 })
    }

    /// 过敏源：预设标签多选 Toggle + 自定义输入追加；自定义项可单独移除
    @ViewBuilder private var allergenField: some View {
        Text("过敏源").font(.body)
        ForEach(AllergenCatalog.presets, id: \.self) { item in
            Toggle(item, isOn: allergenBinding(item))
                .accessibilityIdentifier("pet.allergen.\(item)")
        }
        let customs = vm.draft.allergens.filter { !AllergenCatalog.presets.contains($0) }
        ForEach(customs, id: \.self) { item in
            HStack {
                Text(item)
                Spacer()
                Button {
                    vm.draft.allergens.removeAll { $0 == item }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .a11y("移除过敏源\(item)")
                .accessibilityIdentifier("pet.allergen.remove.\(item)")
            }
        }
        HStack {
            TextField("自定义过敏源", text: $customAllergen)
                .accessibilityIdentifier("pet.allergenInput")
            Button("添加") {
                let value = customAllergen.trimmingCharacters(in: .whitespaces)
                guard !value.isEmpty, !vm.draft.allergens.contains(value) else { return }
                vm.draft.allergens.append(value)
                customAllergen = ""
            }
            .disabled(customAllergen.trimmingCharacters(in: .whitespaces).isEmpty)
            .accessibilityIdentifier("pet.allergenAdd")
        }
    }

    private func allergenBinding(_ item: String) -> Binding<Bool> {
        Binding(
            get: { vm.draft.allergens.contains(item) },
            set: { isOn in
                if isOn {
                    if !vm.draft.allergens.contains(item) { vm.draft.allergens.append(item) }
                } else {
                    vm.draft.allergens.removeAll { $0 == item }
                }
            })
    }
}
