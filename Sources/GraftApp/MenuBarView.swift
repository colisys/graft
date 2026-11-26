import SwiftUI
import AppKit
import GraftCore

struct MenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var environment: EnvironmentManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            statusBlock

            if let busyMessage = model.busyMessage {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busyMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Divider().opacity(0.6)
            appsSection
            Divider().opacity(0.6)
            footer
        }
        .padding(16)
        .frame(width: 340)
        .task { await model.refresh() }
        .alert("出错了", isPresented: $model.showingError) {
            if model.shouldOfferRuntimeRecovery {
                Button("启动运行环境") {
                    Task { await model.requestStartRuntime() }
                }
            }
            Button("好", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "未知错误")
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up.fill")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 1) {
                Text("Graft")
                    .font(.headline)
                Text(environment.baseImage.displayName)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if environment.activeSessionCount > 0 {
                Text("\(environment.activeSessionCount) 个运行中")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.plain)
            .help("退出 Graft")
        }
    }

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                Text("Colima \(environment.colimaState.displayName)")
                    .font(.subheadline.weight(.medium))
                Spacer()
                if let memory = environment.stats.containerMemory {
                    Text(memory)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                Button(environment.colimaState == .running ? "休眠" : "启动") {
                    Task {
                        if environment.colimaState == .running {
                            await model.suspendRuntime()
                        } else {
                            await model.requestStartRuntime()
                        }
                    }
                }
                .controlSize(.small)
                .disabled(model.isBusy)

                Button("刷新") {
                    Task { await model.refresh() }
                }
                .controlSize(.small)
                .disabled(model.isBusy)

                Button("管理窗口") {
                    model.showManagementWindow()
                }
                .controlSize(.small)

                Spacer()
            }
        }
        .padding(12)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("已封装应用")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(model.wrappedApps.count)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if model.wrappedApps.isEmpty {
                Text("还没有应用。打开「管理窗口」一键安装 VS Code、Firefox 等 Linux 软件。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(model.wrappedApps.prefix(10)) { app in
                            appRow(app)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
    }

    private func appRow(_ app: WrappedApp) -> some View {
        HStack(spacing: 8) {
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.bundleURL.path))
                .resizable()
                .frame(width: 18, height: 18)
            Text(app.name)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button {
                model.launch(app)
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(.borderless)
            .help("启动 \(app.name)")
        }
        .contentShape(Rectangle())
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("打开管理窗口") {
                model.showManagementWindow()
            }
            .buttonStyle(.plain)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))

            Spacer()

            Button("退出") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .font(.caption2)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
    }

    private var statusColor: Color {
        switch environment.colimaState {
        case .running: return .green
        case .starting: return .orange
        case .stopped: return .secondary
        case .notInstalled: return .red
        case .unknown: return .gray
        }
    }
}
