import SwiftUI

/// Browse the user's recordings (pulled from R2) and the articles mined from
/// them. Presented as a sheet from the record screen — the record flow itself
/// is never blocked by this.
struct LibraryView: View {
    @State private var store = LibraryStore()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if store.loading && store.recordings.isEmpty {
                    ProgressView().tint(.white)
                } else if let err = store.error, store.recordings.isEmpty {
                    message("加载失败", err)
                } else if store.recordings.isEmpty {
                    message("还没有录音", "录一条，过会儿服务器会自动转写并挖成文章。")
                } else {
                    List(store.recordings) { rec in
                        NavigationLink {
                            RecordingDetailView(store: store, recording: rec)
                        } label: {
                            row(rec)
                        }
                        .listRowBackground(Color.white.opacity(0.04))
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                    .refreshable { await store.load() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("我的录音")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }.tint(.white)
                }
            }
            .toolbarBackground(Color.black, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
        .preferredColorScheme(.dark)
        .task { await store.load() }
    }

    private func row(_ rec: Recording) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform")
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(rec.displayTitle).foregroundStyle(.white).font(.callout.weight(.medium))
                HStack(spacing: 8) {
                    if let d = rec.durationLabel {
                        Text(d).foregroundStyle(.white.opacity(0.4)).font(.caption2.monospaced())
                    }
                    if rec.hasArticles {
                        Label("已成文", systemImage: "doc.text")
                            .foregroundStyle(.green.opacity(0.85)).font(.caption2)
                    } else {
                        Text("待处理").foregroundStyle(.orange.opacity(0.8)).font(.caption2)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func message(_ title: String, _ subtitle: String) -> some View {
        VStack(spacing: 10) {
            Text(title).foregroundStyle(.white.opacity(0.8)).font(.headline)
            Text(subtitle).foregroundStyle(.white.opacity(0.45)).font(.callout)
                .multilineTextAlignment(.center).padding(.horizontal, 40)
        }
    }
}
