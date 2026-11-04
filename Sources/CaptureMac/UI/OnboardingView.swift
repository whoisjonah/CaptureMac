import AVFoundation
import Combine
import SwiftUI

struct OnboardingView: View {
    let onFinish: () -> Void

    @State private var preferences = Preferences.shared
    @State private var screenGranted = CGPreflightScreenCaptureAccess()
    @State private var microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var audioRequested = false

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            hero

            VStack(spacing: 10) {
                step(
                    symbol: "rectangle.dashed.badge.record",
                    title: "Screen Recording",
                    detail: "Needed to capture games and windows.",
                    done: screenGranted,
                    action: "Allow"
                ) {
                    if !CGRequestScreenCaptureAccess() {
                        if let settings = URL(
                            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
                        {
                            NSWorkspace.shared.open(settings)
                        }
                    }
                }
                step(
                    symbol: "speaker.wave.2",
                    title: "System Audio",
                    detail: "So clips include game sound.",
                    done: audioRequested,
                    action: "Allow"
                ) {
                    _ = try? ProcessTap(scope: .everything, seconds: 1)
                    audioRequested = true
                }
                step(
                    symbol: "mic",
                    title: "Microphone",
                    detail: "Optional, for your voice.",
                    done: microphoneStatus == .authorized,
                    action: "Allow"
                ) {
                    Task {
                        _ = await Microphone.requestAccess()
                        microphoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                        if microphoneStatus == .authorized { preferences.microphoneEnabled = true }
                    }
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)

            Spacer(minLength: 16)

            VStack(spacing: 10) {
                Button {
                    preferences.onboarded = true
                    onFinish()
                    Recorder.shared.start()
                } label: {
                    Text("Get started")
                        .font(.body.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                }
                .buttonStyle(ActionButtonStyle(fill: Brand.blue))
                .disabled(!screenGranted)

                if !screenGranted {
                    Text("If you just allowed Screen Recording, macOS may ask you to reopen CaptureMac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if let save = preferences.saveShortcut, let record = preferences.recordShortcut {
                    Text("\(save.display) saves a clip, \(record.display) starts a recording")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 24)
        }
        .frame(width: 480, height: 600)
        .background(Brand.paper)
        .tint(Brand.blue)
        .onReceive(timer) { _ in
            screenGranted = CGPreflightScreenCaptureAccess()
        }
    }

    private var hero: some View {
        VStack(spacing: 14) {
            ViewfinderMark(frameColor: .white, dotColor: .white)
                .frame(width: 64, height: 64)
            VStack(spacing: 4) {
                Text("CaptureMac")
                    .font(.system(size: 30, weight: .bold))
                Text(Brand.slogan)
                    .font(.title3)
                    .opacity(0.85)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity)
        .padding(.top, 58)
        .padding(.bottom, 32)
        .background(Brand.gradient)
    }

    private func step(
        symbol: String, title: String, detail: String, done: Bool, action: String, perform: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Brand.blue)
                .frame(width: 36, height: 36)
                .background(Brand.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.body.weight(.semibold))
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if done {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)
            } else {
                Button(action, action: perform)
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(Card())
    }
}
