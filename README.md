# Mouse2Mouse

Mac間の常時接続基盤。1つのマウスとキーボードで、複数のMacを操作できます。

## 機能

### Phase 1: MVP
- [x] mDNS (Bonjour) による自動デバイス発見
- [x] WebSocket による常時接続
- [x] カーソル位置共有
- [x] 画面端検知・制御権移譲
- [x] キーボード/マウス入力転送
- [x] メニューバーUI

### Phase 2: セキュリティ・安定化
- [x] 6桁コードによるペアリング認証
- [x] X25519 + ChaCha20-Poly1305 暗号化
- [x] 自動再接続
- [x] 画面配置UI（ドラッグ&ドロップ）

### Phase 3: クリップボード・ファイル転送
- [x] クリップボード同期（テキスト・画像）
- [x] LocalSend互換ファイル転送
- [x] ファイル進捗表示

## 必要な権限

- **アクセシビリティ**: ウィンドウ操作、入力監視に必要
- **入力監視**: マウス・キーボードイベントの傍受に必要
- **ネットワーク**: デバイス間通信に必要

## 技術スタック

- **言語**: Swift 5.x
- **UI**: SwiftUI + AppKit
- **ネットワーク**: Network.framework (NWListener, NWBrowser)
- **暗号化**: CryptoKit (X25519, ChaCha20-Poly1305)
- **入力傍受**: CGEvent API

## ディレクトリ構造（モノレポ）

```
Mouse2Mouse/
├── apps/
│   └── macos/                        # macOSアプリ
│       ├── Mouse2Mouse.xcodeproj
│       ├── Mouse2MouseApp.swift      # アプリエントリーポイント
│       ├── Core/
│       │   ├── DiscoveryService.swift    # mDNS発見・接続管理
│       │   ├── InputCapture.swift        # マウス/キーボード傍受
│       │   ├── ScreenManager.swift       # 画面配置管理
│       │   ├── PermissionManager.swift   # 権限管理
│       │   ├── PairingManager.swift      # ペアリング認証
│       │   ├── CryptoManager.swift       # 暗号化
│       │   ├── ConnectionManager.swift   # 接続管理・自動再接続
│       │   └── HotkeyManager.swift       # ホットキー
│       ├── Network/
│       │   ├── Protocol.swift            # メッセージ定義
│       │   ├── WebSocketServer.swift     # WebSocketサーバー
│       │   ├── WebSocketClient.swift     # WebSocketクライアント
│       │   ├── InputTransmitter.swift    # 入力送信
│       │   └── InputReceiver.swift       # 入力受信・注入
│       ├── Features/
│       │   ├── ClipboardSync.swift       # クリップボード同期
│       │   ├── FileTransfer.swift        # ファイル転送
│       │   └── FileTransferServer.swift  # LocalSend互換サーバー
│       └── UI/
│           ├── MenuBarView.swift         # メニューバーUI
│           ├── ScreenLayoutView.swift    # 画面配置UI
│           ├── PairingView.swift         # ペアリングUI
│           └── FileTransferView.swift    # ファイル転送UI
└── tools/
    └── rescue.sh                     # 緊急復旧スクリプト（カーソルロック解除）
```

## 通信プロトコル

### mDNS サービス
- サービスタイプ: `_mugendesk._tcp.local`
- ポート: 24800

### WebSocket メッセージ (JSON)

```json
// カーソル移動
{"type": "cursor_move", "x": 0.5, "y": 0.3}

// マウスボタン
{"type": "mouse_button", "button": 0, "state": "down"}

// スクロール
{"type": "scroll", "dx": 0, "dy": -10}

// キー入力
{"type": "key", "keycode": 0, "state": "down", "modifiers": ["cmd"]}

// 制御権移譲
{"type": "control_transfer", "to": "device_id", "entry_x": 0.0, "entry_y": 0.5}

// クリップボード
{"type": "clipboard", "format": "text", "data": "Hello"}
```

## ビルド

1. Xcodeで `apps/macos/Mouse2Mouse.xcodeproj` を開く
2. Signing & Capabilities でTeam IDを設定
3. Build (Cmd+B)

CLIから:
```bash
xcodebuild -project apps/macos/Mouse2Mouse.xcodeproj -scheme Mouse2Mouse build
```

## 使い方

1. 両方のMacでMouse2Mouseを起動
2. メニューバーのアイコンをクリック
3. 発見されたデバイスの「接続」をクリック
4. ペアリングコードを入力して認証
5. 「画面配置」でデバイスの位置関係を設定
6. カーソルを画面端に移動すると、隣のMacに移動

## ライセンス

MIT License
