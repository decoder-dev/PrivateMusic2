import Foundation

enum VKAudioURLResolver {
    static func resolve(_ url: URL?, userID: Int?) -> URL? {
        guard let url else { return nil }
        let raw = url.absoluteString
        return raw.utf8.withContiguousStorageIfAvailable { buffer -> URL? in
            unmask(bytes: buffer, userID: userID, original: url)
        } ?? {
            let bytes = Array(raw.utf8)
            return bytes.withUnsafeBufferPointer { buffer in
                unmask(bytes: buffer, userID: userID, original: url)
            }
        }()
    }

    private static func unmask(
        bytes: UnsafeBufferPointer<UInt8>,
        userID: Int?,
        original: URL
    ) -> URL? {
        guard let base = bytes.baseAddress else { return original }
        var output = [UInt8](repeating: 0, count: max(bytes.count, 16))
        let written = output.withUnsafeMutableBufferPointer { buffer in
            pm_vk_unmask(
                base,
                Int32(bytes.count),
                Int32(clamping: userID ?? 0),
                buffer.baseAddress,
                Int32(buffer.count)
            )
        }
        if written == PM_VK_UNMASK_NOT_MASKED {
            return original
        }
        guard written > 0, userID != nil else { return nil }
        let unmasked = String(
            decoding: output.prefix(Int(written)),
            as: UTF8.self
        )
        return URL.secureRemoteURL(unmasked)
    }
}
