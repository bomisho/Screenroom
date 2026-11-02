import RealityKit
import SwiftUI

/// A first, minimal theater mode: an empty mixed immersive space whose only job is to
/// dim the real room around the video window. Full theater environments come later.
struct DimmedRoom: View {
    var body: some View {
        RealityView { _ in }
            .preferredSurroundingsEffect(.systemDark)
    }
}
