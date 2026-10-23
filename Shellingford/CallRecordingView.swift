import SwiftUI
import UIKit

/// Full-screen recording view styled like the iPhone's own in-call screen:
/// contact header at the top-left, a 3x2 grid of round buttons, a red End
/// button, and a fully black screen when the phone is held to your ear.
struct CallRecordingView: View {
    @ObservedObject var viewModel: RecordingViewModel
    @State private var isNearEar = false

    var body: some View {
        ZStack {
            background

            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.top, 44)
                    .padding(.horizontal, 36)

                Spacer()

                controls
                    .padding(.horizontal, 24)
                    .padding(.bottom, 36)
            }
        }
        .preferredColorScheme(.dark)
        // Black-out while the phone is at your ear. iOS also blanks the
        // display itself on most iPhones; this overlay guarantees a black,
        // touch-proof screen either way, and fades back when you move away.
        .overlay {
            if isNearEar {
                Color.black
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture {}   // swallow accidental taps from your cheek
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isNearEar)
        .onAppear { isNearEar = UIDevice.current.proximityState }
        .onReceive(
            NotificationCenter.default.publisher(for: UIDevice.proximityStateDidChangeNotification)
        ) { _ in
            isNearEar = UIDevice.current.proximityState
        }
    }

    // MARK: - Pieces

    private var background: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.19, green: 0.16, blue: 0.15),
                    Color(red: 0.25, green: 0.23, blue: 0.22),
                    Color(red: 0.22, green: 0.25, blue: 0.28)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [Color(red: 0.45, green: 0.40, blue: 0.39).opacity(0.7), .clear],
                center: UnitPoint(x: 0.9, y: 0.3),
                startRadius: 10,
                endRadius: 420
            )
        }
        .ignoresSafeArea()
    }

    private var header: some View {
        HStack(spacing: 16) {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [
                            Color(red: 0.18, green: 0.16, blue: 0.43),
                            Color(red: 0.84, green: 0.27, blue: 0.29)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(width: 68, height: 68)
                .overlay(
                    Image(systemName: "waveform")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.white)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(statusText)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.55))
                    .monospacedDigit()
                Text("Shellingford")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.white)
            }
        }
    }

    private var statusText: String {
        if viewModel.isPaused {
            return "Muted · \(formattedDuration(viewModel.currentRecordingDuration))"
        }
        if viewModel.currentRecordingDuration < 1 {
            return "Recording…"
        }
        return formattedDuration(viewModel.currentRecordingDuration)
    }

    private var controls: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 26) {
            GridRow {
                CallButton(icon: "speaker.wave.3.fill", label: "Speaker", isEnabled: false)
                CallButton(icon: "video.fill", label: "FaceTime", isEnabled: false)
                CallButton(icon: "mic.slash.fill", label: "Mute", isActive: viewModel.isPaused) {
                    viewModel.togglePause()
                }
            }
            GridRow {
                CallButton(icon: "ellipsis", label: "More", isEnabled: false)
                CallButton(
                    icon: "phone.down.fill",
                    label: "End",
                    fill: Color(red: 0.80, green: 0.17, blue: 0.14)
                ) {
                    viewModel.requestPermissionAndToggleRecording()
                }
                CallButton(icon: "circle.grid.3x3.fill", label: "Keypad", isEnabled: false)
            }
        }
    }

    private func formattedDuration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

/// One round call-screen button with its label underneath.
private struct CallButton: View {
    let icon: String
    let label: String
    var isActive = false
    var isEnabled = true
    var fill: Color? = nil
    var action: () -> Void = {}

    var body: some View {
        VStack(spacing: 10) {
            Button(action: action) {
                ZStack {
                    Circle()
                        .fill(fill ?? (isActive ? Color.white : Color.white.opacity(0.14)))
                    Circle()
                        .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                    Image(systemName: icon)
                        .font(.system(size: 30, weight: .regular))
                        .foregroundStyle(isActive ? Color.black : Color.white)
                }
                .frame(width: 80, height: 80)
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled)

            Text(label)
                .font(.system(size: 17))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
        .opacity(isEnabled ? 1 : 0.5)
    }
}
