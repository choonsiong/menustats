import Foundation
import Darwin

/// The address the internet sees isn't known to this machine, so it has to
/// come from an outside service. This is the app's only network request,
/// which is why it is opt-in and only runs when the menu opens.
final class PublicIPMonitor {

    private static let service = URL(string: "https://checkip.amazonaws.com")!
    private static let minimumGap: TimeInterval = 60

    private var lastRequest: Date?

    // Ephemeral so nothing about the lookup is kept on disk.
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForResource = 5
        return URLSession(configuration: configuration)
    }()

    /// Calls back on the main thread with the address, or nil if it could not
    /// be found. Does nothing if the last request was under a minute ago.
    func read(completion: @escaping (String?) -> Void) {
        if let last = lastRequest, Date().timeIntervalSince(last) < Self.minimumGap { return }
        lastRequest = Date()

        session.dataTask(with: Self.service) { data, response, _ in
            let address = Self.address(from: data, response: response)
            DispatchQueue.main.async { completion(address) }
        }.resume()
    }

    /// The reply is outside input, so only a well-formed address reaches the menu.
    private static func address(from data: Data?, response: URLResponse?) -> String? {
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let data = data,
              let text = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        var parsed = in_addr()
        return inet_pton(AF_INET, text, &parsed) == 1 ? text : nil
    }
}
