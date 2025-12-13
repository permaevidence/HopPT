import Foundation
import Combine

class LMStudioService: ObservableObject {
    private let settings: AppSettings
    private var cancellables = Set<AnyCancellable>()

    // ⬇️ ADD
    private var activeSession: URLSession?
    private var activeTask: URLSessionDataTask?

    init(settings: AppSettings) {
        self.settings = settings
    }

    func streamChat(messages: [[String: String]],
                    onChunk: @escaping (String) -> Void,
                    onComplete: @escaping () -> Void,
                    onError: @escaping (Error) -> Void) {

        guard let url = settings.chatCompletionsURL else {
            onError(NSError(domain: "Invalid API Base", code: 0, userInfo: [NSLocalizedDescriptionKey: "apiBase is invalid"]))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in settings.authHeaders { request.setValue(v, forHTTPHeaderField: k) }

        request.timeoutInterval = 15 * 60

        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15 * 60
        cfg.timeoutIntervalForResource = 15 * 60

        let body: [String: Any] = [
            "model": settings.model,
            "messages": messages,
            "stream": true
        ]
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let delegate = StreamDelegate(onChunk: onChunk, onComplete: onComplete, onError: onError)
        // ⬇️ CHANGE this block so we retain session/task
        let session = URLSession(configuration: cfg, delegate: delegate, delegateQueue: nil)
        self.activeSession = session
        let task = session.dataTask(with: request)
        self.activeTask = task
        task.resume()
    }

    // ⬇️ ADD
    func cancelStreaming() {
        activeTask?.cancel()
        activeTask = nil
        activeSession?.invalidateAndCancel()
        activeSession = nil
    }
}

class StreamDelegate: NSObject, URLSessionDataDelegate {
    private let onChunk: (String) -> Void
    private let onComplete: () -> Void
    private let onError: (Error) -> Void

    private var buffer = Data()
    private var finished = false
    private var thinkFilter = ThinkFilter()

    init(onChunk: @escaping (String) -> Void,
         onComplete: @escaping () -> Void,
         onError: @escaping (Error) -> Void) {
        self.onChunk = onChunk
        self.onComplete = onComplete
        self.onError = onError
    }

    private func finishIfNeeded() {
        guard !finished else { return }
        finished = true
        DispatchQueue.main.async { self.onComplete() }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)

        // Support both LF and CRLF separators for SSE frames
        let sepLF = "\n\n".data(using: .utf8)!
        let sepCRLF = "\r\n\r\n".data(using: .utf8)!

        while true {
            guard let range = buffer.range(of: sepLF) ?? buffer.range(of: sepCRLF) else { break }

            let eventData = buffer.subdata(in: 0..<range.lowerBound)
            buffer.removeSubrange(0..<range.upperBound)

            guard let str = String(data: eventData, encoding: .utf8) else { continue }

            for line in str.split(separator: "\n") {
                guard line.hasPrefix("data:") else { continue }

                let payload = String(line.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)

                // End-of-stream from OpenAI-style SSE
                if payload == "[DONE]" {
                    finishIfNeeded()
                    return
                }

                if let jsonData = payload.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: jsonData) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]] {

                    // Prefer streaming delta, fall back to full message if a server sends that
                    if let delta = choices.first?["delta"] as? [String: Any],
                       let content = delta["content"] as? String, !content.isEmpty {
                        let filtered = self.thinkFilter.feed(content)
                        if !filtered.isEmpty {
                            DispatchQueue.main.async { self.onChunk(filtered) }
                        }
                    } else if let message = choices.first?["message"] as? [String: Any],
                              let content = message["content"] as? String, !content.isEmpty {
                        let filtered = self.thinkFilter.feed(content)
                        if !filtered.isEmpty {
                            DispatchQueue.main.async { self.onChunk(filtered) }
                        }
                    }
                }
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error = error {
            // If a network error happens after we already finished, ignore it.
            guard !finished else { return }
            finished = true
            DispatchQueue.main.async { self.onError(error) }
        } else {
            // Connection closed cleanly without an explicit [DONE]
            finishIfNeeded()
        }
    }
}

fileprivate struct ThinkFilter {
    private(set) var inThink = false
    private var pending = ""

    // Markers many "thinking" models use
    private let startTags = ["<|begin_of_thought|>", "<think>", "```thinking", "```thoughts"]
    private let endTags   = ["<|end_of_thought|>",   "</think>", "```"]

    mutating func feed(_ newText: String) -> String {
        pending += newText
        var visible = ""

        while true {
            if inThink {
                if let r = earliestRange(in: pending, of: endTags) {
                    let after = pending[r.upperBound...]
                    pending = String(after)
                    inThink = false
                    continue
                } else {
                    // Keep a small tail to catch boundary-crossing end tags
                    if pending.count > 2048 { pending = String(pending.suffix(512)) }
                    return visible
                }
            } else {
                if let r = earliestRange(in: pending, of: startTags) {
                    // Emit anything before the think-start
                    visible += String(pending[..<r.lowerBound])
                    let after = pending[r.upperBound...]
                    pending = String(after)
                    inThink = true
                    continue
                } else {
                    visible += pending
                    pending.removeAll(keepingCapacity: false)
                    return visible
                }
            }
        }
    }

    private func earliestRange(in s: String, of tags: [String]) -> Range<String.Index>? {
        var best: Range<String.Index>?
        for t in tags {
            if let r = s.range(of: t) {
                if best == nil || r.lowerBound < best!.lowerBound { best = r }
            }
        }
        return best
    }
}
