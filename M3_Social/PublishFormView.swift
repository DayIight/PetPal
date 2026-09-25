import SwiftUI

// MARK: - 发布动态表单：文本 + 关联宠物（必选，来自 CoreDataPetRepository）+ 可见性（默认仅粉丝）
struct PublishFormView: View {
    @ObservedObject var vm: FeedViewModel
    @StateObject private var petStore: CurrentPetStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var petID: UUID?
    @State private var visibility: Visibility = .default
    @State private var isPublishing = false
    @State private var errorMessage: String?

    init(vm: FeedViewModel) {
        self.vm = vm
        _petStore = StateObject(wrappedValue: CurrentPetStore(repo: CoreDataPetRepository()))
    }

    var body: some View {
        Form {
            Section("动态内容") {
                TextEditor(text: $text)
                    .frame(minHeight: 120)
                    .accessibilityIdentifier("publish.text")
            }
            Section("关联宠物（必选）") {
                if petStore.pets.isEmpty {
                    Text("暂无宠物档案，请先在首页创建")
                        .font(.callout).foregroundStyle(.secondary)
                        .accessibilityIdentifier("publish.noPet")
                } else {
                    Picker("关联宠物", selection: $petID) {
                        ForEach(petStore.pets) { pet in
                            Text(pet.nickname).tag(Optional(pet.id))
                        }
                    }
                    .accessibilityIdentifier("publish.pet")
                }
            }
            Section("可见范围") {
                Picker("可见范围", selection: $visibility) {
                    ForEach(Visibility.allCases) { Text($0.rawValue).tag($0) }
                }
                .accessibilityIdentifier("publish.visibility")
            }
        }
        .navigationTitle("发布动态")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("发布") { publish() }
                    .disabled(isPublishing || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || petID == nil)
                    .accessibilityIdentifier("publish.submit")
            }
        }
        // 宠物列表加载后默认选中当前宠物（用户可改选；发布必须关联宠物）
        .onReceive(petStore.$current) { current in
            if petID == nil { petID = current?.id }
        }
        .alert("发布失败", isPresented: .init(get: { errorMessage != nil },
                                              set: { if !$0 { errorMessage = nil } })) {
            Button("好", role: .cancel) {}
        } message: { Text(errorMessage ?? "") }
    }

    /// 发布成功后 pop 回信息流；Mock 将新动态插到首位，回到列表顶部即见
    private func publish() {
        guard let petID else { return }
        isPublishing = true
        Task {
            do {
                try await vm.publish(text: text, petID: petID, imageURLs: [], visibility: visibility)
                dismiss()
            } catch {
                isPublishing = false
                errorMessage = "发布失败，请重试"
            }
        }
    }
}
