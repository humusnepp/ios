//
//  WiFiTransferView.swift
//  RenPy Box
//

import SwiftUI

struct WiFiTransferView: View {
    @EnvironmentObject var store: GameLibraryStore
    @Environment(\.dismiss) private var dismiss

    @State private var running = false
    @State private var statusText = "Starting…"

    private let server = WiFiUploadServer.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: running ? "wifi" : "wifi.slash")
                    .font(.system(size: 60))
                    .foregroundStyle(running ? Color.green : Color.secondary)

                Text(running ? "Server active" : "Server stopped")
                    .font(.title3.bold())

                if running {
                    Text("On your computer, open this address in a browser,\nthen select the game archives to upload:")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)

                    Text("http://\(server.addressText)")
                        .font(.system(.title2, design: .monospaced).bold())
                        .padding(14)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))

                    Text("Make sure your computer is on the same Wi-Fi network.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(statusText)
                        .foregroundStyle(.secondary)
                }

                Button(running ? "Stop server" : "Start server") {
                    if running { server.stop() } else { server.start() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
            .padding(32)
            .navigationTitle("Wi-Fi Transfer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .onAppear {
                server.onStateChange = { running = $0 }
                server.onText = { statusText = $0 }
                running = server.isRunning
                if !running { statusText = "Idle" }
            }
            .onDisappear {
                server.onStateChange = nil
                server.onText = nil
            }
        }
    }
}