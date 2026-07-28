import Foundation

struct UserProfile: Codable, Equatable, Sendable {
    let id: Int
    let firstName: String
    let lastName: String
    let photoURL: URL?

    var displayName: String {
        "\(firstName) \(lastName)".trimmingCharacters(in: .whitespaces)
    }

    enum CodingKeys: String, CodingKey {
        case id
        case firstName = "first_name"
        case lastName = "last_name"
        case photo200 = "photo_200"
    }

    init(
        id: Int,
        firstName: String,
        lastName: String,
        photoURL: URL?
    ) {
        self.id = id
        self.firstName = firstName
        self.lastName = lastName
        self.photoURL = photoURL
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(Int.self, forKey: .id)
        firstName = try container.decode(String.self, forKey: .firstName)
        lastName = try container.decode(String.self, forKey: .lastName)
        let photo = try container.decodeIfPresent(
            String.self,
            forKey: .photo200
        )
        photoURL = photo.flatMap { $0.isEmpty ? nil : URL(string: $0) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(firstName, forKey: .firstName)
        try container.encode(lastName, forKey: .lastName)
        try container.encodeIfPresent(photoURL?.absoluteString, forKey: .photo200)
    }
}
