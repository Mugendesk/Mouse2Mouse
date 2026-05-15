import Foundation
import CoreFoundation

/// パフォーマンス計測ユーティリティ
/// 「たまに重くなる」現象の原因特定のため、軽量な計測ログを提供する
enum PerfLogger {

    // MARK: - Configuration

    /// メインスレッドハング検知の閾値 (秒)。これを超えるブロックを警告
    static let hangThresholdSec: Double = 0.05  // 50ms

    /// 処理時間計測の警告閾値 (秒)
    static let slowOperationThresholdSec: Double = 0.05  // 50ms

    /// WebSocket送信の警告閾値 (秒)
    static let slowSendThresholdSec: Double = 0.1  // 100ms

    /// 頻度カウンタのフラッシュ間隔 (秒)
    static let frequencyFlushIntervalSec: Double = 60.0

    // MARK: - Hang Detector

    private static var hangObserver: CFRunLoopObserver?
    private static var lastEntryTime: CFAbsoluteTime = 0

    /// メインスレッドの長時間ブロックを検知してログ出力する
    /// CFRunLoopObserverでbeforeWaiting↔afterWaitingの間隔を測る
    static func startHangDetector() {
        guard hangObserver == nil else { return }

        let activities: CFRunLoopActivity = [.entry, .beforeWaiting, .afterWaiting, .exit]

        hangObserver = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            activities.rawValue,
            true,  // repeats
            0,     // order
            { _, activity in
                let now = CFAbsoluteTimeGetCurrent()
                switch activity {
                case .entry, .afterWaiting:
                    lastEntryTime = now
                case .beforeWaiting, .exit:
                    let elapsed = now - lastEntryTime
                    if lastEntryTime > 0 && elapsed > hangThresholdSec {
                        print("[PerfLogger] ⚠️ MainThread hang: \(String(format: "%.0f", elapsed * 1000))ms")
                    }
                default:
                    break
                }
            }
        )

        if let observer = hangObserver {
            CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
            print("[PerfLogger] Hang detector started (threshold: \(Int(hangThresholdSec * 1000))ms)")
        }
    }

    static func stopHangDetector() {
        if let observer = hangObserver {
            CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes)
            hangObserver = nil
        }
    }

    // MARK: - Measure

    /// ブロックの実行時間を計測。閾値超過時のみログ出力
    @discardableResult
    static func measure<T>(_ label: String, threshold: Double = slowOperationThresholdSec, _ block: () throws -> T) rethrows -> T {
        let start = CFAbsoluteTimeGetCurrent()
        let result = try block()
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        if elapsed > threshold {
            print("[PerfLogger] ⏱ \(label): \(String(format: "%.1f", elapsed * 1000))ms")
        }
        return result
    }

    // MARK: - Frequency Counter

    private static var counters: [String: Int] = [:]
    private static var counterQueue = DispatchQueue(label: "PerfLogger.counters")
    private static var flushTimer: DispatchSourceTimer?

    /// 名前付きカウンタをインクリメント。定期的に出力される
    static func tick(_ label: String) {
        counterQueue.async {
            counters[label, default: 0] += 1
            ensureFlushTimer()
        }
    }

    private static func ensureFlushTimer() {
        guard flushTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: counterQueue)
        timer.schedule(deadline: .now() + frequencyFlushIntervalSec, repeating: frequencyFlushIntervalSec)
        timer.setEventHandler {
            flushCounters()
        }
        timer.resume()
        flushTimer = timer
    }

    private static func flushCounters() {
        guard !counters.isEmpty else { return }
        let summary = counters
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: " ")
        print("[PerfLogger] 📊 freq/\(Int(frequencyFlushIntervalSec))s: \(summary)")
        counters.removeAll()
    }
}
