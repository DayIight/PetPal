import SwiftUI
import PhotosUI

// MARK: - 记录照片选择（横排缩略图 + 删除 + 拍照/相册，预设与自定义记录表单共用）
// 交互范式与 M3 PublishFormView 的 photoStrip 一致；保存策略（何时落盘）由调用方经回调决定
struct RecordPhotoPicker: View {
    /// 已落盘的照片文件名（编辑模式回填；新建为空）
    let savedFileNames: [String]
    /// 本次新选、尚未落盘的图片
    let pickedImages: [UIImage]
    /// a11y id 前缀（"record.photo" / "custom.photo"）
    let a11yPrefix: String
    let onAddData: (Data) -> Void
    let onAddImage: (UIImage) -> Void
    let onRemoveSaved: (String) -> Void
    let onRemovePicked: (Int) -> Void

    @State private var showPhotoOptions = false
    @State private var showLibrary = false
    @State private var showCamera = false
    @State private var photoItems: [PhotosPickerItem] = []

    private var totalCount: Int { savedFileNames.count + pickedImages.count }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DS.Spacing.sm) {
                ForEach(savedFileNames, id: \.self) { name in
                    if let image = AvatarStore.load(fileName: name) {
                        thumb(image: image,
                              a11y: "\(a11yPrefix).saved.\(name)") {
                            onRemoveSaved(name)
                        }
                    }
                }
                ForEach(Array(pickedImages.enumerated()), id: \.offset) { index, image in
                    thumb(image: image,
                          a11y: "\(a11yPrefix).\(index)") {
                        onRemovePicked(index)
                    }
                }
                if totalCount < MediaPolicy.maxPhotos {
                    Button { showPhotoOptions = true } label: {
                        Image(systemName: "plus")
                            .font(.title3)
                            .frame(width: 64, height: 64)
                            .background(Color.groupedBackground,
                                        in: RoundedRectangle(cornerRadius: DS.Radius.control,
                                                             style: .continuous))
                            .foregroundStyle(Color.accentColor)
                    }
                    .a11y("添加照片", hint: "拍照或从相册选择，最多\(MediaPolicy.maxPhotos)张")
                    .accessibilityIdentifier("\(a11yPrefix).add")
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
                      maxSelectionCount: max(1, MediaPolicy.maxPhotos - totalCount), matching: .images)
        .onChange(of: photoItems) { items in
            guard !items.isEmpty else { return }
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        onAddData(data)
                    }
                }
                photoItems = []
            }
        }
        .sheet(isPresented: $showCamera) {
            CameraPicker { image in onAddImage(image) }
                .ignoresSafeArea()
        }
    }

    /// 64×64 缩略图 + 右上角删除钮（样式与发布表单一致）
    private func thumb(image: UIImage, a11y: String,
                       onRemove: @escaping () -> Void) -> some View {
        Image(uiImage: image)
            .resizable().scaledToFill()
            .frame(width: 64, height: 64)
            .clipped()
            .cornerRadius(DS.Radius.control)
            .overlay(alignment: .topTrailing) {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.secondary)
                }
                .offset(x: 6, y: -6)
                .a11y("删除照片")
                .accessibilityIdentifier("\(a11y).remove")
            }
            .accessibilityIdentifier(a11y)
    }
}
