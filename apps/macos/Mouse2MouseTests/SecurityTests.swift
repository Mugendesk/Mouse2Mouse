import XCTest
import CryptoKit
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

    // MARK: - Replay Protection (Encrypt/Decrypt Round-trip)

    /// 2つの一時CryptoManagerをpeerとしてセッション確立し、暗号化/復号できることを確認
    func testEncryptDecryptRoundTrip() {
        // 共有シングルトンに依存するためpeerId/メッセージはユニークに
        let crypto = CryptoManager.shared
        let peerId = "peer-roundtrip-\(UUID().uuidString)"

        // テスト用にpeer公開鍵としてランダム鍵を導出
        let peerPrivate = Curve25519.KeyAgreement.PrivateKey()
        let peerPublicBase64 = peerPrivate.publicKey.rawRepresentation.base64EncodedString()

        XCTAssertTrue(crypto.deriveSessionKey(peerPublicKeyBase64: peerPublicBase64, peerId: peerId))
        XCTAssertTrue(crypto.hasSessionKey(for: peerId))

        let original = "hello replay protection \(UUID().uuidString)"
        guard let wrapped = crypto.wrapMessage(original, for: peerId) else {
            XCTFail("wrap failed")
            return
        }

        guard let decrypted = crypto.unwrapMessage(wrapped, from: peerId) else {
            XCTFail("unwrap failed")
            return
        }
        XCTAssertEqual(decrypted, original)

        crypto.removeSessionKey(for: peerId)
    }

    func testReplayRejectsDuplicateMessage() {
        let crypto = CryptoManager.shared
        let peerId = "peer-replay-\(UUID().uuidString)"

        let peerPrivate = Curve25519.KeyAgreement.PrivateKey()
        let peerPublicBase64 = peerPrivate.publicKey.rawRepresentation.base64EncodedString()
        XCTAssertTrue(crypto.deriveSessionKey(peerPublicKeyBase64: peerPublicBase64, peerId: peerId))

        guard let wrapped = crypto.wrapMessage("first-and-only", for: peerId) else {
            XCTFail("wrap failed")
            return
        }

        // 1回目は復号成功
        XCTAssertNotNil(crypto.unwrapMessage(wrapped, from: peerId))
        // 2回目(=リプレイ)は拒否される
        XCTAssertNil(crypto.unwrapMessage(wrapped, from: peerId),
                     "replay (same seq) must be rejected")

        crypto.removeSessionKey(for: peerId)
    }

    func testReplayRejectsOldTimestamp() {
        let crypto = CryptoManager.shared
        let peerId = "peer-ts-\(UUID().uuidString)"

        let peerPrivate = Curve25519.KeyAgreement.PrivateKey()
        let peerPublicBase64 = peerPrivate.publicKey.rawRepresentation.base64EncodedString()
        XCTAssertTrue(crypto.deriveSessionKey(peerPublicKeyBase64: peerPublicBase64, peerId: peerId))

        // 内部encrypt経由でデータ部を作り、外側ラッパーを古いtimestampで自前構築する
        guard let encryptedPayload = crypto.encrypt("stale", for: peerId) else {
            XCTFail("encrypt failed")
            return
        }
        // ラッパーJSONを手動構築 (timestampを2時間前に)
        let staleJSON = """
        {"type":"encrypted","data":"\(encryptedPayload)","timestamp":\(Date().timeIntervalSince1970 - 7200),"seq":1}
        """

        XCTAssertNil(crypto.unwrapMessage(staleJSON, from: peerId),
                     "messages outside timestamp window must be rejected")

        crypto.removeSessionKey(for: peerId)
    }

    func testReplayStateResetOnSessionRemoval() {
        let crypto = CryptoManager.shared
        let peerId = "peer-reset-\(UUID().uuidString)"

        let peerPrivate = Curve25519.KeyAgreement.PrivateKey()
        let peerPublicBase64 = peerPrivate.publicKey.rawRepresentation.base64EncodedString()
        XCTAssertTrue(crypto.deriveSessionKey(peerPublicKeyBase64: peerPublicBase64, peerId: peerId))

        // 1メッセージ送信してseqを進める
        _ = crypto.wrapMessage("m1", for: peerId)

        // セッション削除→再導出するとseqがリセットされる
        crypto.removeSessionKey(for: peerId)
        XCTAssertTrue(crypto.deriveSessionKey(peerPublicKeyBase64: peerPublicBase64, peerId: peerId))

        // 新しいセッションで送信したメッセージは seq=1 から始まるので受信側もリセット済みのはず
        guard let wrapped = crypto.wrapMessage("m2", for: peerId) else {
            XCTFail("wrap after reset failed")
            return
        }
        XCTAssertNotNil(crypto.unwrapMessage(wrapped, from: peerId),
                        "after session reset, new seq should be accepted")

        crypto.removeSessionKey(for: peerId)
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
