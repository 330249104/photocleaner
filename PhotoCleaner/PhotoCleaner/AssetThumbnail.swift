import SwiftUI
import Photos
import UIKit

struct AssetThumbnail: View {
    let item: PhotoItem
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Color.secondary.opacity(0.12)
                    .overlay {
                        ProgressView()
                            .scaleEffect(0.7)
                    }
            }
        }
        .frame(width: 56, height: 56)
        .clipped()
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .task(id: item.id) {
            let target = CGSize(width: 112, height: 112)
            let fetched: UIImage? = await withCheckedContinuation { continuation in
                let lock = NSLock()
                var finished = false
                PHImageManager.default().requestImage(
                    for: item.asset,
                    targetSize: target,
                    contentMode: .aspectFill,
                    options: nil
                ) { result, _ in
                    lock.lock()
                    guard !finished else {
                        lock.unlock()
                        return
                    }
                    finished = true
                    lock.unlock()
                    continuation.resume(returning: result)
                }
            }
            image = fetched
        }
    }
}
