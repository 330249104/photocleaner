import Foundation
import Photos
import UIKit

// MARK: - 数据模型

struct PhotoItem: Identifiable, Equatable {
    let id: String
    let asset: PHAsset
    let name: String
    let bytes: Int64
    let creationDate: Date?
    let isVideo: Bool

    static func == (lhs: PhotoItem, rhs: PhotoItem) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - 错误提示

enum PhotoCleanerError: LocalizedError {
    case noAccess
    case limitedAccess
    case deleteRejected

    var errorDescription: String? {
        switch self {
        case .noAccess:
            return "无法访问相册。请到「设置 → 隐私与安全性 → 照片」中允许访问。"
        case .limitedAccess:
            return "当前是「有限访问」权限，无法删除照片。请在系统设置中改为「所有照片」后重试。"
        case .deleteRejected:
            return "系统拒绝了删除请求，请稍后重试。"
        }
    }
}

// MARK: - 格式化

enum ByteFormatter {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - 相册管理

@MainActor
final class PhotoLibraryManager: ObservableObject {
    @Published private(set) var items: [PhotoItem] = []
    @Published private(set) var isLoading = false
    @Published private(set) var authorizationStatus: PHAuthorizationStatus = .notDetermined
    @Published private(set) var pendingReclaimableBytes: Int64 = 0
    @Published var errorMessage: String?

    var canDelete: Bool {
        authorizationStatus == .authorized
    }

    // MARK: 权限

    func requestAuthorization() async {
        let status: PHAuthorizationStatus
        if #available(iOS 14.0, *) {
            status = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { continuation.resume(returning: $0) }
            }
        } else {
            status = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization { continuation.resume(returning: $0) }
            }
        }
        authorizationStatus = status
    }

    // MARK: 扫描并按文件大小排序

    func loadItems() async {
        guard authorizationStatus == .authorized || authorizationStatus == .limited else { return }
        isLoading = true
        defer { isLoading = false }

        let scanned = await Task.detached(priority: .userInitiated) {
            let options = PHFetchOptions()
            options.includeHiddenAssets = false
            let result = PHAsset.fetchAssets(with: options)

            var list: [PhotoItem] = []
            list.reserveCapacity(result.count)

            result.enumerateObjects { asset, _, _ in
                let resources = PHAssetResource.assetResources(for: asset)

                // 逐个资源相加：Live Photo 会同时包含 JPEG 和 MOV，这才是实际占用空间
                var total: Int64 = 0
                for resource in resources {
                    if let number = resource.value(forKey: "fileSize") as? NSNumber {
                        total += number.int64Value
                    }
                }

                let primary = resources.first { $0.type == .photo || $0.type == .video } ?? resources.first
                let name = primary?.originalFilename ?? asset.localIdentifier

                list.append(
                    PhotoItem(
                        id: asset.localIdentifier,
                        asset: asset,
                        name: name,
                        bytes: total,
                        creationDate: asset.creationDate,
                        isVideo: asset.mediaType == .video
                    )
                )
            }

            return list.sorted {
                if $0.bytes != $1.bytes { return $0.bytes > $1.bytes }
                return ($0.creationDate ?? .distantPast) > ($1.creationDate ?? .distantPast)
            }
        }.value

        items = scanned
    }

    // MARK: 批量删除（移入「最近删除」）

    /// 返回本次删除的文件总大小，用于提示用户彻底删除后可释放的空间
    func delete(items selected: [PhotoItem]) async throws -> Int64 {
        guard canDelete else {
            throw authorizationStatus == .limited ? PhotoCleanerError.limitedAccess : PhotoCleanerError.noAccess
        }
        guard !selected.isEmpty else { return 0 }

        let assets = selected.map(\.asset)
        let bytes = selected.reduce(Int64(0)) { $0 + $1.bytes }

        let success = await withCheckedContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.deleteAssets(assets as NSArray)
            } completionHandler: { ok, _ in
                continuation.resume(returning: ok)
            }
        }

        guard success else { throw PhotoCleanerError.deleteRejected }

        // iOS 16+ 第三方 App 无法读取「最近删除」相簿，
        // 因此用本 App 删除掉的资产大小作为「可释放空间」的估算值。
        pendingReclaimableBytes += bytes
        return bytes
    }
}
