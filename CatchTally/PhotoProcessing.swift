import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Downscale + recompress a picked photo into the app's private copy
/// (issue #4): pickers hand back full-resolution HEIC/JPEG data; the copy
/// the app stores is bounded in size so a season of photos stays small.
/// The user's original in their library is NEVER touched or rewritten.
enum PhotoProcessing {
    /// Longest edge of the stored copy, in points.
    static let maxDimension: CGFloat = 1280
    static let compressionQuality: CGFloat = 0.8

    /// Returns JPEG bytes for the downscaled copy, or nil if the input
    /// isn't a decodable image (caller surfaces a retryable error).
    static func downscaledJPEG(from data: Data) -> Data? {
        #if canImport(UIKit)
        guard let image = UIImage(data: data) else { return nil }
        let largest = max(image.size.width, image.size.height)
        guard largest > 0 else { return nil }
        let scale = min(1, maxDimension / largest)
        guard scale < 1 else {
            return image.jpegData(compressionQuality: compressionQuality)
        }
        let target = CGSize(
            width: (image.size.width * scale).rounded(),
            height: (image.size.height * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1  // work in points, not device pixels
        // Rendering through the renderer also normalizes EXIF orientation.
        let resized = UIGraphicsImageRenderer(size: target, format: format).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return resized.jpegData(compressionQuality: compressionQuality)
        #else
        // Non-UIKit hosts (Linux CI) never run the picker; the workbench
        // tests inject synthetic bytes straight into the photo store.
        return data
        #endif
    }
}
