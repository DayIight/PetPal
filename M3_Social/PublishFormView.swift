import SwiftUI
import PhotosUI

// MARK: - 发布动态表单：文本 + 照片（≤9张，拍照/相册）+ 关联宠物（必选，来自 CoreDataPetRepository）+ 可见性（默认仅粉丝）
struct PublishFormView: View {
    @ObservedObject var vm: FeedViewModel
    @StateObject private var petStore: CurrentPetStore
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var petID: UUID?
    @State private var visibility: Visibility = .default
    @State private var isPublishing = false
    @State private var errorMessage: String?
    @State private var pickedImages: [UIImage] = []
    @State private var showPhotoOptions = false
    @State private var showLibrary = false
    @State private var showCamera = false
    @State private var photoItems: [PhotosPickerItem] = []

    private let maxPhotos = 9

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
            Section("照片（选填，最多\(maxPhotos)张）") {
                photoStrip
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
        // 照片先经 AvatarStore 压缩落盘（≤1080px、JPEG 0.8），以 file URL 交给信息流按 URL 加载
        let imageURLs = pickedImages.compactMap { AvatarStore.save($0).map(AvatarStore.url(for:)) }
        Task {
            do {
                try await vm.publish(text: text, petID: petID, imageURLs: imageURLs, visibility: visibility)
                dismiss()
            } catch {
                isPublishing = false
                errorMessage = "发布失败，请重试"
            }
        }
    }

    // MARK: 照片横排：已选缩略图（右上角可删）+ 添加入口（拍照 / 相册）
    private var photoStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.sm) {
                ForEach(Array(pickedImages.enumerated()), id: \.offset) { index, image in
                    Image(uiImage: image)
                        .resizable().scaledToFill()
                        .frame(width: 64, height: 64)
                        .clipped()
                        .cornerRadius(DS.Radius.control)
                        .overlay(alignment: .topTrailing) {
                            Button { pickedImages.remove(at: index) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, Color.secondary)
                            }
                            .offset(x: 6, y: -6)
                            .a11y("删除第\(index + 1)张照片")
                            .accessibilityIdentifier("publish.removePhoto.\(index)")
                        }
                        .accessibilityIdentifier("publish.photo.\(index)")
                }
                if pickedImages.count < maxPhotos {
                    Button { showPhotoOptions = true } label: {
                        Image(systemName: "plus")
                            .font(.title3)
                            .frame(width: 64, height: 64)
                            .background(Color.groupedBackground,
                                        in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                            .foregroundStyle(Color.accentColor)
                    }
                    .a11y("添加照片", hint: "拍照或从相册选择，最多\(maxPhotos)张")
                    .accessibilityIdentifier("publish.addPhoto")
                }
            }
            .padding(.vertical, DS.Spacing.xs)
        }
        .confirmationDialog("添加照片", isPresented: $showPhotoOptions, titleVisibility: .visible) {
            if UIImagePickerController.isSourceTypeAvailable(.camera) {
                Button("拍照") { showCamera = true }
            }
            Button("从相册选择") { showLibrary = true }
            Button("取消", role: .cancel) {}
        }
        .photosPicker(isPresented: $showLibrary, selection: $photoItems,
                      maxSelectionCount: max(1, maxPhotos - pickedImages.count), matching: .images)
        .onChange(of: photoItems) { items in
            guard !items.isEmpty else { return }
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data), pickedImages.count < maxPhotos {
                        pickedImages.append(image)
                    }
                }
                photoItems = []
            }
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { image in
                if pickedImages.count < maxPhotos { pickedImages.append(image) }
            }
            .ignoresSafeArea()
        }
    }
}
