import RunloopCore
import SwiftUI
import UIKit

struct GPXShareButton: View {
    let name: String
    let points: [GPXPoint]
    var creditsOpenStreetMap = false
    @State private var item: Export?
    @State private var temporaryDirectory: URL?
    @State private var failed = false

    private struct Export: Identifiable {
        let url: URL
        var id: URL { url }
    }

    var body: some View {
        Button("Esporta GPX", systemImage: "square.and.arrow.up", action: share)
            .disabled(points.isEmpty)
            .sheet(item: $item, onDismiss: cleanUp) { ActivitySheet(url: $0.url) }
            .alert("Impossibile creare il GPX", isPresented: $failed) {
                Button("OK", role: .cancel) {}
            }
    }

    private func share() {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        temporaryDirectory = directory
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let mapped = String(name.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
            let safeName = String(decoding: mapped.utf8.prefix(180), as: UTF8.self)
                .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
            let url = directory.appending(path: (safeName.isEmpty ? "Runloop" : safeName) + ".gpx")
            try GPX.data(name: name, points: points, creditsOpenStreetMap: creditsOpenStreetMap)
                .write(to: url, options: [.atomic, .completeFileProtection])
            item = Export(url: url)
        } catch {
            cleanUp()
            failed = true
        }
    }

    private func cleanUp() {
        if let temporaryDirectory { try? FileManager.default.removeItem(at: temporaryDirectory) }
        temporaryDirectory = nil
    }
}

private struct ActivitySheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
