import AppKit
import SwiftUI

// About panel + in-app updater UI. Single SwiftUI view backed by an Updater
// observable so the state machine drives every label and button without a
// switch in two places.
struct AboutView: View {
    @ObservedObject var updater: Updater
    @ObservedObject var coordinator: AppCoordinator
    @State private var showWhatsNew = false

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 96, height: 96)

            VStack(spacing: 2) {
                Text("Purr")
                    .font(.title2.weight(.semibold))
                HStack(spacing: 8) {
                    Text("Version \(updater.currentVersion)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("What's New") { showWhatsNew = true }
                        .buttonStyle(.link)
                        .font(.callout)
                }
                Text("MIT licensed open source.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Divider()

            updateSection
                .frame(maxWidth: .infinity)

            (Text("Built by ")
                + Text("[Arun Brahma](https://arunbrahma.com)")
                + Text("."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .tint(.secondary)
        }
        .padding(24)
        .frame(width: 380, height: 320)
        .sheet(isPresented: $showWhatsNew) { ChangelogSheet() }
        .onAppear {
            // Quietly check on first open. The user can re-trigger from the
            // button - this just saves a click in the common case.
            if case .idle = updater.state {
                Task { await updater.checkForUpdates() }
            }
        }
    }

    @ViewBuilder
    private var updateSection: some View {
        switch updater.state {
        case .idle:
            Button("Check for Updates") {
                Task { await updater.checkForUpdates() }
            }
            .buttonStyle(.borderedProminent)

        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking for updates…")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

        case .upToDate:
            Label("You're up to date", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout)

        case .available(let version, _, _, let size):
            VStack(spacing: 8) {
                Text("Version \(version) available")
                    .font(.callout.weight(.medium))
                Text(formatSize(size))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Update Purr") {
                    Task { await updater.updatePurr() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!coordinator.safeToQuit)
                if coordinator.safeToQuit {
                    Text("Purr will quit, replace itself, then relaunch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("Finish your current recording before updating.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .multilineTextAlignment(.center)
                }
            }

        case .downloading(let progress):
            VStack(spacing: 6) {
                ProgressView(value: progress)
                    .frame(maxWidth: 240)
                Text("Downloading… \(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .readyToInstall:
            // Transient: updatePurr() flips state -> .installing immediately
            // after .readyToInstall. Shown only if the chained install fails
            // to fire (defensive); the user can retry the same one-click path.
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Preparing installer…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .installing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Installing… the app will relaunch shortly.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

        case .error(let message):
            VStack(spacing: 8) {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
                    .font(.callout)
                    .multilineTextAlignment(.center)
                Button("Try Again") {
                    Task { await updater.checkForUpdates() }
                }
            }
        }
    }

    private func formatSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// The changelog for the installed build, read from the CHANGELOG.md the
// bundle ships (copied into Resources at packaging time), so what the user
// reads always matches the version they run. Rendered with a deliberately
// tiny line-based styler: full markdown fidelity isn't worth a dependency
// for headings and bullets.
private struct ChangelogSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("What's New")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        render(line)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .textSelection(.enabled)
            }
        }
        .frame(width: 480, height: 440)
    }

    private var lines: [String] {
        guard let url = Bundle.main.url(forResource: "CHANGELOG", withExtension: "md"),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else {
            return ["This build doesn't bundle its changelog. See CHANGELOG.md in the repository."]
        }
        // The document title and the format preamble repeat what this sheet
        // already says; the version sections are the content.
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .drop(while: { !$0.hasPrefix("## ") })
            .map { $0 }
    }

    @ViewBuilder
    private func render(_ line: String) -> some View {
        if line.hasPrefix("## ") {
            Text(line.dropFirst(3))
                .font(.title3.weight(.semibold))
                .padding(.top, 4)
        } else if line.hasPrefix("### ") {
            Text(line.dropFirst(4))
                .font(.subheadline.weight(.semibold))
                .padding(.top, 2)
        } else if line.hasPrefix("- ") {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•")
                inlineText(String(line.dropFirst(2)))
            }
        } else if line.hasPrefix("  ") && !line.trimmingCharacters(in: .whitespaces).isEmpty {
            // Continuation of a wrapped bullet: indent under the marker.
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").hidden()
                inlineText(line.trimmingCharacters(in: .whitespaces))
            }
        } else if !line.trimmingCharacters(in: .whitespaces).isEmpty {
            inlineText(line)
        }
    }

    // Inline markdown (bold, links, code) via Foundation's parser; falls back
    // to the raw line when it doesn't parse.
    private func inlineText(_ string: String) -> Text {
        Text(
            (try? AttributedString(markdown: string))
                ?? AttributedString(string)
        )
        .font(.callout)
    }
}
