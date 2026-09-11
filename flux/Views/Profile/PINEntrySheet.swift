import SwiftUI
import AppKit
import Combine

enum PINMode {
    case verify(title: String? = nil, subtitle: String? = nil, profileId: UUID? = nil, onSuccess: () -> Void)
    case setup(title: String? = nil, subtitle: String? = nil, profileId: UUID? = nil, onSuccess: ((String) -> Void)? = nil)
}

// MARK: - Key Event Monitor Coordinator
@MainActor
final class PINKeyMonitorCoordinator: NSObject, ObservableObject {
    var onDigit: ((Character) -> Void)?
    var onBackspace: (() -> Void)?
    var onEscape: (() -> Void)?
    var onPaste: ((String) -> Void)?
    private var monitor: Any?

    func start() {
        stop()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self = self else { return event }

            // Escape key (dismiss)
            if event.keyCode == 53 {
                self.onEscape?()
                return nil
            }

            // Backspace / Delete key
            if event.keyCode == 51 {
                self.onBackspace?()
                return nil
            }

            // Command + V (Paste)
            if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "v" {
                if let str = NSPasteboard.general.string(forType: .string) {
                    let digits = str.filter { $0.isNumber }
                    if !digits.isEmpty {
                        self.onPaste?(digits)
                        return nil
                    }
                }
            }

            // Number keys (0...9, both row and keypad)
            if let chars = event.characters, chars.count == 1, let char = chars.first, char.isNumber {
                self.onDigit?(char)
                return nil
            }

            return event
        }
    }

    func stop() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }

    deinit {
        if let m = monitor {
            NSEvent.removeMonitor(m)
        }
    }
}

// MARK: - PINEntrySheet
/// Premium macOS Liquid Glass modal for entering or configuring a 4-digit PIN.
/// Listens to physical keyboard events cleanly via NSEvent without invisible textfield artifacts.
struct PINEntrySheet: View {
    let mode: PINMode
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var lockManager = ParentalLockManager.shared
    @StateObject private var keyCoordinator = PINKeyMonitorCoordinator()

    @State private var pin: String = ""
    @State private var firstEnteredPin: String = ""
    @State private var isConfirming: Bool = false
    @State private var errorMessage: String? = nil
    @State private var isErrorFlashing: Bool = false
    @State private var shakeOffset: CGFloat = 0
    @State private var isCloseHovered: Bool = false

    var body: some View {
        ZStack {
            // Liquid Glass Background
            Color(red: 0.09, green: 0.10, blue: 0.13)
                .ignoresSafeArea()

            RadialGradient(
                colors: [
                    Color.white.opacity(0.07),
                    Color.white.opacity(0.01),
                    Color.clear
                ],
                center: .top,
                startRadius: 0,
                endRadius: 260
            )
            .ignoresSafeArea()

            VStack(spacing: 22) {
                // Header Icon
                headerIcon
                    .padding(.top, 4)

                // Titles
                VStack(spacing: 6) {
                    Text(titleText)
                        .font(.system(size: 20, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)

                    Text(subtitleText)
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(.white.opacity(0.60))
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .padding(.horizontal, 16)
                }

                // 4-Digit Input Boxes
                HStack(spacing: 16) {
                    ForEach(0..<4, id: \.self) { index in
                        pinBox(at: index)
                    }
                }
                .offset(x: shakeOffset)
                .padding(.vertical, 4)

                // Error / Lockout / Helper Status
                statusFooter
            }
            .padding(.horizontal, 30)
            .padding(.vertical, 26)
        }
        .frame(width: 360, height: 310)
        .overlay(alignment: .topTrailing) {
            closeButton
        }
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color.white.opacity(0.20), Color.white.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
        .onAppear {
            setupKeyCoordinator()
        }
        .onDisappear {
            keyCoordinator.stop()
        }
    }

    // MARK: - Header Icon
    private var headerIcon: some View {
        ZStack {
            Circle()
                .fill(Color(red: 0.96, green: 0.68, blue: 0.20).opacity(0.12))
                .frame(width: 68, height: 68)
                .blur(radius: 10)

            Circle()
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.12), Color.white.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 56, height: 56)
                .overlay(
                    Circle()
                        .stroke(
                            LinearGradient(
                                colors: [Color.white.opacity(0.25), Color.white.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )

            Image(systemName: isConfirming ? "checkmark.shield.fill" : "lock.shield.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(
                    LinearGradient(
                        colors: [
                            Color(red: 1.0, green: 0.84, blue: 0.40),
                            Color(red: 0.96, green: 0.64, blue: 0.16)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .shadow(color: Color(red: 0.96, green: 0.64, blue: 0.16).opacity(0.35), radius: 6, y: 2)
        }
    }

    // MARK: - PIN Box View
    private func pinBox(at index: Int) -> some View {
        let isFilled = index < pin.count
        let isActive = index == pin.count && !lockManager.isLockedOut && !isErrorFlashing

        return ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    isErrorFlashing ? Color.red.opacity(0.10) :
                        (isFilled ? Color.white.opacity(0.09) :
                            (isActive ? Color.white.opacity(0.06) : Color.white.opacity(0.03)))
                )

            if isFilled {
                Circle()
                    .fill(Color.white)
                    .frame(width: 13, height: 13)
                    .transition(.scale)
            } else if isActive {
                Capsule()
                    .fill(Color(red: 0.98, green: 0.78, blue: 0.35).opacity(0.85))
                    .frame(width: 12, height: 2.5)
                    .offset(y: 13)
            } else {
                Circle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 5, height: 5)
            }
        }
        .frame(width: 54, height: 60)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    isErrorFlashing ? Color.red.opacity(0.85) :
                        (isActive ? Color(red: 0.98, green: 0.78, blue: 0.35).opacity(0.9) :
                            (isFilled ? Color.white.opacity(0.32) : Color.white.opacity(0.11))),
                    lineWidth: (isActive || isErrorFlashing) ? 1.5 : 1
                )
                .shadow(
                    color: isErrorFlashing ? Color.red.opacity(0.4) :
                        (isActive ? Color(red: 0.96, green: 0.70, blue: 0.25).opacity(0.35) : Color.clear),
                    radius: 7, x: 0, y: 0
                )
        )
        .animation(.spring(response: 0.22, dampingFraction: 0.65), value: pin.count)
        .animation(.easeInOut(duration: 0.15), value: isErrorFlashing)
    }

    // MARK: - Status Footer
    private var statusFooter: some View {
        Group {
            if lockManager.isLockedOut {
                HStack(spacing: 6) {
                    Image(systemName: "hourglass")
                        .font(.system(size: 11, weight: .semibold))
                    Text("Locked out. Try again in \(lockManager.remainingLockoutSeconds)s")
                        .font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.45))
            } else if let error = errorMessage {
                HStack(spacing: 5) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 11, weight: .semibold))
                    Text(error)
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.45))
                .transition(.scale.combined(with: .opacity))
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "keyboard")
                        .font(.system(size: 11))
                    Text("Type 4-digit code on keyboard")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.35))
            }
        }
        .frame(height: 20)
    }

    // MARK: - Close Button
    private var closeButton: some View {
        Button(action: { dismiss() }) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(isCloseHovered ? 0.12 : 0.06))
                    .frame(width: 28, height: 28)

                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white.opacity(isCloseHovered ? 0.9 : 0.45))
            }
        }
        .buttonStyle(.plain)
        .onHover { isCloseHovered = $0 }
        .padding(14)
    }

    // MARK: - Key Monitor Setup & Handlers
    private func setupKeyCoordinator() {
        keyCoordinator.onDigit = { char in
            guard pin.count < 4, !lockManager.isLockedOut else { return }
            pin.append(char)
            errorMessage = nil

            if pin.count == 4 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    processCompletedPin()
                }
            }
        }

        keyCoordinator.onBackspace = {
            guard !pin.isEmpty, !lockManager.isLockedOut else { return }
            pin.removeLast()
            errorMessage = nil
        }

        keyCoordinator.onEscape = {
            dismiss()
        }

        keyCoordinator.onPaste = { digits in
            guard !lockManager.isLockedOut else { return }
            pin = String(digits.prefix(4))
            errorMessage = nil

            if pin.count == 4 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    processCompletedPin()
                }
            }
        }

        keyCoordinator.start()
    }

    // MARK: - Helpers & Logic
    private var titleText: String {
        switch mode {
        case .verify(let title, _, _, _):
            return title ?? "Parental PIN"
        case .setup(let title, _, _, _):
            return isConfirming ? "Confirm PIN" : (title ?? "Set Profile PIN")
        }
    }

    private var subtitleText: String {
        switch mode {
        case .verify(_, let subtitle, _, _):
            return subtitle ?? "Enter your 4-digit PIN to proceed"
        case .setup(_, let subtitle, _, _):
            return isConfirming ? "Re-enter the 4-digit PIN to confirm" : (subtitle ?? "Choose a 4-digit PIN to lock this profile")
        }
    }

    private func processCompletedPin() {
        switch mode {
        case .verify(_, _, let profileId, let onSuccess):
            if lockManager.verify(pin: pin, for: profileId) {
                dismiss()
                onSuccess()
            } else {
                triggerShake(message: "Incorrect PIN. Try again.")
                pin = ""
            }

        case .setup(_, _, let profileId, let onSuccess):
            if !isConfirming {
                firstEnteredPin = pin
                pin = ""
                isConfirming = true
            } else {
                if pin == firstEnteredPin {
                    lockManager.setPin(pin, for: profileId)
                    dismiss()
                    onSuccess?(pin)
                } else {
                    triggerShake(message: "PINs did not match. Start over.")
                    pin = ""
                    firstEnteredPin = ""
                    isConfirming = false
                }
            }
        }
    }

    private func triggerShake(message: String) {
        errorMessage = message
        isErrorFlashing = true

        withAnimation(.default) {
            shakeOffset = -12
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            withAnimation(.default) { shakeOffset = 12 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) {
            withAnimation(.default) { shakeOffset = -8 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) {
            withAnimation(.default) { shakeOffset = 8 }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.32) {
            withAnimation(.default) {
                shakeOffset = 0
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
            withAnimation(.easeOut(duration: 0.2)) {
                isErrorFlashing = false
            }
        }
    }
}
