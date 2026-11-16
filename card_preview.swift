import AppKit
import Foundation
import SwiftUI

@main enum CardPreview {
    @MainActor static func main() throws {
        _ = NSApplication.shared
        // Synthetic preview only. No user's session or location is uploaded.
        var session = SessionSummary(startedAt: Date(timeIntervalSince1970: 1794823200), gpsEnabledAtStart: true, batteryAtStartPercent: nil)
        session.setup = SessionSetup(sport: .groundTest)
        session.durationSeconds = 901
        session.distanceMeters = 970
        session.maxSpeedMetersPerSecond = 4
        let event = JumpCandidate(startSeconds: 100, endSeconds: 100.5, minimumLoadG: 0.1, returnPeakG: 3, maximumRotationRadiansPerSecond: 1)
        session.jumpAnalysis = JumpAnalysis(candidates: [event])
        session.review = SessionReview()
        session.review?.setLabel(.bodyJump, for: event, version: JumpDetector.version)
        let renderer = ImageRenderer(content: SessionCardView(data: SessionCardData(session: session)))
        renderer.scale = 3
        renderer.isOpaque = true
        guard let cg = renderer.cgImage, cg.width == 1080, cg.height == 1440,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            fatalError("Unable to render card at 1080x1440")
        }
        try png.write(to: URL(fileURLWithPath: "build/Rider-card-preview.png"), options: .atomic)
        print("PASS: native SwiftUI card rendered at 1080 x 1440")
    }
}
