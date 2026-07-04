import XCTest
@testable import Mouse2Mouse

/// セキュリティ強化(リプレイ防止/Fingerprint/Keychain)の単体テスト
final class SecurityTests: XCTestCase {

    // MARK: - Fingerprint Generation

    func testFingerprintFormat() {
        let key = Data(repeating: 0xAB, count: 32)
        let fp = PairingManager.fingerprint(of: key)

        // 形式: XXXX:XXXX:XXXX:XXXX:XXXX:XXXX:XXXX:XXXX (4文字×8グループ、コロン7個)
        XCTAssertEqual(fp.count, 39, "fingerprint should be 32 hex chars + 7 colons")
        let groups = fp.split(separator: ":")
        XCTAssertEqual(groups.count, 8)
        for g in groups {
            XCTAssertEqual(g.count, 4)
            XCTAssertTrue(g.allSatisfy { $0.isHexDigit }, "non-hex char in \(g)")
        }
    }

    func testFingerprintDeterministic() {
        let key = Data((0..<32).map { UInt8($0) })
        let a = PairingManager.fingerprint(of: key)
        let b = PairingManager.fingerprint(of: key)
        XCTAssertEqual(a, b, "same input must produce same fingerprint")
    }

    func testFingerprintChangesWithKey() {
        let k1 = Data(repeating: 0x01, count: 32)
        let k2 = Data(repeating: 0x02, count: 32)
        XCTAssertNotEqual(PairingManager.fingerprint(of: k1),
                          PairingManager.fingerprint(of: k2))
    }

    // MARK: - Key Change Detection

    func testCheckKeyUnknownForUnpairedDevice() {
        let result = PairingManager.shared.checkKey(
            deviceId: "non-existent-device-id-\(UUID().uuidString)",
            incomingPublicKey: Data(repeating: 0xFF, count: 32)
        )
        XCTAssertEqual(result, .unknown)
    }

    func testCheckKeyMatchVsMismatch() {
        let mgr = PairingManager.shared
        let deviceId = "test-device-\(UUID().uuidString)"
        let originalKey = Data(repeating: 0x42, count: 32)
        let differentKey = Data(repeating: 0x43, count: 32)

        mgr.recordTrust(deviceId: deviceId, hostname: "test-host", publicKey: originalKey)
        // recordTrust uses DispatchQueue.main.async; wait for it
        let waitExp = expectation(description: "trust recorded")
        DispatchQueue.main.async { waitExp.fulfill() }
        wait(for: [waitExp], timeout: 1.0)

        XCTAssertEqual(mgr.checkKey(deviceId: deviceId, incomingPublicKey: originalKey), .match)
        XCTAssertEqual(mgr.checkKey(deviceId: deviceId, incomingPublicKey: differentKey), .mismatch)

        // cleanup
        mgr.unpair(deviceId: deviceId)
    }

    // MARK: - SecureChannel (Noise) Round-trip & fail-open elimination

    /// 2つの SecureChannel をループバック接続し、ハンドシェイクが完了して
    /// アプリメッセージが暗号化往復できることを確認する。
    func testSecureChannelHandshakeAndRoundTrip() {
        var a: SecureChannel!
        var b: SecureChannel!

        // sendFrame は envelope テキスト。相手の receiveFrame(frame Data) に渡す。
        a = SecureChannel.initiator(sendFrame: { env in
            if let frame = SecureChannel.decodeEnvelope(env) { b.receiveFrame(frame) }
        })
        b = SecureChannel.responder(sendFrame: { env in
            if let frame = SecureChannel.decodeEnvelope(env) { a.receiveFrame(frame) }
        })

        let bEstablished = expectation(description: "b established")
        b.onEstablished = { _, _, _, _ in bEstablished.fulfill() }

        let gotMessage = expectation(description: "message delivered to b")
        let payload = "{\"type\":\"clipboard\",\"nonce\":\"\(UUID().uuidString)\"}"
        b.onMessage = { msg in
            XCTAssertEqual(msg, payload)
            gotMessage.fulfill()
        }

        a.start()  // 同期的にハンドシェイクが往復して確立する
        wait(for: [bEstablished], timeout: 2.0)
        XCTAssertTrue(a.isEstablished && b.isEstablished, "both sides must establish")

        XCTAssertTrue(a.sendApp(payload), "sendApp should succeed after establish")
        wait(for: [gotMessage], timeout: 2.0)
    }

    /// fail-open 排除: ハンドシェイク完了前に app-data フレームを注入しても、
    /// 平文が `onMessage` として上がってこないこと (旧実装の平文フォールバックが構造的に不可能)。
    func testSecureChannelDropsAppDataBeforeHandshake() {
        var delivered = false
        let b = SecureChannel.responder(sendFrame: { _ in })
        b.onMessage = { _ in delivered = true }

        // tag=0x02 (AppData) の生フレームを確立前に注入。
        let injected = Data([0x02]) + Data("pretend-this-is-plaintext".utf8)
        b.receiveFrame(injected)

        XCTAssertFalse(delivered, "app-data before handshake must never surface as plaintext")
        XCTAssertFalse(b.isEstablished, "channel must not establish from an app-data frame")
    }

    /// noise envelope の判定 (raw テキスト → frame) が往復すること。
    func testEnvelopeEncodeDecodeRoundTrip() {
        let frame = Data([0x01, 0xAA, 0xBB, 0xCC])
        let env = SecureChannel.encodeEnvelope(frame)
        XCTAssertEqual(SecureChannel.decodeEnvelope(env), frame)
        // 非 noise テキストは nil
        XCTAssertNil(SecureChannel.decodeEnvelope("{\"type\":\"cursor_move\",\"x\":1,\"y\":2}"))
    }

    // MARK: - Keychain Round-trip

    func testKeychainItemRoundTrip() {
        // privateKey スロットは実機の鍵を上書きする可能性があるため、
        // 既存値を保存して復元する
        let original = KeychainItem.privateKey.load()
        defer {
            if let original = original {
                _ = KeychainItem.privateKey.save(original)
            }
        }

        let testData = Data("test-payload-\(UUID().uuidString)".utf8)
        XCTAssertTrue(KeychainItem.privateKey.save(testData))
        XCTAssertEqual(KeychainItem.privateKey.load(), testData)
        XCTAssertTrue(KeychainItem.privateKey.delete())
        XCTAssertNil(KeychainItem.privateKey.load())
    }
}
