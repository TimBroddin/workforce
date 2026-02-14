import SwiftUI

struct AvatarView: View {
    let seed: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
            } else {
                RoundedRectangle(cornerRadius: 6)
                    .fill(.quaternary)
                    .overlay {
                        ProgressView()
                            .scaleEffect(0.5)
                    }
            }
        }
        .frame(width: 32, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .task(id: seed) {
            await loadAvatar()
        }
    }

    private func loadAvatar() async {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Workforce/avatars")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let cached = cacheDir.appendingPathComponent("\(seed).png")

        if let data = try? Data(contentsOf: cached), let img = NSImage(data: data) {
            self.image = img
            return
        }

        guard let url = URL(string: "https://api.dicebear.com/9.x/bottts-neutral/png?seed=\(seed)&size=64") else { return }
        guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
        try? data.write(to: cached)
        if let img = NSImage(data: data) {
            self.image = img
        }
    }
}
