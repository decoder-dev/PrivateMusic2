import XCTest
@testable import PrivateMusic

/// Taken from a device log: five `catalog.getSection` requests, of which
/// the two carrying numbered ids came back `vk=104 Not found` while the
/// opaque ones returned content.
final class CatalogSectionIDPolicyTests: XCTestCase {
    func testTheOpaqueIDsVKActuallyServesAreAccepted() {
        for id in [
            "PUldVA8FR0RzSVNUR1UPDykYHRdBXQQINUlFVAwWUVdqSVFUDwVbX3FTWUADA1ob",
            "PUldVA8FR0RzSVNUU1sHCikcABhSax4WIgodE0YWR0R_SVNHGRZTRHxaWU8CDFtQcFxYCw"
        ] {
            XCTAssertTrue(
                CatalogSectionIDPolicy.isSectionID(id),
                "\(id) is a real section id"
            )
        }
    }

    /// The two that failed in the log. They are playlist and album ids that
    /// the shape heuristic mistook for sections.
    func testTheNumberedIDsThatOnlyEverReturnNotFoundAreRejected() {
        XCTAssertFalse(CatalogSectionIDPolicy.isSectionID("456254091"))
        XCTAssertFalse(CatalogSectionIDPolicy.isSectionID("151905456"))
    }

    /// A community-owned object is numbered too, just negatively.
    func testAnOwnerNegatedObjectIDIsRejected() {
        XCTAssertFalse(CatalogSectionIDPolicy.isSectionID("-2000123456"))
    }

    func testBlankIDsAreRejected() {
        XCTAssertFalse(CatalogSectionIDPolicy.isSectionID(""))
        XCTAssertFalse(CatalogSectionIDPolicy.isSectionID("   "))
        XCTAssertFalse(CatalogSectionIDPolicy.isSectionID("-"))
    }

    /// The rule is "not a bare number", not "no digits at all" — section
    /// ids may well contain them.
    func testAnIDThatMerelyContainsDigitsIsStillASection() {
        XCTAssertTrue(CatalogSectionIDPolicy.isSectionID("audios_456"))
        XCTAssertTrue(CatalogSectionIDPolicy.isSectionID("2f8a91"))
    }

    func testSurroundingWhitespaceDoesNotDisguiseANumber() {
        XCTAssertFalse(CatalogSectionIDPolicy.isSectionID("  456254091  "))
    }
}
