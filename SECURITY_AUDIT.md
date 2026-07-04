# セキュリティ監査メモ (2026-06-30)

Mouse2Mouse (macOS) のネットワーク経路に対する現状把握。結論: **LAN上の攻撃者が、ペアリングも暗号化もすり抜けて任意のキー入力・クリックを注入できる状態。**
暗号レイヤ自体（X25519 + ChaCha20-Poly1305 + HKDF + replay対策 + TOFU）は実装されているが、「平文を拒否しない」「入力イベントを認可しない」の2点で実質無効化されている。

---

## 🔴 致命的

### 1. 暗号化が「任意」（受信側が平文を受理する）
受信側は「暗号化されていれば復号、なければ平文のまま処理」というフォールバック構造。

- `apps/macos/Core/DiscoveryService.swift:386-393` — `initialType == .encrypted` でなければ `message = rawMessage` として平文を採用。
- `apps/macos/Network/WebSocketClient.swift:384-389` — 同じフォールバック。
- 結果、`DiscoveryService.swift:496-501` で `cursorMove / mouseButton / scroll / key / clipboard` が暗号化必須チェックなしで `handleIncomingMessage` に到達。

→ 攻撃者は WebSocket に接続して `{"type":"key", ...}` を**平文で**送るだけでキーストローク注入が可能。暗号が破られるのではなく、要求されていないのが問題。

### 2. 入力イベントにペアリングゲートが無い
承認ゲート (`isPaired` / `requestApproval`) は `.deviceInfo` 分岐のみ (`DiscoveryService.swift:421-459`)。
`cursorMove/key/...` 側には送信者が承認済みか確認する処理が一切ない。`serverClientMapping` が無くても `clientId` をそのまま peerId として処理続行 (`:498-501`)。

→ deviceInfo ハンドシェイクを飛ばして直接入力イベントを送れば未認証で操作できる。

### 3. cursor_move 高速パスが無認証・無暗号
`DiscoveryService.swift:373-377` — 型デコード後に即 `InputReceiver` 直行。チェックなし。

### 4. UDP カーソルチャネルが完全に無防備
`apps/macos/Network/UDPCursorChannel.swift:161-175` — ポート 24801 に 26 byte 送れば誰でもカーソルを動かせる。送信元IP検証なし。
唯一のガードは `connectedPeers.isEmpty` チェック (`:166`) = 「誰か1台でも接続中なら任意の送信元を受理」。コメントは「同一LANスプーフィング遮断」と書いてあるが**実際には遮断していない**。

---

## 🟠 高

### 5. 鍵交換が中間者攻撃 (MITM) に弱い
- 公開鍵は `deviceInfo` で平文交換 (`DiscoveryService.swift:603-607` の `proceedDeviceInfo`)。
- 承認は AirDrop 風 Yes/No のみ。fingerprint をユーザーに見せて突き合わせる SAS 照合が無い (`PairingManager.swift:147-171`)。
- → 初回ペアリング時に能動的 MITM で鍵すり替えが可能。

### 6. 6桁ペアリングコード経路がデッドコード
`PairingManager.verifyPairingCode` (`:99`) / `startPairingRequest` (`:83`) は実フローで未使用。認証は承認ダイアログ (TOFU) のみで、コードは効いていない。

---

## 🟡 補足
- レート制限 `maxMessagesPerSecond` (`DiscoveryService.swift:357-369`) はあるが、これは DoS 緩和であって認可ではない。
- WebSocket はプレーン `ws://`（TLSなし）。app層 ChaCha が一部メッセージにしか掛かっていない前提を崩している。
- UDP の replay 対策 `lastReceivedTimestamp` (`UDPCursorChannel.swift:68`) はピア単位でなく単一グローバル、かつ送信側クロック依存。
- `pairedDevices` は UserDefaults 保存だが中身は公開鍵 + hostname のため機微度は低い。秘密鍵は Keychain 保存 (良)。

---

## 修正の優先順位（いずれも小変更で塞げる）
1. **入力系メッセージは必ず `unwrapMessage` 成功（有効なセッション鍵での復号）を経由しなければ破棄**。平文フォールバックを廃止。(致命的 #1, #3)
2. `handleIncomingMessage` 入口で **`PairingManager.isPaired` + `serverClientMapping` 確立済み**を必須ゲートに。(致命的 #2)
3. UDP パケットに**ピアごとのセッション鍵で MAC/暗号**を付与し、送信元IPを登録済みエンドポイントと照合。(致命的 #4)
4. 承認ダイアログに**両端末の fingerprint を表示**して目視照合（既存の `PairingManager.fingerprint(of:)` を活用）。(高 #5)

> 推奨着手順: ① → ② が最小変更で最大効果。
