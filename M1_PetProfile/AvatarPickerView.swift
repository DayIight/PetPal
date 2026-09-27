import SwiftUI
import PhotosUI

// MARK: - 头像选择器（建档/编辑表单与详情页共用）
// 交互：点头像 → confirmationDialog（拍照 / 从相册选择 / 移除照片）→ 回调由调用方决定保存策略
struct AvatarPickerView: View {
    let nickname: String
    var avatarFileName: String?       // 已落盘的头像文件名
    var pickedImage: UIImage?         // 本次新选、尚未保存的图片（优先级最高）
    var diameter: CGFloat = 72
    let onPick: (UIImage) -> Void
    let onRemove: () -> Void

    @State private var showOptions = false
    @State private var showLibrary = false
    @State private var showCamera = false
    @State private var photoItem: PhotosPickerItem?

    private var hasAvatar: Bool {
        pickedImage != nil || avatarFileName?.isEmpty == false
    }

    var body: some View {
        Button { showOptions = true } label: { preview }
            .buttonStyle(.plain)
            .a11y("宠物头像", hint: "点击更换头像，可拍照或从相册选择")
            .accessibilityIdentifier("pet.avatar.picker")
            .confirmationDialog("设置头像", isPresented: $showOptions, titleVisibility: .visible) {
                if UIImagePickerController.isSourceTypeAvailable(.camera) {
                    Button("拍照") { showCamera = true }
                }
                Button("从相册选择") { showLibrary = true }
                if hasAvatar {
                    Button("移除照片", role: .destructive) { onRemove() }
                }
                Button("取消", role: .cancel) {}
            }
            .photosPicker(isPresented: $showLibrary, selection: $photoItem, matching: .images)
            .onChange(of: photoItem) { item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self),
                       let image = UIImage(data: data) {
                        onPick(image)
                    }
                    photoItem = nil
                }
            }
            .sheet(isPresented: $showCamera) {
                CameraPicker(onPick: onPick)
                    .ignoresSafeArea()
            }
    }

    // MARK: 圆形预览 + 右下角相机角标（占位样式与 PetAvatarThumb 一致：昵称首字）
    private var preview: some View {
        Group {
            if let pickedImage {
                Image(uiImage: pickedImage).resizable().scaledToFill()
            } else if let file = avatarFileName, let image = AvatarStore.load(fileName: file) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.15))
                    Text(nickname.prefix(1))
                        .font(.headline)
                        .foregroundStyle(Color.accentColor)
                }
            }
        }
        .frame(width: diameter, height: diameter)
        .clipShape(Circle())
        .overlay(alignment: .bottomTrailing) {
            Image(systemName: "camera.circle.fill")
                .font(.system(size: diameter * 0.3))
                .symbolRenderingMode(.palette)
                .foregroundStyle(.white, Color.accentColor)
                .offset(x: 2, y: 2)
        }
    }
}

// MARK: - 相机封装（iOS 16 无原生 SwiftUI 拍照入口，包一层 UIImagePickerController；动态发布等多图场景共用）
struct CameraPicker: UIViewControllerRepresentable {
    let onPick: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker
        init(_ parent: CameraPicker) { self.parent = parent }
        func imagePickerController(_ picker: UIImagePickerController,
                                   didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage { parent.onPick(image) }
            parent.dismiss()
        }
        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) { parent.dismiss() }
    }
}
