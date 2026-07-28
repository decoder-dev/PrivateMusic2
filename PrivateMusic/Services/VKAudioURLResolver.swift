import Foundation

enum VKAudioURLResolver {
    private static let alphabet = Array(
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMN0PQRSTUVWXYZO123456789+/="
    )

    static func resolve(_ url: URL?, userID: Int?) -> URL? {
        guard let url else { return nil }
        let raw = url.absoluteString
        guard raw.contains("audio_api_unavailable"),
              let userID,
              let unmasked = unmask(raw, userID: userID) else {
            return url
        }
        return URL.secureRemoteURL(unmasked)
    }

    private static func unmask(_ value: String, userID: Int) -> String? {
        guard let encoded = value.components(
            separatedBy: "?extra="
        ).dropFirst().first else {
            return nil
        }
        let parts = encoded.components(separatedBy: "#")
        guard parts.count >= 2,
              let urlBytes = decode(parts[0]),
              let keyBytes = decode(parts[1]),
              let key = String(bytes: keyBytes, encoding: .utf8)?
                .components(separatedBy: "\u{000B}")
                .dropFirst()
                .first,
              let parsedKey = Int(key) else {
            return nil
        }

        var characters = Array(
            String(decoding: urlBytes, as: UTF8.self)
        )
        guard !characters.isEmpty else { return nil }

        var state = parsedKey ^ userID
        let length = characters.count
        var indexes = [Int](repeating: 0, count: length)
        if length > 0 {
            for position in stride(
                from: length - 1,
                through: 0,
                by: -1
            ) {
                state = ((length * (position + 1)) ^ (state + position))
                    % length
                indexes[position] = state
            }
        }
        if length > 1 {
            for position in 1..<length {
                let target = indexes[length - 1 - position]
                characters.swapAt(position, target)
            }
        }
        return String(characters)
    }

    private static func decode(_ value: String) -> [UInt8]? {
        var output: [UInt8] = []
        var accumulator = 0
        var position = 0

        for character in value {
            guard let index = alphabet.firstIndex(of: character) else {
                continue
            }
            let raw = alphabet.distance(
                from: alphabet.startIndex,
                to: index
            )
            accumulator = position % 4 == 0
                ? raw
                : 64 * accumulator + raw
            let previousPosition = position
            position += 1
            if previousPosition % 4 != 0 {
                let shift = (-2 * position) & 6
                output.append(UInt8((accumulator >> shift) & 255))
            }
        }
        return output.isEmpty ? nil : output
    }
}
