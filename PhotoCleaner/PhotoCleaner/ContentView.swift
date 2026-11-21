import SwiftUI
import Photos
import UIKit

struct DeletionResult: Identifiable {
    let id = UUID()
    let count: Int
    let bytes: Int64
}

@MainActor
struct ContentView: View {
    @StateObject private var manager = PhotoLibraryManager()
    @State private var selectedIDs: Set<String> = []
    @State private var showDeleteConfirmation = false
    @State private var result: DeletionResult?

    private var selectedItems: [PhotoItem] {
        manager.items.filter { selectedIDs.contains($0.id) }
    }

    private var selectedBytes: Int64 {
        selectedItems.reduce(Int64(0)) { $0 + $1.bytes }
    }

    var body: some View {
        NavigationStack {
            Group {
                switch manager.authorizationStatus {
                case .notDetermined:
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("正在请求相册访问权限…")
                            .foregroundStyle(.secondary)
                    }
                case .denied, .restricted:
                    PermissionView()
                default:
                    libraryContent
                }
            }
            .navigationTitle("相册清理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .sheet(item: $result) { CleanupResultView(result: $0) }
            .alert("确认删除", isPresented: $showDeleteConfirmation) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) { performDelete() }
            } message: {
                Text("将 \(selectedIDs.count) 项（约 \(ByteFormatter.string(selectedBytes))）移到「最近删除」。之后需要在照片 App 中彻底删除，才会真正释放空间。")
            }
            .alert("提示", isPresented: Binding(
                get: { manager.errorMessage != nil },
                set: { if !$0 { manager.errorMessage = nil } }
            )) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text(manager.errorMessage ?? "")
            }
        }
        .task {
            await manager.requestAuthorization()
            await manager.loadItems()
        }
    }

    // MARK: - 主体列表

    @ViewBuilder
    private var libraryContent: some View {
        if manager.isLoading && manager.items.isEmpty {
            VStack(spacing: 12) {
                ProgressView()
                Text("正在扫描相册文件大小…")
                    .foregroundStyle(.secondary)
            }
        } else if manager.items.isEmpty {
            VStack(spacing: 12) {
                Image(systemName: "photo.stack")
                    .font(.system(size: 56))
                    .foregroundStyle(.secondary)
                Text("相册里暂时没有照片或视频")
                    .foregroundStyle(.secondary)
            }
        } else {
            List {
                Section {
                    ForEach(manager.items) { item in
                        HStack(spacing: 12) {
                            Image(systemName: selectedIDs.contains(item.id) ? "checkmark.circle.fill" : "circle")
                                .font(.title3)
                                .foregroundStyle(
                                    selectedIDs.contains(item.id) ? Color.accentColor : Color.secondary.opacity(0.5)
                                )

                            AssetThumbnail(item: item)

                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.name)
                                    .lineLimit(1)
                                Text(subtitle(for: item))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }

                            Spacer(minLength: 4)

                            Text(ByteFormatter.string(item.bytes))
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { toggle(item) }
                    }
                } header: {
                    Text("共 \(manager.items.count) 项 · 按大小从大到小")
                }
            }
            .listStyle(.plain)
            .refreshable { await manager.loadItems() }
        }
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigationBarLeading) {
            Button(selectedIDs.count == manager.items.count ? "取消全选" : "全选") {
                if selectedIDs.count == manager.items.count {
                    selectedIDs.removeAll()
                } else {
                    selectedIDs = Set(manager.items.map(\.id))
                }
            }
            .disabled(manager.items.isEmpty)
        }

        ToolbarItem(placement: .navigationBarTrailing) {
            Button("刷新") {
                Task { await manager.loadItems() }
            }
        }
    }

    // MARK: - 底部操作栏

    @ViewBuilder
    private var bottomBar: some View {
        VStack(spacing: 8) {
            if manager.pendingReclaimableBytes > 0 {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill")
                    Text("再去「照片 → 相册 → 最近删除 → 全部删除」，可释放约 \(ByteFormatter.string(manager.pendingReclaimableBytes))")
                }
                .font(.footnote)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if manager.authorizationStatus == .limited {
                Text("当前为「有限访问」权限，无法删除。请在系统设置中改为「所有照片」。")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("已选 \(selectedIDs.count) 项")
                    Text(ByteFormatter.string(selectedBytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Label("删除所选", systemImage: "trash")
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedItems.isEmpty || !manager.canDelete)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    // MARK: - 操作

    private func toggle(_ item: PhotoItem) {
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
        } else {
            selectedIDs.insert(item.id)
        }
    }

    private func performDelete() {
        let selected = selectedItems
        guard !selected.isEmpty else { return }

        Task {
            do {
                let bytes = try await manager.delete(items: selected)
                result = DeletionResult(count: selected.count, bytes: bytes)
                selectedIDs.removeAll()
                await manager.loadItems()
            } catch {
                manager.errorMessage = error.localizedDescription
            }
        }
    }

    private func subtitle(for item: PhotoItem) -> String {
        var parts: [String] = []
        if let date = item.creationDate {
            let formatter = DateFormatter()
            formatter.dateStyle = .medium
            formatter.timeStyle = .none
            parts.append(formatter.string(from: date))
        }
        if item.isVideo { parts.append("视频") }
        return parts.isEmpty ? "照片" : parts.joined(separator: " · ")
    }
}

// MARK: - 权限提示页

struct PermissionView: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("需要访问你的相册")
                .font(.title2.bold())
            Text("用于按文件大小排序并批量移入「最近删除」。文件不会被本 App 直接永久删除。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("前往系统设置") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }
}

// MARK: - 删除结果页

struct CleanupResultView: View {
    let result: DeletionResult
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 72))
                    .foregroundStyle(.green)

                VStack(spacing: 4) {
                    Text("已移入「最近删除」")
                        .font(.title2.bold())
                    Text("共 \(result.count) 项")
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 8) {
                    Text("去「最近删除」彻底删除，可释放约")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(ByteFormatter.string(result.bytes))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(.orange)
                }
                .padding()
                .frame(maxWidth: .infinity)
                .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 16))

                VStack(alignment: .leading, spacing: 6) {
                    Text("操作路径").font(.headline)
                    Text("1. 打开系统「照片」App\n2. 底部「相册」→「最近删除」\n3. 右上角「选择」→「全部删除」")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button {
                    if let url = URL(string: "photos://") {
                        UIApplication.shared.open(url)
                    }
                } label: {
                    Label("打开照片 App", systemImage: "photo")
                }
                .buttonStyle(.borderedProminent)

                Spacer()
            }
            .padding(24)
            .navigationTitle("清理完成")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
