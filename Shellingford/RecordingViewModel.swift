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
    /// The day currently being uploaded (nil when idle). Tracking the day,
    /// not just a Bool, lets only that day's button show a spinner.
    @Published var uploadingDay: Date?
    @Published var uploadResultMessage: String?

    var isUploading: Bool { uploadingDay != nil }

    func isUploading(day: Date) -> Bool {
        guard let uploadingDay else { return false }
        return Calendar.current.isDate(uploadingDay, inSameDayAs: day)
    }

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
            // .voiceChat is the same audio mode Phone/FaceTime Audio use — it
            // optimizes microphone pickup for near-ear use, so holding the
            // phone like a call actually captures clearly instead of relying
            // on the bottom mic from an awkward distance.
            try session.setCategory(.playAndRecord, mode: .voiceChat)
            try session.setActive(true)

            // Lets iOS detect when the phone is held to your ear, so it can
            // automatically blank the screen — same as a real phone call.
            UIDevice.current.isProximityMonitoringEnabled = true

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
        UIDevice.current.isProximityMonitoringEnabled = false
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

    /// Deletes every recording belonging to the given day. The confirmation
    /// prompt itself lives in the view — this just does the actual deletion
    /// once the user has confirmed.
    func deleteAllRecordings(for day: Date) {
        let calendar = Calendar.current
        let dayRecordings = recordings.filter { calendar.isDate($0.createdAt, inSameDayAs: day) }

        for recording in dayRecordings {
            if currentlyPlayingID == recording.id {
                stopPlayback()
            }
            try? FileManager.default.removeItem(at: recording.url)
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
        guard !isUploading else { return }

        let calendar = Calendar.current
        let dayRecordings = recordings
            .filter { calendar.isDate($0.createdAt, inSameDayAs: day) }
            .sorted { $0.createdAt < $1.createdAt }

        guard !dayRecordings.isEmpty else {
            uploadResultMessage = "No recordings found for that day."
            return
        }

        uploadingDay = calendar.startOfDay(for: day)
        uploadResultMessage = nil

        // Keep the screen awake while uploading. If it auto-locks, iOS
        // suspends the app and the in-flight upload can stall or fail.
        UIApplication.shared.isIdleTimerDisabled = true

        Task {
            do {
                let bytes = try await UploadService.shared.upload(recordings: dayRecordings, day: day)
                let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
                await MainActor.run {
                    self.finishUpload(
                        message: "Uploaded \(dayRecordings.count) recording(s) for \(Self.dayFormatter.string(from: day)) (\(size))."
                    )
                }
            } catch {
                await MainActor.run {
                    self.finishUpload(message: "Upload failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func finishUpload(message: String) {
        uploadingDay = nil
        // Don't switch the screen-lock back on if a recording is in progress.
        UIApplication.shared.isIdleTimerDisabled = isRecording
        uploadResultMessage = message
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
