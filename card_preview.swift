import Foundation
import CoreGraphics

@main enum CardPreview {
    static func main() throws {
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
        guard let cg = CardArtwork.render(SessionCardData(session: session)), cg.width == 1080, cg.height == 1440,
              let png = CardArtwork.png(cg) else {
            fatalError("Unable to render card at 1080x1440")
        }
        try png.write(to: URL(fileURLWithPath: "build/Rider-card-preview.png"), options: .atomic)
        print("PASS: native Core Graphics card rendered at 1080 x 1440")
    }
}
