import SwiftUI
import PIiOSCore

struct SkillsScreen: View {
    @EnvironmentObject private var connection: ConnectionModel

    @State private var skills: [RACPV2Skill] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var showingInstall = false
    @State private var sourceType = "git"
    @State private var sourceValue = ""
    @State private var subdir = ""
    @State private var ref = ""
    @State private var replace = false
    @State private var pendingDelete: RACPV2Skill?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PISpacing.s16) {
                if !connection.state.isOnline {
                    PIStatusBanner(
                        kind: .warning,
                        text: "Host 未连接",
                        detail: "连接后可读取服务器上的全局 Skill。"
                    )
                }
                if let error {
                    PIStatusBanner(kind: .danger, text: "Skill 操作失败", detail: error)
                }
                PIGroup("已安装", footer: "Skill 复制到 Host 全局目录；运行中的 turn 固定使用启动时版本。") {
                    if isLoading {
                        PIListRow(title: "正在读取…", isEnabled: false, showsDivider: false)
                    } else if skills.isEmpty {
                        PIListRow(title: "还没有全局 Skill", subtitle: "点击右上角安装", isEnabled: false, showsDivider: false)
                    } else {
                        ForEach(Array(skills.enumerated()), id: \.element.id) { index, skill in
                            PIListRow(
                                title: skill.name,
                                subtitle: "\(skill.description) · \(skill.status)",
                                showsChevron: false,
                                showsDivider: index < skills.count - 1
                            ) {
                                Button("删除", role: .destructive) { pendingDelete = skill }
                                    .font(PIFont.captionStrong)
                            }
                        }
                    }
                }
                PIGroup("安装来源") {
                    Picker("来源类型", selection: $sourceType) {
                        Text("公开 Git").tag("git")
                        Text("服务器目录").tag("directory")
                    }
                    .pickerStyle(.segmented)
                    PIFormField(label: sourceType == "git" ? "Git URL" : "服务器目录") {
                        TextField(
                            sourceType == "git" ? "https://github.com/…" : "/home/user/skills/demo",
                            text: $sourceValue
                        )
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    }
                    PIFormField(label: "子目录（可选）") {
                        TextField("skills/demo", text: $subdir)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    if sourceType == "git" {
                        PIFormField(label: "branch / tag / commit（可选）") {
                            TextField("main", text: $ref)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }
                    }
                    Toggle("同名覆盖", isOn: $replace)
                    Button("安装 Skill") { Task { await install() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!connection.state.isOnline || sourceValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(.horizontal, PIMetrics.pageMargin)
            .padding(.vertical, PISpacing.s16)
        }
        .piPageBackground()
        .navigationTitle("全局 Skill")
        .navigationBarTitleDisplayMode(.inline)
        .task { await reload() }
        .refreshable { await reload() }
        .confirmationDialog(
            "删除 Skill？",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible
        ) {
            Button("删除安装副本", role: .destructive) {
                if let skill = pendingDelete { Task { await delete(skill) } }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只删除 Host 的安装副本，不修改来源仓库或来源目录。")
        }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            skills = try await connection.listHostSkills()
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func install() async {
        let value = sourceValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var source: [String: JSONValue] = ["type": .string(sourceType)]
        if sourceType == "git" {
            source["url"] = .string(value)
            if !subdir.isEmpty { source["subdir"] = .string(subdir) }
            if !ref.isEmpty { source["ref"] = .string(ref) }
        } else {
            source["path"] = .string(value)
            if !subdir.isEmpty { source["subdir"] = .string(subdir) }
        }
        do {
            _ = try await connection.installHostSkill(source: .object(source), replace: replace)
            sourceValue = ""
            subdir = ""
            ref = ""
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func delete(_ skill: RACPV2Skill) async {
        do {
            try await connection.deleteHostSkill(id: skill.id)
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
