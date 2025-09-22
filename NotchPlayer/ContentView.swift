import SwiftUI
import AppKit

// MARK: - Bridge: reads values from PlayerView via KVC and sends commands back
final class PlayerBridge: ObservableObject {
    weak var player: PlayerView?

    // UI state
    @Published var isPaused: Bool = true
    @Published var isLooping: Bool = true

    // KVC reads
    var currentTime: Double { (player?.value(forKey: "currentPTS") as? Double) ?? 0 }
    var duration: Double    { (player?.value(forKey: "duration")  as? Double) ?? .nan }
    var fps: Double         { (player?.value(forKey: "fps")       as? Double) ?? 30.0 }

    // Commands
    func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.movie, .mpeg4Movie, .quickTimeMovie]
        if panel.runModal() == .OK, let url = panel.url {
            player?.openAndPlay(url: url)  // NotchLC gate happens inside PlayerView
            isPaused = false
        }
    }

    func playPause() {
        guard let p = player else { return }
        if isPaused {
            if !(p.isStopped) { p.resume() } else { p.play() }
            isPaused = false
        } else {
            p.pause()
            isPaused = true
        }
    }

    func stop() {
        player?.stopPlayback()   // PlayerView.stop() is private; use stopPlayback()
        isPaused = true
    }

    func applyLooping() {
        player?.isLooping = isLooping
    }
}

// MARK: - Timecode formatting (mm:ss.ff frames)
fileprivate func formatTimecode(_ seconds: Double, fps: Double) -> String {
    guard seconds.isFinite, seconds >= 0, fps > 0 else { return "--:--" }
    let framesPerSecond = Int(round(fps))                 // integer frames for display
    let totalFrames = Int((seconds * fps).rounded())      // snap to nearest frame
    let frames = totalFrames % framesPerSecond
    let totalSeconds = totalFrames / framesPerSecond
    let secs = totalSeconds % 60
    let mins = totalSeconds / 60
    return String(format: "%02d:%02d.%02d", mins, secs, frames)
}

// MARK: - NSViewRepresentable that hosts PlayerView and wires the bridge
struct PlayerContainer: NSViewRepresentable {
    @ObservedObject var bridge: PlayerBridge

    func makeNSView(context: Context) -> PlayerView {
        let v = PlayerView(frame: .zero)
        bridge.player = v
        // Push initial loop state
        v.isLooping = bridge.isLooping
        return v
    }

    func updateNSView(_ nsView: PlayerView, context: Context) {
        // Keep PlayerView’s looping in sync with the toggle
        nsView.isLooping = bridge.isLooping
    }
}

// MARK: - Checkerboard background
struct CheckerboardView: View {
    var body: some View {
        GeometryReader { geo in
            let size = 12.0
            let cols = Int(ceil(geo.size.width / size))
            let rows = Int(ceil(geo.size.height / size))
            Canvas { ctx, _ in
                for y in 0..<rows {
                    for x in 0..<cols {
                        let dark = (x + y) % 2 == 0
                        let rect = CGRect(x: Double(x) * size,
                                          y: Double(y) * size,
                                          width: size, height: size)
                        ctx.fill(Path(rect),
                                 with: .color(dark ? .gray.opacity(0.35) : .gray.opacity(0.15)))
                    }
                }
            }
        }
        .drawingGroup()
    }
}

// MARK: - Main view
struct ContentView: View {
    @StateObject private var bridge = PlayerBridge()
    // 30 Hz UI tick (instead of timelineSchedule)
    @State private var tick = 0
    private let timer = Timer.publish(every: 1.0/30.0, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                CheckerboardView()
                    .ignoresSafeArea(edges: .horizontal)

                PlayerContainer(bridge: bridge)
            }
            .frame(minWidth: 320, minHeight: 180)

            controlsBar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        // UI refresh
        .onReceive(timer) { _ in tick &+= 1 }
    }

    private var controlsBar: some View {
        VStack(spacing: 8) {
            // Time + progress
            HStack {
                Text(formatTimecode(bridge.currentTime, fps: bridge.fps))
                    .monospacedDigit()

                Slider(value: .constant(progressValue), in: 0...1)
                    .disabled(true)

                Text(formatTimecode(bridge.duration, fps: bridge.fps))
                    .monospacedDigit()
            }

            // Transport
            HStack(spacing: 12) {
                Button {
                    bridge.openFile()
                } label: {
                    Label("Open…", systemImage: "folder")
                }

                Button {
                    bridge.playPause()
                } label: {
                    Image(systemName: bridge.isPaused ? "play.fill" : "pause.fill")
                }
                .keyboardShortcut(.space, modifiers: [])

                Button {
                    bridge.stop()
                } label: {
                    Image(systemName: "stop.fill")
                }

                Divider().frame(height: 18)

                Toggle(isOn: $bridge.isLooping) {
                    Text("Loop")
                }
                .onChange(of: bridge.isLooping) { _, _ in bridge.applyLooping() }
                .toggleStyle(.switch)

                Spacer()

                Text("\(Int(round(bridge.fps))) fps")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var progressValue: Double {
        let d = bridge.duration
        guard d.isFinite, d > 0 else { return 0 }
        return min(max(bridge.currentTime / d, 0), 1)
    }
}
