import Foundation
import XCTest
@testable import ListenLater

final class PlaybackPreferencesTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "PlaybackPreferencesTests"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testClipsPlayContinuouslyByDefault() {
        XCTAssertTrue(PlaybackPreferences.clipsPlayContinuously(in: defaults))
    }

    func testTurningContinuousPlayOffIsHonoured() {
        defaults.set(false, forKey: PlaybackPreferences.clipsPlayContinuouslyKey)

        XCTAssertFalse(PlaybackPreferences.clipsPlayContinuously(in: defaults))
    }

    func testMigrationCarriesAnOldChoiceToSaveVideosForTheScreen() {
        defaults.set(true, forKey: PlaybackPreferences.legacyVideosWaitForScreenKey)

        PlaybackPreferences.migrate(in: defaults)

        XCTAssertEqual(
            defaults.object(forKey: PlaybackPreferences.clipsPlayContinuouslyKey) as? Bool,
            false
        )
        XCTAssertFalse(PlaybackPreferences.clipsPlayContinuously(in: defaults))
    }

    func testMigrationCarriesAnOldChoiceToPlayVideosWhileLocked() {
        defaults.set(false, forKey: PlaybackPreferences.legacyVideosWaitForScreenKey)

        PlaybackPreferences.migrate(in: defaults)

        XCTAssertEqual(
            defaults.object(forKey: PlaybackPreferences.clipsPlayContinuouslyKey) as? Bool,
            true
        )
        XCTAssertTrue(PlaybackPreferences.clipsPlayContinuously(in: defaults))
    }

    func testMigrationKeepsTheOldKeyForEarlierBuilds() {
        defaults.set(true, forKey: PlaybackPreferences.legacyVideosWaitForScreenKey)

        PlaybackPreferences.migrate(in: defaults)

        XCTAssertEqual(
            defaults.object(forKey: PlaybackPreferences.legacyVideosWaitForScreenKey) as? Bool,
            true
        )
    }

    func testMigrationLeavesACurrentChoiceAlone() {
        defaults.set(true, forKey: PlaybackPreferences.clipsPlayContinuouslyKey)
        defaults.set(true, forKey: PlaybackPreferences.legacyVideosWaitForScreenKey)

        PlaybackPreferences.migrate(in: defaults)

        XCTAssertTrue(PlaybackPreferences.clipsPlayContinuously(in: defaults))
    }

    func testMigrationWithoutAnOldChoiceStoresNothing() {
        PlaybackPreferences.migrate(in: defaults)

        XCTAssertNil(defaults.object(forKey: PlaybackPreferences.clipsPlayContinuouslyKey))
        XCTAssertTrue(PlaybackPreferences.clipsPlayContinuously(in: defaults))
    }
}
