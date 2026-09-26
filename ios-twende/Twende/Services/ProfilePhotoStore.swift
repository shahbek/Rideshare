import UIKit

/// The face crop from a scanned ID, kept only when the passenger chooses it as their profile photo.
/// Stored in Application Support, excluded from backups; the full ID image is never written anywhere.
nonisolated enum ProfilePhotoStore {
    private static var url: URL? {
        guard let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("zuri-profile-photo.jpg")
    }

    static func save(_ image: UIImage) {
        guard var url, let data = image.jpegData(compressionQuality: 0.85) else { return }
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
        } catch {
            print("[ProfilePhotoStore] Could not save photo")
        }
    }

    static func load() -> UIImage? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return UIImage(data: data)
    }

    static func delete() {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
