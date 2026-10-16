import Foundation
import XCTest

final class LocalMediaLibraryTests: XCTestCase {
    private var temporaryRoot: URL!

    override func setUpWithError() throws {
        temporaryRoot = FileManager.default.temporaryDirectory
            .appending(path: "MushRadioTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryRoot)
    }

    func testImportCommitsOnlyAfterInspectionAndSurvivesRelaunch() async throws {
        let source = temporaryRoot.appending(path: "sample.mov")
        try Data("movie bytes".utf8).write(to: source)
        let ownedRoot = temporaryRoot.appending(path: "Library", directoryHint: .isDirectory)
        let library = LocalMediaLibrary(root: ownedRoot) { stagedURL in
            XCTAssertTrue(FileManager.default.fileExists(atPath: stagedURL.path))
            XCTAssertTrue(stagedURL.path.contains(".partial-"))
            return LocalMediaInspection(
                title: "Sample",
                duration: 42,
                pixelWidth: 1_920,
                pixelHeight: 1_080,
                posterJPEGData: Data([1, 2, 3])
            )
        }

        let imported = try await library.importVideo(from: source)
        let playbackURL = await library.playbackURL(
            mediaID: imported.mediaID,
            filename: imported.filename
        )
        XCTAssertNotNil(playbackURL)
        XCTAssertEqual(imported.title, "Sample")

        let relaunched = LocalMediaLibrary(root: ownedRoot)
        let isAvailableAfterRelaunch = await relaunched.contains(
            mediaID: imported.mediaID,
            filename: imported.filename
        )
        XCTAssertTrue(isAvailableAfterRelaunch)
        let staging = ownedRoot.appending(path: "Staging", directoryHint: .isDirectory)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    func testInvalidImportRemovesPartialAndDoesNotCreateMediaDirectory() async throws {
        let source = temporaryRoot.appending(path: "corrupt.mov")
        try Data("not a movie".utf8).write(to: source)
        let ownedRoot = temporaryRoot.appending(path: "Library", directoryHint: .isDirectory)
        let library = LocalMediaLibrary(root: ownedRoot) { _ in
            throw LocalMediaLibraryError.invalidMovie
        }

        do {
            _ = try await library.importVideo(from: source)
            XCTFail("Expected invalid movie")
        } catch {
            XCTAssertEqual(error as? LocalMediaLibraryError, .invalidMovie)
        }

        let media = ownedRoot.appending(path: "Media", directoryHint: .isDirectory)
        let staging = ownedRoot.appending(path: "Staging", directoryHint: .isDirectory)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: media.path).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
    }

    func testSymbolicLinkImportIsRejectedInsteadOfRetainingExternalDependency() async throws {
        let target = temporaryRoot.appending(path: "target.mov")
        let link = temporaryRoot.appending(path: "linked.mov")
        try Data("movie bytes".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let ownedRoot = temporaryRoot.appending(path: "Library", directoryHint: .isDirectory)
        let library = LocalMediaLibrary(root: ownedRoot) { _ in
            throw LocalMediaLibraryError.invalidMovie
        }

        do {
            _ = try await library.importVideo(from: link)
            XCTFail("Expected symbolic link rejection")
        } catch {
            XCTAssertEqual(error as? LocalMediaLibraryError, .symbolicLink)
        }

        let media = ownedRoot.appending(path: "Media", directoryHint: .isDirectory)
        let staging = ownedRoot.appending(path: "Staging", directoryHint: .isDirectory)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: media.path).isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: staging.path).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testTrashRestoreOrphanAndPartialCleanupStayInsideOwnedRoot() async throws {
        let source = temporaryRoot.appending(path: "sample.mov")
        try Data("movie".utf8).write(to: source)
        let ownedRoot = temporaryRoot.appending(path: "Library", directoryHint: .isDirectory)
        let library = LocalMediaLibrary(root: ownedRoot) { _ in
            LocalMediaInspection(
                title: "Sample",
                duration: 1,
                pixelWidth: 10,
                pixelHeight: 10,
                posterJPEGData: nil
            )
        }
        let imported = try await library.importVideo(from: source)
        let importedPlaybackURL = await library.playbackURL(
            mediaID: imported.mediaID,
            filename: imported.filename
        )
        let playbackURL = try XCTUnwrap(importedPlaybackURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date.distantPast],
            ofItemAtPath: playbackURL.deletingLastPathComponent().path
        )
        let movedToTrash = try await library.moveToTrash(mediaID: imported.mediaID)
        let trashed = try XCTUnwrap(movedToTrash)
        try await library.cleanTrash(olderThan: Date().addingTimeInterval(-60))
        let isAvailableInTrash = await library.contains(
            mediaID: imported.mediaID,
            filename: imported.filename
        )
        XCTAssertFalse(isAvailableInTrash)
        let didRestore = try await library.restoreFromTrash(trashed)
        XCTAssertTrue(didRestore)
        let isAvailableAfterRestore = await library.contains(
            mediaID: imported.mediaID,
            filename: imported.filename
        )
        XCTAssertTrue(isAvailableAfterRestore)

        try await library.reconcile(referencedMediaIDs: [])
        let isAvailableAfterReconcile = await library.contains(
            mediaID: imported.mediaID,
            filename: imported.filename
        )
        XCTAssertFalse(isAvailableAfterReconcile)

        let partial = ownedRoot
            .appending(path: "Staging", directoryHint: .isDirectory)
            .appending(path: ".partial-stale", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.modificationDate: Date.distantPast],
            ofItemAtPath: partial.path
        )
        try await library.cleanStalePartials(olderThan: Date())
        XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: temporaryRoot.path))
    }
}
