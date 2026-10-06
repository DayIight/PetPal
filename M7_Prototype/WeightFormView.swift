import SwiftUI
import Combine

// MARK: - 体重录入（M5 CoreDataWeightRepository.add 的 UI 落点；入口在首页「记体重」）

struct WeightFormView: View {
    let petID: UUID
    private let editing: WeightSample?
    @State private var sampleID: UUID
    init(petID: UUID, editing: WeightSample? = nil) {
        self.petID = petID; self.editing = editing
        _sampleID = State(initialValue: editing?.id ?? UUID())
        _kg = State(initialValue: editing?.kg ?? 5)
        _date = State(initialValue: editing?.date ?? Date())
    }
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
            .navigationTitle(editing == nil ? "记体重" : "编辑体重")
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
            let sample = WeightSample(id: sampleID, petID: petID, kg: kg, date: date)
            if editing == nil { try repo.add(sample) } else { try repo.update(sample) }
            dismiss()
        } catch {
            self.error = "保存失败：" + error.localizedDescription
        }
    }
}


struct WeightHistoryView: View {
    let pet: Pet
    let pets: [Pet]
    @State private var selectedPetID: UUID
    @State private var samples: [WeightSample] = []
    @State private var editing: WeightSample?
    @State private var sourceRecord: Record?
    @State private var showAdd = false
    @State private var error: String?
    @State private var sourceSubscription: AnyCancellable?
    private let repo = CoreDataWeightRepository()
    private let recordRepo = CoreDataRecordRepository()
    @Environment(\.dismiss) private var dismiss

    init(pet: Pet, pets: [Pet]) {
        self.pet = pet
        self.pets = pets
        _selectedPetID = State(initialValue: pet.id)
    }

    private var availablePets: [Pet] { pets.isEmpty ? [pet] : pets }
    private var selectedPet: Pet {
        availablePets.first(where: { $0.id == selectedPetID }) ?? availablePets[0]
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("宠物", selection: $selectedPetID) {
                        ForEach(availablePets) { pet in
                            Text("\(pet.nickname)（\(pet.species.rawValue)）").tag(pet.id)
                        }
                    }
                    .pickerStyle(.menu)
                    .disabled(availablePets.count < 2)
                    .accessibilityIdentifier("weightHistory.petPicker")
                }
                Text("当前体重采用日期最新的体重记录；没有记录时采用档案中的初始体重。体检数据请到来源记录修改。")
                    .font(.footnote).foregroundStyle(.secondary)
                if let error { Text(error).foregroundStyle(.red) }
                if samples.isEmpty {
                    Text("\(selectedPet.nickname)暂无体重记录")
                        .accessibilityIdentifier("weightHistory.empty")
                }
                ForEach(samples) { sample in
                    Button {
                        if let id = sample.sourceRecordID {
                            sourceSubscription = recordRepo.recordsPublisher(petID: sample.petID)
                                .first().receive(on: DispatchQueue.main).sink { records in
                                guard selectedPet.id == sample.petID else { return }
                                if let record = records.first(where: { $0.id == id }) { sourceRecord = record }
                                else { error = "来源记录不存在，请刷新后重试" }
                            }
                        } else { editing = sample }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(sample.date, style: .date)
                                Text(sample.sourceRecordID == nil ? "手动录入" : "来自体检 · 点此编辑来源")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(String(format: "%.1f kg", sample.kg))
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("weightHistory.sample.\(sample.id.uuidString)")
                    .swipeActions {
                        if sample.sourceRecordID == nil {
                            Button("删除", role: .destructive) {
                                do { try repo.delete(id: sample.id); reload() }
                                catch { self.error = "删除失败：" + error.localizedDescription }
                            }
                        }
                    }
                }
            }
            .navigationTitle("\(selectedPet.nickname)的体重记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("weightHistory.done")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("新增") { showAdd = true }.accessibilityIdentifier("weightHistory.add")
                }
            }
            .sheet(isPresented: $showAdd, onDismiss: reload) { WeightFormView(petID: selectedPet.id) }
            .sheet(item: $editing, onDismiss: reload) { WeightFormView(petID: $0.petID, editing: $0) }
            .sheet(item: $sourceRecord, onDismiss: reload) { RecordDetailView(record: $0) }
            .onAppear(perform: reload)
            .onChange(of: selectedPetID) { _ in
                sourceSubscription?.cancel()
                sourceSubscription = nil
                reload()
            }
            .onChange(of: availablePets.map(\.id)) { ids in
                if !ids.contains(selectedPetID), let firstID = ids.first {
                    selectedPetID = firstID
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .weightsDidChange)) { _ in reload() }
        }
    }
    private func reload() {
        do { samples = try repo.samples(petID: selectedPet.id).sorted { $0.date > $1.date }; error = nil }
        catch { samples = []; self.error = "读取失败：" + error.localizedDescription }
    }
}
