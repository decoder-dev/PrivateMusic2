import XCTest
@testable import PrivateMusic

final class MixTuningTests: XCTestCase {
    private func json(_ text: String) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    }

    func testMoodTilesOfOneStreamMixStayDistinct() throws {
        let payload = try json("""
        {"blocks":[{"audio_stream_mixes":[
          {"mix_id":"common","title":"Грустное","options":{"mood":"sad"}},
          {"mix_id":"common","title":"Бодрое","options":{"mood":"energetic"}},
          {"mix_id":"common","title":"Мой микс"}
        ]}]}
        """)
        let mixes = payload.musicMixes
        XCTAssertEqual(mixes.count, 3)
        XCTAssertEqual(Set(mixes.map(\.id)).count, 3)
        XCTAssertTrue(mixes.allSatisfy { $0.streamMixID == "common" })
        let sad = try XCTUnwrap(mixes.first { $0.title == "Грустное" })
        XCTAssertEqual(sad.streamOptions, #"{"mood":"sad"}"#)
        XCTAssertEqual(sad.untuned.id, "common")
        XCTAssertNil(sad.untuned.streamOptions)
    }

    func testSettingsParseCategoriesAndSelection() throws {
        let payload = try json("""
        {"mix_categories":[
          {"type":"mood","title":"Настроение","multi_select":false,
           "options":[{"id":"sad","title":"Грустное","selected":1},
                      {"id":"calm","title":"Спокойное"}]},
          {"type":"genre","title":"Жанры","multi_select":true,
           "options":[{"id":"rock","title":"Рок"},{"id":"pop","title":"Поп"}]}
        ]}
        """)
        let tuning = payload.mixTuning
        XCTAssertEqual(tuning.categories.map(\.id), ["mood", "genre"])
        XCTAssertEqual(tuning.categories[1].allowsMultiple, true)
        XCTAssertEqual(tuning.initialSelection, ["mood": ["sad"]])
        XCTAssertFalse(tuning.isEmpty)
    }

    func testUnknownShapeIsEmptyNotACrash() throws {
        XCTAssertTrue(try json(#"{"unexpected":[1,2]}"#).mixTuning.isEmpty)
    }

    func testSelectionBecomesMixOptionsAndBack() throws {
        let tuning = MixTuning(categories: [])
        let tuned = tuning.mix(
            applying: ["mood": ["calm"], "genre": ["pop", "rock"]],
            to: .common
        )
        XCTAssertEqual(tuned.streamMixID, "common")
        XCTAssertEqual(
            tuned.streamOptions,
            #"{"genre":["pop","rock"],"mood":["calm"]}"#
        )
        XCTAssertEqual(tuning.mix(applying: [:], to: tuned).id, "common")
    }
}
