import XCTest
@testable import MrEditorCore

/// `/usr/local/bin/mreditor`（アプリ本体への symlink）から起動されたプロセスでも、バンドル ID を取れること。
///
/// 取れないと、「起動中のアプリがいない」と誤判定し、受け渡し・パイプ・`--wait` が起動中のアプリに届かない
/// （1.32.0 で、`--wait` が「MrEditor が終了しました」で戻った。実体のパスで試すと動くので、見逃した）。
final class BundleIdentifierTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundle-id-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// 偽の `.app`（Info.plist と実行ファイルだけ）を作り、実行ファイルの URL を返す。
    private func makeFakeApp(id: String?, name: String = "Fake.app") throws -> URL {
        let app = root.appendingPathComponent(name, isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleExecutable": "Fake", "CFBundlePackageType": "APPL"]
        if let id { plist["CFBundleIdentifier"] = id }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: app.appendingPathComponent("Contents/Info.plist"))
        let exe = macOS.appendingPathComponent("Fake")
        FileManager.default.createFile(atPath: exe.path, contents: Data("#!/bin/sh\n".utf8),
                                       attributes: [.posixPermissions: 0o755])
        return exe
    }

    func testTheIdentifierIsReadFromTheEnclosingApp() throws {
        let exe = try makeFakeApp(id: "com.example.fake")
        XCTAssertEqual(Intake.bundleIdentifier(forExecutable: exe), "com.example.fake")
    }

    /// 本題。`/usr/local/bin/mreditor` のような symlink 経由でも、本体の `.app` の ID が取れる。
    func testTheIdentifierIsFoundThroughASymlinkOutsideTheBundle() throws {
        let exe = try makeFakeApp(id: "com.example.fake")
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let link = bin.appendingPathComponent("mreditor")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: exe)
        XCTAssertNotNil(EditorWait.appBundle(forExecutable: link), "symlink を解決して、親の .app が見つかる")
        XCTAssertEqual(Intake.bundleIdentifier(forExecutable: link), "com.example.fake")
    }

    func testASymlinkToASymlinkIsResolvedToo() throws {
        let exe = try makeFakeApp(id: "com.example.chain")
        let a = root.appendingPathComponent("a-link")
        let b = root.appendingPathComponent("b-link")
        try FileManager.default.createSymbolicLink(at: a, withDestinationURL: exe)
        try FileManager.default.createSymbolicLink(at: b, withDestinationURL: a)
        XCTAssertEqual(Intake.bundleIdentifier(forExecutable: b), "com.example.chain")
    }

    func testNoIdentifierWhenThereIsNoEnclosingApp() throws {
        let loose = root.appendingPathComponent("loose-tool")
        FileManager.default.createFile(atPath: loose.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        XCTAssertNil(Intake.bundleIdentifier(forExecutable: loose))
        XCTAssertNil(Intake.bundleIdentifier(forExecutable: nil))
    }

    func testNoIdentifierWhenTheAppDeclaresNone() throws {
        let exe = try makeFakeApp(id: nil)
        XCTAssertNil(Intake.bundleIdentifier(forExecutable: exe))
    }

    /// 通知名は、バンドル ID で分かれる（配布版と開発ビルドが混ざらない）。
    /// CLI 側とアプリ側で、**同じ ID から同じ名前**が作られることを確かめる。
    func testNotificationNamesFollowTheIdentifier() {
        let cli = Intake.pipeNotificationName("wait", bundleID: "com.example.fake")
        let app = Intake.pipeNotificationName("wait", bundleID: "com.example.fake")
        XCTAssertEqual(cli, app)
        XCTAssertNotEqual(cli, Intake.pipeNotificationName("wait", bundleID: "com.example.other"))
        XCTAssertNotEqual(cli, Intake.pipeNotificationName("wait", bundleID: nil),
                          "ID が取れないときの素の名前とは、別物（これが 1.32.0 の食い違いの正体）")
    }

    func testTheRunningProcessHasAnExecutablePath() {
        XCTAssertNotNil(Intake.currentExecutableURL())
    }
}
