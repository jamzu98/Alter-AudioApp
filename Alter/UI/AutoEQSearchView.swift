import SwiftUI

struct AutoEQSearchView: View {
    @Environment(\.dismiss) private var dismiss
    let onPick: (EQPreset) -> Void

    @State private var query = ""
    @State private var results: [AutoEQClient.Entry] = []
    @State private var loading = false
    @State private var downloading: String?
    @State private var error: String?
    @State private var indexCount = 0
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AutoEQ Database").font(.title3.weight(.semibold))
                    Text("Correction profiles from github.com/jaakkopasanen/AutoEq. Pick the measurement source you trust; oratory1990 is a common first choice for over-ear headphones.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            HStack {
                TextField("Search headphones, e.g. HD 600", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: query) { _, _ in scheduleSearch() }
                    .onSubmit { scheduleSearch(immediate: true) }
                if loading { ProgressView().controlSize(.small) }
                Button {
                    Task { await refreshIndex() }
                } label: { Image(systemName: "arrow.clockwise") }
                .help("Download the latest AutoEQ index")
            }

            List(results) { entry in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.name)
                        Text(entry.sourceDescription).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if downloading == entry.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Add") { Task { await download(entry) } }
                            .disabled(downloading != nil)
                    }
                }
                .padding(.vertical, 2)
            }
            .overlay {
                if results.isEmpty && !loading {
                    Text(query.isEmpty ? "Type to search \(indexCount > 0 ? "\(indexCount) profiles" : "the AutoEQ database")." : "No matches.")
                        .foregroundStyle(.secondary)
                }
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(16)
        .frame(width: 520, height: 520)
        .task {
            if let all = try? await AutoEQClient.shared.index() { indexCount = all.count }
        }
    }

    private func scheduleSearch(immediate: Bool = false) {
        searchTask?.cancel()
        let q = query
        searchTask = Task {
            if !immediate { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            loading = true
            defer { loading = false }
            do {
                let found = try await AutoEQClient.shared.search(q)
                guard !Task.isCancelled else { return }
                results = Array(found.prefix(200))
                indexCount = max(indexCount, found.count)
                error = nil
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func refreshIndex() async {
        loading = true
        defer { loading = false }
        do {
            indexCount = try await AutoEQClient.shared.index(refresh: true).count
            scheduleSearch(immediate: true)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func download(_ entry: AutoEQClient.Entry) async {
        downloading = entry.id
        defer { downloading = nil }
        do {
            let preset = try await AutoEQClient.shared.download(entry)
            onPick(preset)
            dismiss()
        } catch {
            self.error = "Could not download \(entry.name): \(error.localizedDescription)"
        }
    }
}
