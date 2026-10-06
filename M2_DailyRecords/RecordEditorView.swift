import SwiftUI
import PhotosUI

/// 创建和编辑共用同一表单；自定义记录始终使用记录自身的字段快照。
struct RecordEditorView: View {
    @StateObject var vm: RecordFormViewModel
    let onSaved: () -> Void
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var isLoadingPhotos = false
    @State private var showCamera = false

    private var prefix: String { vm.draft.kind == .custom ? "custom" : "record" }
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }()

    var body: some View {
        Form {
            if vm.draft.kind == .custom && vm.draft.templateSnapshot == nil {
                Section {
                    Text("这条历史记录未保存字段名称。原答案已保留，可逐项修改。")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            ForEach(vm.draft.fields, id: \.key) { field in
                Section(field.title) { fieldView(field) }
            }
            Section("备注与心情") {
                TextField("备注（≤200字）", text: $vm.draft.note)
                    .accessibilityIdentifier("\(prefix).note")
                Picker("心情", selection: $vm.draft.mood) {
                    Text("未选择").tag("")
                    ForEach(Array(Set(["😀", "😐", "😢", vm.draft.mood].filter { !$0.isEmpty })).sorted(), id: \.self) {
                        Text($0).tag($0)
                    }
                }
                .accessibilityIdentifier("\(prefix).mood")
            }
            photoSection
        }
        .navigationTitle("\(vm.draft.displayKind)记录")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .top, spacing: 0) {
            if !vm.errors.isEmpty {
                Text(vm.errors.joined(separator: "\n"))
                    .font(.footnote).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding().background(Color(.systemBackground))
                    .accessibilityIdentifier("\(prefix).errors")
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { if vm.save() { onSaved() } }
                    .disabled(isLoadingPhotos)
                    .accessibilityIdentifier("\(prefix).save")
            }
        }
        .onChange(of: photoItems) { items in
            guard !items.isEmpty else { return }
            isLoadingPhotos = true
            Task { @MainActor in
                defer { photoItems = []; isLoadingPhotos = false }
                for item in items {
                    do {
                        guard let data = try await item.loadTransferable(type: Data.self) else {
                            vm.reportPhotoError(); break
                        }
                        if !vm.addPhoto(data) { break }
                    } catch { vm.reportPhotoError(); break }
                }
            }
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { image in
                if let data = image.jpegData(compressionQuality: 0.9) { vm.addPhoto(data) }
                else { vm.reportPhotoError() }
            }
        }
        .interactiveDismissDisabled(isLoadingPhotos)
    }

    @ViewBuilder private func fieldView(_ field: TemplateField) -> some View {
        switch field.kind {
        case .text:
            TextField(field.title, text: answer(field.key))
                .accessibilityIdentifier("\(prefix).field.\(field.key)")
        case .multiline:
            TextEditor(text: answer(field.key)).frame(minHeight: 80)
                .accessibilityIdentifier("\(prefix).field.\(field.key)")
        case .number:
            TextField("数字", text: answer(field.key)).keyboardType(.decimalPad)
                .accessibilityIdentifier("\(prefix).field.\(field.key)")
        case .single(let options):
            Picker(field.title, selection: answer(field.key)) {
                Text("未选择").tag("")
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
            .accessibilityIdentifier("\(prefix).field.\(field.key)")
        case .multi(let options):
            ForEach(options, id: \.self) { option in
                Toggle(option, isOn: Binding(
                    get: { selected(field.key).contains(option) },
                    set: { enabled in
                        var values = selected(field.key)
                        if enabled { values.insert(option) } else { values.remove(option) }
                        vm.draft.answers[field.key] = values.sorted().joined(separator: ",")
                    }))
                .accessibilityIdentifier("\(prefix).field.\(field.key).\(option)")
            }
        case .toggle:
            Toggle(field.title, isOn: Binding(
                get: { vm.draft.answers[field.key] == "true" },
                set: { vm.draft.answers[field.key] = $0 ? "true" : "false" }))
            .accessibilityIdentifier("\(prefix).field.\(field.key)")
        case .date:
            if !field.isRequired {
                Toggle("填写日期", isOn: Binding(
                    get: { !(vm.draft.answers[field.key] ?? "").isEmpty },
                    set: { vm.draft.answers[field.key] = $0 ? Self.dateFormatter.string(from: Date()) : "" }))
            }
            if field.isRequired || !(vm.draft.answers[field.key] ?? "").isEmpty {
                DatePicker(field.title, selection: Binding(
                    get: { vm.draft.answers[field.key].flatMap(Self.dateFormatter.date) ?? Date() },
                    set: { vm.draft.answers[field.key] = Self.dateFormatter.string(from: $0) }),
                    displayedComponents: .date)
                    .accessibilityIdentifier("\(prefix).field.\(field.key)")
            }
        }
    }

    private func answer(_ key: String) -> Binding<String> {
        Binding(get: { vm.draft.answers[key] ?? "" }, set: { vm.draft.answers[key] = $0 })
    }
    private func selected(_ key: String) -> Set<String> {
        Set((vm.draft.answers[key] ?? "").split(separator: ",").map(String.init))
    }

    private var photoSection: some View {
        Section("照片（\(vm.photoCount)/9）") {
            ScrollView(.horizontal) {
                HStack {
                    ForEach(vm.draft.photoFileNames, id: \.self) { file in
                        photoPreview(AvatarStore.load(fileName: file), id: file) {
                            vm.draft.photoFileNames.removeAll { $0 == file }
                        }
                    }
                    ForEach(vm.pendingPhotos) { photo in
                        photoPreview(photo.image, id: photo.id.uuidString) {
                            vm.removePendingPhoto(id: photo.id)
                        }
                    }
                }
            }
            if vm.photoCount < MediaPolicy.maxPhotos {
                PhotosPicker(selection: $photoItems, maxSelectionCount: MediaPolicy.maxPhotos - vm.photoCount,
                             matching: .images) {
                    Label(isLoadingPhotos ? "正在加载照片…" : "从相册添加照片", systemImage: "photo.badge.plus")
                }
                .disabled(isLoadingPhotos)
                .accessibilityIdentifier("record.addPhotos")
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("拍照") { showCamera = true }.disabled(isLoadingPhotos)
                }
            }
        }
    }

    private func photoPreview(_ image: UIImage?, id: String, remove: @escaping () -> Void) -> some View {
        VStack {
            Group {
                if let image { Image(uiImage: image).resizable().scaledToFill() }
                else { Image(systemName: "photo").foregroundStyle(.secondary) }
            }
            .frame(width: 80, height: 80).clipped()
            Button("移除", role: .destructive, action: remove)
                .accessibilityIdentifier("record.removePhoto.\(id)")
        }
    }
}
