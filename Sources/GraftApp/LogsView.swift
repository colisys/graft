import SwiftUI
import GraftCore

struct LogsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var log: LogStore
    @State private var follow = true

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Toggle("自动滚动", isOn: $follow)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Toggle("记录日志", isOn: $log.isRecording)
                    .toggleStyle(.switch)
                    .controlSize(.small)

                Spacer()

                Text("\(log.entries.count) 行")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                Button {
                    model.clearLogs()
                } label: {
                    Label("清空", systemImage: "trash")
                }
                .controlSize(.small)
                .disabled(log.entries.isEmpty || model.isBusy || model.isActionPending)

                Button {
                    model.exportLogs()
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
                .controlSize(.small)
                .disabled(model.isBusy || model.isActionPending)
            }
            .padding(12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.primary.opacity(0.07), lineWidth: 1)
            }

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(log.entries) { entry in
                            LogRow(entry: entry)
                                .id(entry.id)
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(.primary.opacity(0.07), lineWidth: 1)
                }
                .onChange(of: log.entries.count) { _ in
                    guard follow, let last = log.entries.last else { return }
                    withAnimation(.easeOut(duration: 0.12)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            Text("文件日志：\(LogStore.logFileURL.path)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(LogStore.logFileURL.path)
        }
        .padding(EdgeInsets(top: 0, leading: 22, bottom: 22, trailing: 22))
    }
}

private struct LogRow: View {
    let entry: LogStore.Entry

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Text(Self.timeFormatter.string(from: entry.date))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
            Text(entry.text)
                .font(.caption.monospaced())
                .foregroundStyle(color)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 1)
    }

    private var color: Color {
        switch entry.level {
        case .error: return .red
        case .warning: return .orange
        case .success: return .green
        case .command: return .blue
        case .info: return .primary
        }
    }
}
