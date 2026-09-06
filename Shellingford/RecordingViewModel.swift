import Foundation
import AVFoundation
import Combine
import UIKit

/// A single saved voice recording, with the metadata we care about for the journal.
struct Recording: Identifiable {
    let id = UUID()
    let url: URL
    let createdAt: Date
    var duration: TimeInterval

    var fileName: String { url.lastPathComponent }
}

final class RecordingViewModel: NSObject, ObservableObject {
    @Published var recordings: [Recording] = []
    @Published var isRecording = false
    @Published var currentRecordingDuration: TimeInterval = 0
    @Published var currentlyPlayingID: UUID?
    @Published var isUploading = false
    @Published var uploadResultMessage: String?

    private var audioRecorder: AVAudioRecorder?
    private var audioPlayer: AVAudioPlayer?
    private var recordingStartTime: Date?
    private var timer: Timer?

    override init() {
        super.init()
        loadExistingRecordings()
    }

    private var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    // MARK: - Permission + recording control

    func requestPermissionAndToggleRecording() {
        // Note: AVAudioSession.requestRecordPermission is deprecated in newer iOS
        // in favor of AVAudioApplication.requestRecordPermission, but still works
        // and keeps this compatible across a wider range of iOS versions.
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                if granted {
                    self.toggleRecording()
                } else {
                    print("Microphone permission denied — enable it in Settings > Privacy > Microphone.")
                }
            }
        }
    }

    private func toggleRecording() {
        isRecording ? stopRecording() : startRecording()
    }

    private func startRecording() {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .default)
            try session.setActive(true)

            // Filename encodes the exact date/time this entry was recorded.
            let safeTimestamp = ISO8601DateFormatter()
                .string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let fileURL = documentsDirectory.appendingPathComponent("\(safeTimestamp).m4a")

            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 44_100,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ]

            audioRecorder = try AVAudioRecorder(url: fileURL, settings: settings)
            audioRecorder?.delegate = self
            audioRecorder?.record()

            // Prevent auto-lock while recording — otherwise iOS suspends audio
            // capture once the screen locks, and anything said after that point
            // silently doesn't get recorded.
            UIApplication.shared.isIdleTimerDisabled = true

            recordingStartTime = Date()
            isRecording = true
            startTimer()
        } catch {
            print("Failed to start recording: \(error)")
        }
    }

    private func stopRecording() {
        audioRecorder?.stop()
        isRecording = false
        stopTimer()
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let start = self.recordingStartTime else { return }
            self.currentRecordingDuration = Date().timeIntervalSince(start)
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
        currentRecordingDuration = 0
    }

    // MARK: - Playback control

    func togglePlayback(for recording: Recording) {
        if currentlyPlayingID == recording.id {
            stopPlayback()
        } else {
            play(recording)
        }
    }

    private func play(_ recording: Recording) {
        // Switch the session to playback so it comes out the speaker, not the mic path.
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default)
            try session.setActive(true)

            audioPlayer = try AVAudioPlayer(contentsOf: recording.url)
            audioPlayer?.delegate = self
            audioPlayer?.play()
            currentlyPlayingID = recording.id
        } catch {
            print("Failed to play recording: \(error)")
        }
    }

    func stopPlayback() {
        audioPlayer?.stop()
        audioPlayer = nil
        currentlyPlayingID = nil
    }

    // MARK: - Delete

    func deleteRecording(_ recording: Recording) {
        if currentlyPlayingID == recording.id {
            stopPlayback()
        }
        do {
            try FileManager.default.removeItem(at: recording.url)
        } catch {
            print("Failed to delete recording: \(error)")
        }
        loadExistingRecordings()
    }

    // MARK: - Grouping + upload

    /// Recordings grouped by calendar day, newest day first — this is what
    /// both the per-day upload buttons and the section list are built from.
    var recordingsByDay: [(day: Date, recordings: [Recording])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: recordings) { calendar.startOfDay(for: $0.createdAt) }
        return grouped
            .map { (day: $0.key, recordings: $0.value.sorted { $0.createdAt < $1.createdAt }) }
            .sorted { $0.day > $1.day }
    }

    /// Consolidates and uploads every recording from the given day — works
    /// equally for today or any past day you forgot to send earlier.
    func uploadRecordings(for day: Date) {
        let calendar = Calendar.current
        let dayRecordings = recordings
            .filter { calendar.isDate($0.createdAt, inSameDayAs: day) }
            .sorted { $0.createdAt < $1.createdAt }

        guard !dayRecordings.isEmpty else {
            uploadResultMessage = "No recordings found for that day."
            return
        }

        isUploading = true
        uploadResultMessage = nil

        Task {
            do {
                try await UploadService.shared.upload(recordings: dayRecordings, day: day)
                await MainActor.run {
                    self.isUploading = false
                    self.uploadResultMessage =
                        "Uploaded \(dayRecordings.count) recording(s) for \(Self.dayFormatter.string(from: day))."
                }
            } catch {
                await MainActor.run {
                    self.isUploading = false
                    self.uploadResultMessage = "Upload failed: \(error.localizedDescription)"
                }
            }
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter
    }()

    // MARK: - Loading saved recordings

    /// Rebuilds the list by scanning the Documents directory. Simple and reliable
    /// for the MVP — no separate database needed yet since the files themselves
    /// (plus their creation date) are the source of truth.
    private func loadExistingRecordings() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: documentsDirectory,
            includingPropertiesForKeys: [.creationDateKey]
        ) else { return }

        recordings = files
            .filter { $0.pathExtension == "m4a" }
            .compactMap { url -> Recording? in
                guard let attrs = try? fm.attributesOfItem(atPath: url.path),
                      let createdAt = attrs[.creationDate] as? Date else { return nil }
                let asset = AVURLAsset(url: url)
                let duration = CMTimeGetSeconds(asset.duration)
                return Recording(url: url, createdAt: createdAt, duration: duration)
            }
            .sorted { $0.createdAt > $1.createdAt }
    }
}

extension RecordingViewModel: AVAudioRecorderDelegate {
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        loadExistingRecordings()
    }
}

extension RecordingViewModel: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        currentlyPlayingID = nil
    }
}
