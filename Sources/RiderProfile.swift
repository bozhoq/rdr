import SwiftUI
import PhotosUI
import ImageIO
import Security

enum RiderDestination: Hashable { case statistics }

private struct RiderPublication: Codable {
    let name: String
    let bio: String?
    let totals: RiderTotals
    let avatar: Data?
}

private struct RemoteRider: Decodable, Identifiable {
    let id: String
    let profile: RiderPublication
    let followers: Int
    let following: Bool
}

private struct CommunityState: Decodable {
    let mine: RemoteRider?
    let riders: [RemoteRider]
}

enum RiderCommunity {
    static var endpoint: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "RiderProfileServer") as? String,
              let url = URL(string: value), url.scheme == "https", url.host != nil else { return nil }
        return url
    }

    fileprivate static func request(_ path: String, method: String = "GET", payload: RiderPublication? = nil) async throws -> CommunityState {
        let body = try payload.map { try JSONEncoder().encode($0) }
        let data = try await requestData(path, method: method, body: body)
        return try JSONDecoder().decode(CommunityState.self, from: data)
    }

    private struct RoutePoint: Encodable {
        let latitude: Double
        let longitude: Double
    }

    private struct RouteMatrixRequest: Encodable {
        let origin: RoutePoint
        let destinations: [RoutePoint]
    }

    private struct RouteMatrixResponse: Decodable {
        let seconds: [Double?]
    }

    static func routeDurations(latitude: Double, longitude: Double, to spots: [RiderSpot]) async throws -> [Double?] {
        let query = RouteMatrixRequest(
            origin: RoutePoint(latitude: latitude, longitude: longitude),
            destinations: spots.map { RoutePoint(latitude: $0.latitude, longitude: $0.longitude) }
        )
        let data = try await requestData("route-eta", method: "POST", body: JSONEncoder().encode(query))
        let result = try JSONDecoder().decode(RouteMatrixResponse.self, from: data).seconds
        guard result.count == spots.count else { throw URLError(.cannotParseResponse) }
        return result
    }

    private static func requestData(_ path: String, method: String, body: Data?) async throws -> Data {
        guard let base = endpoint else { throw URLError(.unsupportedURL) }
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "RiderCommunity", kSecAttrAccount as String: base.absoluteString]
        var result: CFTypeRef?
        var lookup = query
        lookup[kSecReturnData as String] = true
        let status = SecItemCopyMatching(lookup as CFDictionary, &result)
        let token: String
        if status == errSecSuccess, let data = result as? Data, let saved = String(data: data, encoding: .utf8) {
            token = saved
        } else {
            guard status == errSecItemNotFound else { throw URLError(.userAuthenticationRequired) }
            token = UUID().uuidString + UUID().uuidString
            var item = query
            item[kSecValueData as String] = Data(token.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw URLError(.userAuthenticationRequired) }
        }
        var req = URLRequest(url: base.appendingPathComponent(path), cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 12)
        req.httpMethod = method
        req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return data
    }
}

struct RiderProfileView: View {
    @ObservedObject var recorder: SessionRecorder
    @AppStorage("rider.profileName") private var name = "Райдер"
    @AppStorage("rider.profileBio") private var bio = ""
    @AppStorage("rider.profilePhoto") private var photo = Data()
    @State private var picked: PhotosPickerItem?
    @State private var editing = false

    var body: some View {
        let totals = RiderTotals(recorder.history)
        ScrollView {
            VStack(spacing: 18) {
                profile(totals)
                NavigationLink(value: RiderDestination.statistics) {
                    shortcut("Личная статистика", subtitle: "Сессии, маршруты и комплекты", icon: "chart.bar.xaxis")
                }
                .buttonStyle(.plain)
                records(totals)
                achievements(totals)
                NavigationLink {
                    RiderCommunityView(totals: totals)
                } label: {
                    shortcut("Райдеры", subtitle: "Публичные профили и подписки", icon: "person.2")
                }
                .buttonStyle(.plain)
            }
            .padding(20)
        }
        .background(RiderTheme.canvas.ignoresSafeArea())
        .navigationTitle("Райдер")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $editing) {
            NavigationStack {
                Form {
                    TextField("Имя", text: $name)
                        .onChange(of: name) { _, value in if value.count > 50 { name = String(value.prefix(50)) } }
                    TextField("О себе", text: $bio, axis: .vertical)
                        .lineLimit(3...5)
                        .onChange(of: bio) { _, value in if value.count > 160 { bio = String(value.prefix(160)) } }
                }
                .navigationTitle("Профиль")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) { Button("Готово") { editing = false } }
                }
            }
        }
        .task(id: picked) {
            guard let picked else { return }
            guard let data = try? await picked.loadTransferable(type: Data.self),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 320
                  ] as CFDictionary), let jpg = UIImage(cgImage: thumb).jpegData(compressionQuality: 0.65),
                  jpg.count <= 96_000, !Task.isCancelled else { return }
            photo = jpg
        }
    }

    private func profile(_ totals: RiderTotals) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 15) {
                PhotosPicker(selection: $picked, matching: .images) {
                    RiderAvatar(photo: photo, size: 68)
                        .overlay { Circle().strokeBorder(RiderTheme.foam.opacity(0.8), lineWidth: 2) }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Выбрать фото райдера")
                VStack(alignment: .leading, spacing: 4) {
                    let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
                    Text(title.isEmpty ? "Райдер" : title).font(.title2.bold())
                    Text("Сессии · \(totals.sessions)").font(.subheadline).foregroundStyle(RiderTheme.foam)
                }
                Spacer(minLength: 0)
                Button { editing = true } label: {
                    Image(systemName: "pencil").font(.headline).padding(10)
                        .background(.white.opacity(0.17), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Изменить профиль")
            }
            if !bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(bio).font(.subheadline).fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(.white)
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RiderTheme.lagoon, in: RoundedRectangle(cornerRadius: 24))
    }

    private func shortcut(_ title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.title3.weight(.semibold)).foregroundStyle(RiderTheme.accent)
                .frame(width: 38, height: 38)
                .background(RiderTheme.canvas, in: RoundedRectangle(cornerRadius: 11))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .lagoonCard()
        .contentShape(Rectangle())
    }

    private func records(_ totals: RiderTotals) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Рекорды").font(.title3.bold()).accessibilityAddTraits(.isHeader)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 140), spacing: 10, alignment: .leading)], spacing: 10) {
                record("Топ прыжок", value: metric(totals.height, unit: "м"), icon: "arrow.up.right")
                record("Топ завис", value: metric(totals.airtime, unit: "с"), icon: "timer")
            }
            HStack(spacing: 12) {
                Image(systemName: "water.waves").font(.title3).foregroundStyle(RiderTheme.accent).accessibilityHidden(true)
                Text("Часы на воде").font(.subheadline.weight(.semibold))
                Spacer(minLength: 6)
                Text(totals.timeOnWater).font(.headline.monospacedDigit()).multilineTextAlignment(.trailing)
            }
            .lagoonCard()
            .accessibilityElement(children: .combine)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func record(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: icon).font(.subheadline.bold()).foregroundStyle(RiderTheme.accent).accessibilityHidden(true)
            Text(value).font(.title2.bold().monospacedDigit())
            Text(title).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
        }
        .lagoonCard()
        .accessibilityElement(children: .combine)
    }

    private func achievements(_ totals: RiderTotals) -> some View {
        let badges = RiderAchievement.milestones(totals)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Ачивки").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                Spacer()
                Text("\(badges.filter(\.unlocked).count) из \(badges.count)")
                    .font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), spacing: 10)], spacing: 10) {
                ForEach(badges) { badge in
                    VStack(alignment: .leading, spacing: 7) {
                        HStack {
                            Image(systemName: badge.icon)
                                .foregroundStyle(badge.unlocked ? RiderTheme.accent : Color.secondary)
                            Spacer()
                            Image(systemName: badge.unlocked ? "checkmark.seal.fill" : "lock")
                                .foregroundStyle(badge.unlocked ? RiderTheme.accent : Color.secondary)
                        }
                        .font(.title3.weight(.semibold))
                        .accessibilityHidden(true)
                        Text(badge.title).font(.subheadline.bold())
                        Text(badge.goal).font(.caption).foregroundStyle(.secondary)
                        ProgressView(value: badge.progress).tint(RiderTheme.accent)
                            .accessibilityLabel(badge.unlocked ? "Получена" : "Прогресс")
                    }
                    .lagoonCard()
                }
            }
        }
    }
}

private struct RiderAvatar: View {
    let photo: Data
    let size: CGFloat

    var body: some View {
        Group {
            if let image = UIImage(data: photo) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "person.crop.circle.fill")
                    .resizable().scaledToFit().foregroundStyle(RiderTheme.accent)
                    .background(RiderTheme.surface)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

private struct RiderCommunityView: View {
    let totals: RiderTotals
    @AppStorage("rider.profileName") private var name = "Райдер"
    @AppStorage("rider.profileBio") private var bio = ""
    @AppStorage("rider.profilePhoto") private var photo = Data()
    @State private var community: CommunityState?
    @State private var busy = false
    @State private var message: String?

    var body: some View {
        List {
            if RiderCommunity.endpoint == nil {
                ContentUnavailableView("Сообщество пока недоступно", systemImage: "person.2",
                                       description: Text("Публичные профили и подписки появятся после подключения сервера Rider."))
            } else {
                Section {
                    if let community {
                        if let me = community.mine {
                            LabeledContent("Подписчики", value: String(me.followers))
                        }
                        Button(community.mine == nil ? "Опубликовать профиль" : "Обновить профиль") {
                            let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
                            let description = bio.trimmingCharacters(in: .whitespacesAndNewlines)
                            perform("me", method: "PUT", payload: RiderPublication(
                                name: title.isEmpty ? "Райдер" : String(title.prefix(50)),
                                bio: description.isEmpty ? nil : String(description.prefix(160)),
                                totals: totals, avatar: photo.isEmpty ? nil : photo
                            ))
                        }
                        if community.mine != nil {
                            Button("Сделать профиль закрытым") { perform("me", method: "DELETE") }
                        }
                    }
                } header: {
                    Text("Мой публичный профиль")
                } footer: {
                    Text("Публикуются имя, фото, описание и суммарные рекорды.")
                }
                Section("Другие райдеры") {
                    if community?.riders.isEmpty == true {
                        Text("Пока никто не опубликовал профиль").foregroundStyle(.secondary)
                    }
                    ForEach(community?.riders ?? []) { rider in
                        DisclosureGroup {
                            if let bio = rider.profile.bio, !bio.isEmpty { Text(bio) }
                            LabeledContent("Топ прыжок", value: metric(rider.profile.totals.height, unit: "м"))
                            LabeledContent("Топ завис", value: metric(rider.profile.totals.airtime, unit: "с"))
                            LabeledContent("Часы на воде", value: rider.profile.totals.timeOnWater)
                            LabeledContent("Подписчики", value: String(rider.followers))
                            Button(rider.following ? "Отписаться" : "Подписаться") {
                                perform("follow/" + rider.id, method: rider.following ? "DELETE" : "PUT")
                            }
                        } label: {
                            HStack(spacing: 9) {
                                RiderAvatar(photo: rider.profile.avatar ?? Data(), size: 34)
                                Text(rider.profile.name).font(.headline)
                            }
                        }
                    }
                }
                Button("Обновить список райдеров") { perform("riders") }
            }
            if busy { ProgressView("Загружаем") }
            if let message { Text(message).foregroundStyle(.secondary) }
        }
        .disabled(busy)
        .navigationTitle("Райдеры")
        .navigationBarTitleDisplayMode(.inline)
        .scrollContentBackground(.hidden).background(RiderTheme.canvas)
        .onAppear { if community == nil && RiderCommunity.endpoint != nil { perform("riders") } }
    }

    private func perform(_ path: String, method: String = "GET", payload: RiderPublication? = nil) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { community = try await RiderCommunity.request(path, method: method, payload: payload); message = nil }
            catch { message = "Нет подтверждения от сервера. Проверьте связь и обновите данные." }
        }
    }
}
