import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = RecordingViewModel()
    @State private var dayPendingDeletion: Date?

    var body: some View {
        NavigationStack {
            VStack {
                if viewModel.recordings.isEmpty {
                    Spacer()
                    Text("No recordings yet")
                        .foregroundStyle(.secondary)
                    Spacer()
                } else {
                    List {
                        ForEach(viewModel.recordingsByDay, id: \.day) { group in
                            Section {
                                ForEach(group.recordings) { recording in
                                    RecordingRow(
                                        recording: recording,
                                        isPlaying: viewModel.currentlyPlayingID == recording.id,
                                        onTogglePlayback: { viewModel.togglePlayback(for: recording) }
                                    )
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            viewModel.deleteRecording(recording)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                }
                            } header: {
                                dayHeader(for: group.day, count: group.recordings.count)
                            }
                        }
                    }
                    .listStyle(.plain)
                }

                recordButton
                    .padding(.vertical, 24)
            }
            .navigationTitle("Shellingford")
            .fullScreenCover(isPresented: $viewModel.isRecording) {
                CallRecordingView(viewModel: viewModel)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        viewModel.uploadRecordings(for: Date())
                    } label: {
                        if viewModel.isUploading {
                            ProgressView()
                        } else {
                            Label("Upload Today", systemImage: "icloud.and.arrow.up")
                        }
                    }
                    .disabled(viewModel.isUploading)
                }
            }
            .alert(
                "Upload",
                isPresented: Binding(
                    get: { viewModel.uploadResultMessage != nil },
                    set: { if !$0 { viewModel.uploadResultMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(viewModel.uploadResultMessage ?? "")
            }
            .alert(
                "Delete Recordings?",
                isPresented: Binding(
                    get: { dayPendingDeletion != nil },
                    set: { if !$0 { dayPendingDeletion = nil } }
                ),
                presenting: dayPendingDeletion
            ) { day in
                Button("Delete", role: .destructive) {
                    viewModel.deleteAllRecordings(for: day)
                }
                Button("Cancel", role: .cancel) {}
            } message: { day in
                Text("This will permanently delete all recordings for \(day.formatted(date: .abbreviated, time: .omitted)). This can't be undone.")
            }
        }
    }

    /// Section header for a day's group of recordings — shows the date, how
    /// many recordings are in it, and an upload button scoped to just that day.
    /// This is what covers "upload a specific past day I forgot" — every day
    /// gets this same button, not just today.
    private func dayHeader(for day: Date, count: Int) -> some View {
        HStack {
            Text(day, style: .date)
            Text("(\(count))")
                .foregroundStyle(.secondary)
            Spacer()
            Button {
                dayPendingDeletion = day
            } label: {
                Image(systemName: "trash")
            }
            .foregroundStyle(.red)
            .disabled(viewModel.isUploading)
            Button {
                viewModel.uploadRecordings(for: day)
            } label: {
                Image(systemName: "icloud.and.arrow.up")
            }
            .disabled(viewModel.isUploading)
        }
    }

    private var recordButton: some View {
        VStack(spacing: 12) {
            Button(action: viewModel.requestPermissionAndToggleRecording) {
                ZStack {
                    Circle()
                        .stroke(Color.red, lineWidth: 3)
                        .frame(width: 88, height: 88)

                    // Morphs from a circle to a rounded square while recording,
                    // matching the familiar Voice Memos record button behavior.
                    RoundedRectangle(cornerRadius: viewModel.isRecording ? 8 : 36)
                        .fill(Color.red)
                        .frame(
                            width: viewModel.isRecording ? 36 : 72,
                            height: viewModel.isRecording ? 36 : 72
                        )
                        .animation(.easeInOut(duration: 0.2), value: viewModel.isRecording)
                }
            }
            .buttonStyle(.plain)

            if viewModel.isRecording {
                Text(formattedDuration(viewModel.currentRecordingDuration))
                    .font(.headline)
                    .monospacedDigit()
            }
        }
    }

    private func formattedDuration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval) / 60
        let seconds = Int(interval) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

struct RecordingRow: View {
    let recording: Recording
    let isPlaying: Bool
    let onTogglePlayback: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onTogglePlayback) {
                Image(systemName: isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 30))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 2) {
                Text(recording.createdAt, style: .date)
                    .font(.subheadline)
                Text(recording.createdAt.formatted(date: .omitted, time: .standard))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(durationString)
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 4)
    }

    private var durationString: String {
        let minutes = Int(recording.duration) / 60
        let seconds = Int(recording.duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

#Preview {
    ContentView()
}
