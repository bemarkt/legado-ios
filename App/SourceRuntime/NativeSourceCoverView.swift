import SwiftUI
import UIKit

struct NativeSourceCoverView: View {
    @ObservedObject var model: NativeSourceLibrary
    let installation: SourceInstallation
    let scope: SourceScope
    let cover: SourceWire.Cover?
    var expectedIdentity: SourceExecutionIdentity? = nil
    var width: CGFloat = 46
    @State private var image: UIImage?
    private var requestID: String { model.coverRevision.uuidString + ":" + installation.digest + ":" + scope.accountID + ":" + (cover?.url ?? "") }
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6).fill(.quaternary)
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "book.closed").font(.title3).foregroundStyle(.secondary) }
        }
        .frame(width: width, height: width * 1.4)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .accessibilityHidden(true)
        .task(id: requestID) {
            image = nil
            guard let cover else { return }
            do {
                let data = try await model.cover(cover, installation: installation, scope: scope, expectedIdentity: expectedIdentity)
                try Task.checkCancellation()
                image = UIImage(data: data)
            } catch { if !Task.isCancelled { image = nil } }
        }
    }
}
