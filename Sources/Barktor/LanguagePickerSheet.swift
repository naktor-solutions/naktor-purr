import SwiftUI

// Modal sheet for picking the source language for Whisper translation. A
// compact settings row can't host a 100-item list, so we pop a dedicated
// picker that owns the search interaction. This matches what macOS System
// Settings uses for similar long lists (Language & Region, Input Sources).
struct LanguagePickerSheet: View {
    @Binding var selection: String
    let onClose: () -> Void

    @State private var query: String = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            searchField
            Divider()
            languageList
        }
        .frame(width: 380, height: 460)
        .onAppear { searchFocused = true }
    }

    private var header: some View {
        HStack {
            Text("Source Language").font(.headline)
            Spacer()
            Button("Done") { onClose() }
                .keyboardShortcut(.defaultAction)
        }
        .padding()
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search", text: $query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Clear search")
            }
        }
        .padding(8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var languageList: some View {
        if items.isEmpty {
            VStack {
                Spacer()
                Text("No language matches \"\(query)\".")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(items) { language in
                        Button {
                            selection = language.code
                            onClose()
                        } label: {
                            HStack {
                                Text(language.name)
                                Spacer()
                                if language.code == selection {
                                    Image(systemName: "checkmark").foregroundStyle(.tint)
                                }
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 8)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().padding(.leading)
                    }
                }
            }
        }
    }

    // With an empty search, lead with Auto-detect so users can find it as
    // easily as any specific language. While searching, defer to the
    // ranked matcher (which deliberately omits Auto-detect from results);
    // clearing the search restores it.
    private var items: [WhisperLanguage] {
        if query.trimmingCharacters(in: .whitespaces).isEmpty {
            return WhisperLanguage.all
        }
        return WhisperLanguage.matching(query)
    }
}
