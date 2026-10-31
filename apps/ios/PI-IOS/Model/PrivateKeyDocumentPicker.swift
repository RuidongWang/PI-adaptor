import SwiftUI
import UIKit
import PIiOSNet

/// 私钥文件选择器（就地打开，不复制）。
///
/// 两个真机才会踩到的坑：
///
/// 1. **类型被置灰**：`.key` 被系统认成 `com.apple.iwork.keynote.sffkey`（Keynote 的 package 类型），
///    复制型选择器（`.fileImporter` / `asCopy: true`）会把这类包置灰——用户看到的是「文件在列表里
///    却点不动」。所以这里用 `asCopy: false` 的就地打开，类型只要符合 `public.item` 就能选中。
/// 2. **套在 SwiftUI `.sheet` 里点不动**：`UIDocumentPickerViewController` 是模态控制器，
///    用 `UIViewControllerRepresentable` 把它内嵌成 sheet 内容时，导航栏与点击命中都不可靠
///    （模拟器常常看不出问题，真机上表现为「列表能翻但选不中」）。所以这里只放一个透明宿主
///    控制器，由它 `present` 真正的选择器。
struct PrivateKeyDocumentPicker: UIViewControllerRepresentable {
    let onPick: (Result<URL, Error>) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> PickerHostController {
        let host = PickerHostController()
        host.onFirstAppear = { [weak host] in
            guard let host else { return }
            let picker = UIDocumentPickerViewController(
                forOpeningContentTypes: SSHPrivateKeyFileLoader.allowedContentTypes,
                asCopy: false
            )
            picker.allowsMultipleSelection = false
            picker.shouldShowFileExtensions = true
            picker.delegate = context.coordinator
            host.present(picker, animated: true)
        }
        return host
    }

    func updateUIViewController(_ controller: PickerHostController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick, onCancel: onCancel)
    }

    /// 透明宿主：不为界面服务，只为拿到一个「可以 present 的控制器」。
    final class PickerHostController: UIViewController {
        var onFirstAppear: (() -> Void)?

        override func loadView() {
            let view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            self.view = view
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            // 只 present 一次：sheet 重新出现（例如键盘收起）时不能再弹。
            let action = onFirstAppear
            onFirstAppear = nil
            action?()
        }
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onPick: (Result<URL, Error>) -> Void
        private let onCancel: () -> Void

        init(onPick: @escaping (Result<URL, Error>) -> Void, onCancel: @escaping () -> Void) {
            self.onPick = onPick
            self.onCancel = onCancel
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else {
                onCancel()
                return
            }
            // 就地打开返回的是 file provider 提供的 URL：安全作用域一放开、或选择器一关，
            // 同一个 URL 就可能读不到了（真机上表现为「选完加载不进来」）。所以要在委托
            // 回调里立刻复制一份到沙盒临时目录，上层之后读的是普通文件，不再受 provider 影响。
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let directory = FileManager.default.temporaryDirectory
                    .appendingPathComponent("piios-picked-key-\(UUID().uuidString)", isDirectory: true)
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let name = url.lastPathComponent.isEmpty ? "private-key" : url.lastPathComponent
                let copy = directory.appendingPathComponent(name)
                try FileManager.default.copyItem(at: url, to: copy)
                onPick(.success(copy))
            } catch {
                onPick(.failure(error))
            }
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            // 取消不改任何状态：已选/已保存的私钥继续沿用。
            onCancel()
        }
    }
}
