import SwiftUI
import Combine

/// ペアリング認証UI
struct PairingView: View {
    @ObservedObject var pairingManager = PairingManager.shared
    @Environment(\.dismiss) private var dismiss

    @State private var inputCode = ""
    @State private var showingError = false
    @State private var errorMessage = ""

    enum Mode {
        case displayCode
        case inputCode
    }

    let mode: Mode
    let deviceName: String

    var body: some View {
        VStack(spacing: 24) {
            // Header
            headerView

            // Content
            switch mode {
            case .displayCode:
                displayCodeView
            case .inputCode:
                inputCodeView
            }

            // Actions
            actionsView
        }
        .padding(24)
        .frame(width: 320)
        .background(Color(NSColor.windowBackgroundColor))
        .alert("エラー", isPresented: $showingError) {
            Button("OK") { }
        } message: {
            Text(errorMessage)
        }
    }

    // MARK: - Header

    private var headerView: some View {
        VStack(spacing: 12) {
            Image(systemName: "link.circle.fill")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("デバイスをペアリング")
                .font(.title2)
                .fontWeight(.semibold)

            Text(deviceName)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Display Code View

    private var displayCodeView: some View {
        VStack(spacing: 16) {
            Text("このコードを相手のデバイスで入力してください")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            if let request = pairingManager.pendingPairingRequest {
                // 大きなコード表示
                HStack(spacing: 8) {
                    ForEach(Array(request.code), id: \.self) { digit in
                        Text(String(digit))
                            .font(.system(size: 36, weight: .bold, design: .monospaced))
                            .frame(width: 44, height: 56)
                            .background(Color.secondary.opacity(0.1))
                            .cornerRadius(8)
                    }
                }

                // 有効期限
                TimeRemainingView(expiresAt: request.expiresAt)
            }
        }
    }

    // MARK: - Input Code View

    private var inputCodeView: some View {
        VStack(spacing: 16) {
            Text("相手のデバイスに表示されている\n6桁のコードを入力してください")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)

            // コード入力フィールド
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { index in
                    codeDigitField(index: index)
                }
            }

            // 隠しテキストフィールド
            TextField("", text: $inputCode)
                .textFieldStyle(.plain)
                .frame(width: 0, height: 0)
                .opacity(0)
                .onChange(of: inputCode) { newValue in
                    // 数字のみ許可、6桁まで
                    let filtered = newValue.filter { $0.isNumber }.prefix(6)
                    inputCode = String(filtered)

                    // 6桁入力されたら自動検証
                    if inputCode.count == 6 {
                        verifyCode()
                    }
                }
        }
        .onAppear {
            // フォーカスを当てる
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.keyWindow?.makeFirstResponder(nil)
            }
        }
    }

    private func codeDigitField(index: Int) -> some View {
        let digit = index < inputCode.count ? String(inputCode[inputCode.index(inputCode.startIndex, offsetBy: index)]) : ""

        return Text(digit)
            .font(.system(size: 24, weight: .bold, design: .monospaced))
            .frame(width: 36, height: 48)
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(index == inputCode.count ? Color.accentColor : Color.clear, lineWidth: 2)
            )
    }

    // MARK: - Actions

    private var actionsView: some View {
        HStack(spacing: 12) {
            Button("キャンセル") {
                pairingManager.cancelPairingRequest()
                dismiss()
            }
            .buttonStyle(.bordered)

            if mode == .inputCode {
                Button("確認") {
                    verifyCode()
                }
                .buttonStyle(.borderedProminent)
                .disabled(inputCode.count != 6)
            }
        }
    }

    // MARK: - Actions

    private func verifyCode() {
        if pairingManager.verifyPairingCode(inputCode) {
            dismiss()
        } else {
            errorMessage = "コードが一致しません"
            showingError = true
            inputCode = ""
        }
    }
}

// MARK: - Time Remaining View

struct TimeRemainingView: View {
    let expiresAt: Date

    @State private var timeRemaining: TimeInterval = 0

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.caption)

            Text(timeRemainingString)
                .font(.caption)
                .monospacedDigit()
        }
        .foregroundColor(timeRemaining < 30 ? .orange : .secondary)
        .onAppear {
            updateTimeRemaining()
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            updateTimeRemaining()
        }
    }

    private var timeRemainingString: String {
        let minutes = Int(timeRemaining) / 60
        let seconds = Int(timeRemaining) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func updateTimeRemaining() {
        timeRemaining = max(0, expiresAt.timeIntervalSinceNow)
    }
}

// MARK: - Paired Devices List

struct PairedDevicesView: View {
    @ObservedObject var pairingManager = PairingManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("ペアリング済みデバイス")
                .font(.headline)

            if pairingManager.pairedDevices.isEmpty {
                HStack {
                    Spacer()
                    Text("ペアリング済みのデバイスはありません")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.vertical)
            } else {
                ForEach(pairingManager.pairedDevices) { device in
                    PairedDeviceRow(device: device)
                }
            }
        }
        .padding()
    }
}

struct PairedDeviceRow: View {
    let device: PairingManager.PairedDevice
    @ObservedObject var pairingManager = PairingManager.shared

    var body: some View {
        HStack {
            Image(systemName: "desktopcomputer")
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(device.hostname)
                    .font(.subheadline)

                Text("ペアリング: \(device.pairedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Spacer()

            Button(role: .destructive) {
                pairingManager.unpair(deviceId: device.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.plain)
            .foregroundColor(.red)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Preview

#Preview("Display Code") {
    PairingView(mode: .displayCode, deviceName: "MacBook Pro")
}

#Preview("Input Code") {
    PairingView(mode: .inputCode, deviceName: "MacBook Air")
}
