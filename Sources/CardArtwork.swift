import Foundation
import SwiftUI

struct SessionCardView: View {
    let data: SessionCardData
    private let foam = Color(red: 0.82, green: 1, blue: 0.95)
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(alignment: .firstTextBaseline) {
                Text("RDR").font(.system(size: 38, weight: .black, design: .rounded))
                Spacer()
                Text("Rider").font(.system(size: 20, weight: .semibold))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(data.sport).font(.system(size: 25, weight: .bold)).lineLimit(2)
                Text(data.date, format: .dateTime.day().month(.wide).year()).font(.system(size: 15)).foregroundStyle(foam)
            }
            Text(cardDuration(data.duration)).font(.system(size: 43, weight: .bold, design: .monospaced)).minimumScaleFactor(0.7).lineLimit(1)
            HStack(alignment: .top, spacing: 20) {
                cardMetric("Дистанция GPS", cardNumber(data.distanceMeters.map { $0 / 1000 }, unit: "км", digits: 2))
                cardMetric("Максимум GPS", cardNumber(data.speedMetersPerSecond.map { $0 * 3.6 }, unit: "км/ч"))
            }
            Rectangle().fill(foam.opacity(0.3)).frame(height: 1)
            Text("Прыжков отмечено мной: \(data.markedJumps)").font(.system(size: 17, weight: .semibold))
            Text("Событий детектора: \(data.candidateCount)").font(.system(size: 15)).foregroundStyle(foam)
            Spacer(minLength: 0)
            Text("GPS приблизительный · детектор экспериментальный\nВысота и время полёта не измерены")
                .font(.system(size: 11)).foregroundStyle(foam).fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(width: 360, height: 480, alignment: .topLeading)
        .foregroundStyle(.white)
        .background(LinearGradient(colors: [Color(red: 0.01, green: 0.32, blue: 0.43), Color(red: 0, green: 0.48, blue: 0.44)], startPoint: .topLeading, endPoint: .bottomTrailing))
        .environment(\.locale, Locale(identifier: "ru_RU"))
        .environment(\.colorScheme, .light)
        .environment(\.dynamicTypeSize, .medium)
    }

    private func cardMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundStyle(foam)
            Text(value).font(.system(size: 21, weight: .bold)).lineLimit(1).minimumScaleFactor(0.65)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

private func cardDuration(_ seconds: Double) -> String {
    let total = Int(max(0, seconds))
    return String(format: "%02d:%02d:%02d", total / 3600, total / 60 % 60, total % 60)
}

private func cardNumber(_ value: Double?, unit: String, digits: Int = 1) -> String {
    guard let value, value.isFinite else { return "—" }
    return value.formatted(.number.locale(Locale(identifier: "ru_RU")).precision(.fractionLength(digits))) + " " + unit
}
