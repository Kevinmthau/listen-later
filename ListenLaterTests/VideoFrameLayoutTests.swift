import CoreGraphics
import XCTest
@testable import ListenLater

final class VideoFrameLayoutTests: XCTestCase {
    func testLandscapeVideoUsesTheFullWidth() {
        let height = VideoFrameLayout.height(
            forWidth: 320,
            aspectRatio: 16.0 / 9.0,
            maxHeight: 360,
            minHeight: 0
        )
        XCTAssertEqual(height, 180, accuracy: 0.01)
    }

    func testPortraitVideoIsCappedInsteadOfPillarboxedToFullHeight() {
        let height = VideoFrameLayout.height(
            forWidth: 320,
            aspectRatio: 9.0 / 16.0,
            maxHeight: 360,
            minHeight: 0
        )
        XCTAssertEqual(height, 360)
    }

    func testYouTubeNeverDropsBelowItsMinimumHeight() {
        let height = VideoFrameLayout.height(
            forWidth: 300,
            aspectRatio: 16.0 / 9.0,
            maxHeight: 200,
            minHeight: 200
        )
        XCTAssertEqual(height, 200)
    }

    func testUnknownShapeFallsBackToTheMaximumHeight() {
        XCTAssertEqual(
            VideoFrameLayout.height(forWidth: 320, aspectRatio: 0, maxHeight: 360, minHeight: 0),
            360
        )
        XCTAssertEqual(
            VideoFrameLayout.height(forWidth: .infinity, aspectRatio: 1, maxHeight: 112, minHeight: 0),
            112
        )
    }
}
