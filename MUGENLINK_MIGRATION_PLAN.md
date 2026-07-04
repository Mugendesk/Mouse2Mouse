# mugenlink 移行計画 (2026-07-02)

正典: [`Mugendesk/docs/LAN_Auth_Pattern.md`](../docs/LAN_Auth_Pattern.md) (v2.1) §9。
詳細監査: [`SECURITY_AUDIT.md`](./SECURITY_AUDIT.md)。ここでは重複を避け要点のみ引用する。

## 現状の脆弱性 (要約)

`SECURITY_AUDIT.md` の結論: 暗号レイヤ自体 (X25519 + ChaCha20-Poly1305 + HKDF + replay対策、`apps/macos/Core/CryptoManager.swift`) は実装済みだが、**「平文を拒否しない」「入力イベントを認可しない」の2点で実質無効化**されている。

- 🔴 受信側が復号失敗/未暗号化メッセージを **平文のままフォールバック処理** (`DiscoveryService.swift:386-393`, `WebSocketClient.swift:384-389`)
- 🔴 `cursorMove/key/clipboard` 等の入力イベントに **ペアリング済みチェックが一切ない** (`DiscoveryService.swift:496-501`)
- 🔴 UDP カーソルチャネル (`UDPCursorChannel.swift`) が **無認証・無暗号・送信元検証なし**
- 🟠 鍵交換 (`deviceInfo` ハンドシェイク) が平文交換 + TOFU のみで **MITM に弱い**、SAS (fingerprint 目視照合) 無し
- 🟠 6桁コードペアリング (`PairingManager.verifyPairingCode`) が **デッドコード**

正典 §9 の監査結果 (「入力イベントが平文+認証なし、HMAC不在」) と実態は整合している。ただし `SECURITY_AUDIT.md` の方がより正確: 暗号プリミティブ自体は正しく実装済みで、**ゲート漏れ (fail-open) が根本原因**。「暗号が壊れている」のではなく「暗号を経由しなくても動いてしまう」バグに近い。

## mugenlink で使えるもの

`/Users/toro/myapp/mugenlink` (Rust, uniffi公開済み) に以下が実装済み・テスト17件通過:

- **Identity**: static鍵生成 + 永続化 (`to_bytes`/`from_bytes`, 64byte, Keychain保存想定)
- **NoiseSession**: `Noise_XX_25519_ChaChaPoly_SHA256`。bootstrap_psk を束ねた **XXpsk0** 対応 (psk不一致はハンドシェイク自体が失敗 = MITM耐性が暗号学的に保証される。SECURITY_AUDIT #5 の SAS 目視照合と違い、実装ミスで抜け道が生まれない)。`write_handshake`/`read_handshake`/`is_finished`/`encrypt`/`decrypt`/`remote_fp`/`remote_static_key`
- **Roster + OwnerKey**: 署名付きroster、epoch、失効 (複数Mac構成 = Device Group にそのまま使える。今の `pairedDevices` UserDefaults 相当を roster に置き換え可能)
- Swift向け: iOS実機+シミュレータ、**macOS (arm64+x86_64 Universal)** のXCFrameworkをビルド済み。ローカルSwift Package (`mugenlink/swift/Package.swift`) が既にある。MagicDeckの `MagicDeck` (macOS) / `MagicDeckiOS` にリンク・ビルド確認済みなので、**Mouse2Mouse (macOS) も同じ Package をそのままリンクできる** (プラットフォーム的に新規ビルドは不要、xcframeworkは既存のものを使い回せる)。

## Mouse2Mouse 固有の移行ステップ

Mouse2Mouseは **Rust/uniffi 未導入**。MagicDeckで踏んだ手順をそのまま再利用する:

1. `Mouse2Mouse.xcodeproj` の該当ターゲット (macOS) に、`mugenlink/swift` をローカル Swift Package として追加 (MagicDeckでやった `xcodeproj` gem 経由のスクリプトが流用できる。手動なら Xcode の "Add Local Package")。
2. **`CryptoManager.swift` を `Mugenlink.NoiseSession` に置き換え**:
   - `deriveSessionKey(peerPublicKey:peerId:)` → `NoiseSession.newInitiator/newResponder` によるハンドシェイク確立に置き換え
   - `wrapMessage`/`unwrapMessage` (今の自前 `EncryptedMessage` JSON) → `session.encrypt`/`session.decrypt` に置き換え
   - 手動 replay対策 (`resetReplayState`) は Noise の内部 nonce に置き換わるため **削除可能**
3. **fail-open バグの根絶** (`SECURITY_AUDIT.md` 修正優先順位 #1, #2 と同じ勘所だが、Noiseに置き換えれば構造的に解消する): `DiscoveryService.swift` / `WebSocketClient.swift` の「平文フォールバック」分岐そのものを削除し、`session.decrypt` 失敗 = メッセージ破棄一択にする。`isPaired` チェックは roster の `is_member(device_pub)` 照合に統合。
4. **UDPCursorChannel の認証追加**: 26byte生パケットに `session.encrypt` の結果 (AEADタグ込み) を通す。低遅延用途なので正典 §5 の「UDPは`set_receiving_nonce()`でスライディングウィンドウ」の注意点に従う (mugenlink側は現状 in-order 前提のtransportのみ実装、UDP向けの順序無視モードは未実装 — 必要なら mugenlink 側に追加作業が要る)。
5. **鍵交換をQR/psk方式に**: 現行の平文 `deviceInfo` 公開鍵交換 → 正典§4のQRブートストラップ (`bootstrap_psk`) 方式に寄せる。Mac同士なので QR の代わりに「もう一方のMacの画面に表示されたコード」等、UX は要検討 (下記「未解決」参照)。
6. **6桁コード (デッドコード)** はNoise移行時に削除するか、正典§4の「Fallback: 8桁英数コード」相当として作り直すか判断する。

## 未解決・検討事項

- **Discovery (mDNS) は mugenlink 側も未実装**。Mouse2Mouse は既存の `DiscoveryService.swift` (Bonjour) をそのまま使い続けてよい。
- Mac↔Mac構成なのでQRスキャンのUXがそのまま使えない (MagicDeckはiPhoneカメラでQRスキャンする前提)。bootstrap_psk の受け渡し方法をどうするか (例: 表示されたコードを手入力、AirDrop、等) は要検討。
- UDP低遅延パスの順序保証をどう扱うか (上記4)。
- 複数Mac (3台以上) 運用時に roster/epoch をどう配布するか (正典§6の「多対多メッシュ型」がそのまま当てはまる想定)。

## 次の一手

1. `mugenlink/swift` をMouse2Mouseにローカル Package としてリンクし、`import Mugenlink` が通ることをまずビルド確認する (MagicDeckと同じ手順、xcframework再ビルド不要)。
2. `CryptoManager.swift` を `NoiseSession` ベースの薄いラッパーに書き換え、`Mouse2MouseTests/SecurityTests.swift` を新実装に合わせて更新する。
