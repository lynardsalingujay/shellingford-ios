import SwiftUI

/// Shown full-screen while recording — styled like a phone call screen, so
/// holding the phone up to your ear to talk feels natural instead of
/// awkwardly talking into the phone an inch from your mouth.
struct CallRecordingView: View {
    @ObservedObject var viewModel: RecordingViewModel

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.black, Color(red: 0.1, green: 0.1, blue: 0.16)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 40) {
                Spacer()

                VStack(spacing: 16) {
                    Circle()
                        .fill(Color.red.opacity(0.15))
                        .frame(width: 140, height: 140)
                        .overlay(
                            Image(systemName: "waveform")
                                .font(.system(size: 50, weight: .regular))
                                .foregroundStyle(.white)
                        )

                    Text("Shellingford")
                        .font(.title2.bold())
                        .foregroundStyle(.white)

                    Text("Recording your journal")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.7))
                }

                Text(formattedDuration(viewModel.currentRecordingDuration))
                    .font(.system(size: 44, weight: .light, design: .monospaced))
                    .foregroundStyle(.white)
                    .monospacedDigit()

                Spacer()

                Button {
                    viewModel.requestPermissionAndToggleRecording()
                } label: {
                    ZStack {
                        Circle()
                            .fill(Color.red)
                            .frame(width: 76, height: 76)
                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 28))
                            .foregroundStyle(.white)
                    }
                }
                .padding(.bottom, 60)
            }
        }
        .statusBarHidden()
    }

    private func formattedDuration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
