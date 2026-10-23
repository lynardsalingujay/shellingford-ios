import Foundation

enum UploadError: LocalizedError {
    case invalidResponse
    case serverError(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The server didn't return a valid response."
        case .serverError(let code, let detail):
            switch code {
            case 404:
                return "The upload address wasn't found (404). Check the webhook URL and that the n8n workflow is active."
            case 413:
                return "The upload was too large for the server (413). Try again with fewer or shorter recordings."
            default:
                return "Server responded with error \(code). \(detail)"
            }
        }
    }
}

final class UploadService {
    static let shared = UploadService()

    // n8n workflow endpoint (self-hosted on Fly.io)
    private let endpoint = URL(string: "https://skyguyver-n8n-test.fly.dev/webhook/shellingford-upload")!

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    /// Uploads all of a day's recordings as one multipart request, tagged
    /// with the day so the backend can group/label the batch.
    /// Returns the number of bytes sent, so the app can show the upload size.
    func upload(recordings: [Recording], day: Date) async throws -> Int {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        // Idle timeout while waiting on the server (the default is 60 seconds).
        request.timeoutInterval = 120

        let boundary = "Boundary-\(UUID().uuidString)"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()

        // Important: use the device's local calendar day here, not UTC.
        // ISO8601DateFormatter defaults to UTC, which caused the day field
        // to read as "yesterday" once local time was ahead of UTC's rollover.
        let dayString = Self.dayFormatter.string(from: day)

        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"day\"\r\n\r\n".data(using: .utf8)!)
        body.append("\(dayString)\r\n".data(using: .utf8)!)

        for recording in recordings {
            let fileData = try Data(contentsOf: recording.url)
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append(
                "Content-Disposition: form-data; name=\"recordings[]\"; filename=\"\(recording.fileName)\"\r\n"
                    .data(using: .utf8)!
            )
            body.append("Content-Type: audio/m4a\r\n\r\n".data(using: .utf8)!)
            body.append(fileData)
            body.append("\r\n".data(using: .utf8)!)
        }

        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        let (data, response) = try await URLSession.shared.upload(for: request, from: body)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw UploadError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            let detail = String(data: data.prefix(200), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw UploadError.serverError(httpResponse.statusCode, detail)
        }

        return body.count
    }
}
