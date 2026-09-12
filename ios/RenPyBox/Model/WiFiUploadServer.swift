//
//  WiFiUploadServer.swift
//  RenPy Box
//
//  A tiny local HTTP server (NWListener) so games can be uploaded from a
//  computer on the same Wi-Fi. No third-party dependencies.
//

import Foundation
import Network
import UIKit

@objcMembers
final class WiFiUploadServer: NSObject {

    static let shared = WiFiUploadServer()

    private var listener: NWListener?
    private(set) var isRunning = false

    var onStateChange: ((Bool) -> Void)?
    var onText: ((String) -> Void)?       // toast the user in the UI

    var port: UInt16? { listener?.port?.rawValue }

    var addressText: String {
        let ip = Self.localIPAddresses().first ?? "IP unknown"
        return "\(ip):\(port ?? 0)"
    }

    func start() {
        guard listener == nil else { return }

        let params = NWParameters(tcp: NWProtocolTCP.Options())
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true
        let serviceName = UIDevice.current.name.isEmpty ? "RenPy Box" : "RenPy Box on \(UIDevice.current.name)"
        params.service = NWListener.Service(type: "_renpybox._tcp", domain: "local.", name: serviceName)

        let newListener = try? NWListener(using: params, on: 9180)
        guard let listener = newListener, listener.port != nil else {
            // Fallback: system-assigned port.
            guard let alt = try? NWListener(using: params) else {
                onText?("Could not start Wi-Fi server.")
                return
            }
            self.listener = alt
            configure(alt)
            return
        }

        self.listener = listener
        configure(listener)
    }

    private func configure(_ listener: NWListener) {
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.isRunning = true
                self?.onStateChange?(true)
                self?.onText?("Server ready at http://\(self?.addressText ?? "")")
            case .failed(let err):
                self?.onText?("Server failed: \(err.localizedDescription)")
            case .cancelled:
                self?.onStateChange?(false)
            default:
                break
            }
        }
        listener.start(queue: .global(qos: .userInitiated))
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
        onStateChange?(false)
    }

    // MARK: - HTTP handling (only the routes we need)

    private func handle(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .userInitiated))
        var buffer = Data()
        var requestLine: String?
        var contentLength = 0
        var headersDone = false
        var body = Data()
        var path = "/"

        func pump() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                guard let self else {
                    connection.cancel()
                    return
                }
                if let data = data { buffer.append(data) }

                // Parse request line + headers.
                if !headersDone, let range = buffer.range(of: Data("\r\n\r\n".utf8)) {
                    let head = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                    buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                    headersDone = true
                    let lines = String(data: head, encoding: .utf8)?.components(separatedBy: "\r\n") ?? []
                    requestLine = lines.first
                    if let line = lines.first(where: { $0.lowercased().hasPrefix("content-length:") }) {
                        contentLength = Int(line.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) ?? 0
                    }
                }

                // Decode the path once we have the request line.
                if path == "/", let line = requestLine {
                    let parts = line.split(separator: " ")
                    if parts.count >= 2 { path = String(parts[1]) }
                }

                // Accumulate the body.
                if headersDone, contentLength > 0, buffer.count <= contentLength {
                    body.append(buffer)
                    buffer.removeAll()
                }

                let httpDone = error != nil || isComplete
                if headersDone, (body.count >= contentLength || httpDone) {
                    self.respond(connection: connection, path: path, body: body)
                    return
                }

                if error != nil {
                    connection.cancel()
                    return
                }
                pump()
            }
        }
        pump()
    }

    private func respond(connection: NWConnection, path: String, body: Data) {
        var status = 200
        var mime = "text/html; charset=utf-8"
        var extraHeaders = ""
        var payload: Data

        if path == "/" || path == "" {
            payload = Data(Self.indexPage.utf8)
        } else if path.hasPrefix("/games") {
            let names = RenPyBoxGameLauncher.store.games.map {
                ["id": $0.id, "name": $0.name, "saves": Self.saveCount($0)]
            }
            payload = Self.json(names)
        } else if path.hasPrefix("/upload") {
            payload = Self.handleUpload(path: path, body: body)
        } else if path.hasPrefix("/saves/") {
            let result = Self.handleSaveRequest(path: path)
            if result.isError {
                status = 404
                payload = Data("{\"error\":\"not found\"}".utf8)
                mime = "application/json"
            } else {
                payload = result.data
                mime = result.mime ?? "application/octet-stream"
                if let filename = result.filename {
                    extraHeaders = "Content-Disposition: attachment; filename=\"\(filename)\"\r\n"
                }
            }
        } else {
            status = 404
            payload = Data("not found".utf8)
        }

        let header = "HTTP/1.1 \(status)\r\n" +
                     "Content-Type: \(mime)\r\n" +
                     "Content-Length: \(payload.count)\r\n" +
                     extraHeaders +
                     "Connection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(payload)

        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: Upload

    private static func handleUpload(path: String, body: Data) -> Data {
        // Name passed as query param.
        let decoded = path.removingPercentEncoding ?? ""
        let name = decoded
            .components(separatedBy: "&")
            .first { $0.lowercased().hasPrefix("name=") }?
            .replacingOccurrences(of: "name=", with: "", options: [.caseInsensitive])
            ?? "game.zip"

        let fm = FileManager.default
        try? fm.createDirectory(at: GamePaths.inboxDirectory, withIntermediateDirectories: true)
        let safe = name.components(separatedBy: CharacterSet(charactersIn: "/\\:")).joined()
        let target = GamePaths.inboxDirectory.appendingPathComponent(safe)
        do {
            try body.write(to: target, options: .atomic)
        } catch {
            return Self.json(["ok": false, "error": "write failed"])
        }

        do {
            var progress = 0.0
            let game = try GameImporter.importSource(at: target) { p in progress = p }
            try? fm.removeItem(at: target)
            let store = RenPyBoxGameLauncher.store
            DispatchQueue.main.async { store.refresh() }
            return Self.json(["ok": true, "id": game.id, "name": game.name])
        } catch {
            try? fm.removeItem(at: target)
            return Self.json(["ok": false, "error": (error as? LocalizedError)?.errorDescription ?? "\(error)"])
        }
    }

    private static func saveCount(_ game: RenPyGame) -> Int {
        RenPyBoxGameLauncher.store.saves(for: game).count
    }

    // MARK: Saves download

    private static func handleSaveRequest(path: String) -> (data: Data, mime: String?, filename: String?, isError: Bool) {
        let parts = path.split(separator: "/").map(String.init)
        // /saves/<gameId>/<filename>
        guard parts.count >= 3 else { return (Data(), nil, nil, true) }
        let gameId = parts[1]
        let filename = parts.dropFirst(2).joined(separator: "/").removingPercentEncoding ?? ""

        guard let game = RenPyBoxGameLauncher.store.games.first(where: { $0.id == gameId }) else {
            return (Data(), nil, nil, true)
        }
        // Reject path traversal.
        guard !filename.contains("..") else { return (Data(), nil, nil, true) }

        let dirs = [game.savesDirectory,
                    GamePaths.documentsDirectory.appendingPathComponent("\(game.id)/saves", isDirectory: true)]
        let safeName = (filename as NSString).lastPathComponent

        for dir in dirs {
            let url = dir.appendingPathComponent(safeName)
            if let data = try? Data(contentsOf: url), !data.isEmpty {
                return (data, "application/octet-stream", safeName, false)
            }
        }
        return (Data(), nil, nil, true)
    }

    // MARK: Helpers

    static func json(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    static func localIPAddresses() -> [String] {
        var addresses: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return [] }
        defer { freeifaddrs(ifaddr) }

        var ptr = ifaddr
        while let p = ptr {
            let interface = p.pointee
            let family = interface.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET) {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let sock = interface.ifa_addr.withMemoryRebound(to: sockaddr.self, capacity: 1) { $0 }
                if getnameinfo(sock, socklen_t(interface.ifa_addr.pointee.sa_len),
                               &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: host)
                    if ip != "127.0.0.1" {
                        addresses.append(ip)
                    }
                }
            }
            ptr = interface.ifa_next
        }
        return addresses
    }

    private static let indexPage = """
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>RenPy Box - Upload</title>
      <style>
        body { font-family: -apple-system, sans-serif; max-width: 640px; margin: 2em auto; padding: 0 1em; color: #222; }
        h1 { font-size: 1.4em; }
        input[type=file] { width: 100%; padding: .6em; border: 1px dashed #bbb; border-radius: 8px; }
        #log { margin-top: 1em; font-size: .9em; white-space: pre-wrap; }
        ul { padding-left: 1.2em; }
        li { margin: .4em 0; }
      </style>
    </head>
    <body>
      <h1>RenPy Box · Upload games</h1>
      <p>Select Ren'Py game archives (ZIP, TAR, TGZ). They will appear in your library.</p>
      <input type="file" id="files" multiple accept=".zip,.tar,.gz,.tgz,.renpy">
      <div id="log"></div>
      <h2>Browsing saves</h2>
      <ul id="games"></ul>
      <script>
        const log = document.getElementById('log');
        document.getElementById('files').addEventListener('change', async (ev) => {
          for (const f of ev.target.files) {
            log.textContent += `Uploading ${f.name} (${(f.size/1048576).toFixed(1)} MB)...\\n`;
            try {
              const r = await fetch('/upload?name=' + encodeURIComponent(f.name), { method: 'POST', body: f });
              const j = await r.json();
              if (j.ok) log.textContent += `OK: ${j.name}\\n`;
              else log.textContent += `FAILED: ${j.error}\\n`;
            } catch (e) { log.textContent += `FAILED: ${e}\\n`; }
            refreshGames();
          }
        });
        async function refreshGames() {
          const r = await fetch('/games');
          const games = await r.json();
          const ul = document.getElementById('games');
          ul.innerHTML = '';
          for (const g of games) {
            const li = document.createElement('li');
            li.textContent = `${g.name} (${g.saves} saves)`;
            ul.appendChild(li);
          }
        }
        refreshGames();
      </script>
    </body>
    </html>
    """
}