import SwiftUI

enum QXCenterSection: String, CaseIterable, Identifiable {
    case routing = "代理与分源路由"
    case scripts = "QX脚本与重写"
    case logs = "实时命中日志"

    var id: String { rawValue }
}

struct QuantumultXCenterView: View {
    @Environment(QuantumultXEngine.self) private var qx

    @State private var activeSection: QXCenterSection = .routing
    @State private var isShowingAddNodeSheet: Bool = false
    @State private var isShowingAddScriptSheet: Bool = false
    @State private var isShowingImportConfSheet: Bool = false
    @State private var editingScript: QXScriptRule? = nil

    var body: some View {
        VStack(spacing: 0) {
            // 顶部单层液态玻璃切换栏
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(QXCenterSection.allCases) { sec in
                        GlassPillButton(
                            title: sec.rawValue,
                            isSelected: activeSection == sec,
                            activeColor: .orange,
                            minHeight: 36
                        ) {
                            withAnimation(.snappy) {
                                activeSection = sec
                            }
                        }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .glassEffect(.regular, in: .rect(cornerRadius: 18))
            }
            .padding(.horizontal, 12)
            .padding(.top, 6)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch activeSection {
                    case .routing:
                        routingAndNodesSection
                    case .scripts:
                        scriptsAndRewriteSection
                    case .logs:
                        trafficLogsSection
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 120)
            }
        }
        .background(Color(red: 0.06, green: 0.07, blue: 0.09).ignoresSafeArea())
        .navigationTitle("内部代理与 Quantumult X")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isShowingAddNodeSheet) {
            AddQXProxyNodeSheet()
        }
        .sheet(isPresented: $isShowingAddScriptSheet) {
            EditQXScriptRuleSheet(rule: nil)
        }
        .sheet(item: $editingScript) { rule in
            EditQXScriptRuleSheet(rule: rule)
        }
        .sheet(isPresented: $isShowingImportConfSheet) {
            ImportQXConfigSheet()
        }
    }

    // MARK: - 1. 代理模式、分书源独立代理与节点管理
    private var routingAndNodesSection: some View {
        @Bindable var bindableQX = qx

        return VStack(alignment: .leading, spacing: 18) {
            // 总开关与运行说明
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("启用软件内部代理路由")
                            .font(.system(size: 16, weight: .bold))
                        Text("仅接管 DSNovel 内部请求，不创建系统 VPN，不影响其他软件")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("", isOn: $bindableQX.isProxyEnabled)
                        .labelsHidden()
                        .tint(.orange)
                }

                Divider().overlay(Color.white.opacity(0.08))

                Text("代理路由模式")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    ForEach(InAppProxyMode.allCases) { mode in
                        GlassPillButton(
                            title: mode.rawValue,
                            isSelected: qx.proxyMode == mode,
                            activeColor: .orange,
                            minHeight: 36
                        ) {
                            qx.proxyMode = mode
                            if mode != .direct {
                                qx.isProxyEnabled = true
                            }
                        }
                    }
                }

                Text(qx.proxyMode.subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange.opacity(0.9))
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(red: 0.11, green: 0.12, blue: 0.15)))

            // 分书源单独代理配置卡片（喜马拉雅 / 番茄畅听 各自独立选择直连或任意节点）
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("分书源单独代理策略（喜马拉雅 / 番茄畅听）", systemImage: "arrow.triangle.branch")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.orange)
                    Spacer()
                }

                ForEach(CoreSourceID.allCases) { source in
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            Image(systemName: source.iconName)
                                .foregroundStyle(.white)
                                .frame(width: 28, height: 28)
                                .background(RoundedRectangle(cornerRadius: 8).fill(source.brandColor))

                            Text("\(source.displayName) 独立代理通道")
                                .font(.system(size: 14, weight: .bold))

                            Spacer()

                            Text("当前生效：\(qx.routeDescription(for: source))")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.green)
                        }

                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                let currentSel = qx.sourceNodeIdMap[source] ?? "DIRECT"

                                GlassPillButton(
                                    title: "直连 (DIRECT)",
                                    isSelected: currentSel == "DIRECT",
                                    activeColor: .green,
                                    minHeight: 32
                                ) {
                                    qx.sourceNodeIdMap[source] = "DIRECT"
                                }

                                GlassPillButton(
                                    title: "跟随全局主节点",
                                    isSelected: currentSel == "GLOBAL",
                                    activeColor: .orange,
                                    minHeight: 32
                                ) {
                                    qx.sourceNodeIdMap[source] = "GLOBAL"
                                    qx.proxyMode = .splitBySource
                                    qx.isProxyEnabled = true
                                }

                                ForEach(qx.nodes) { node in
                                    GlassPillButton(
                                        title: node.tag,
                                        isSelected: currentSel == node.id,
                                        activeColor: source.brandColor,
                                        minHeight: 32
                                    ) {
                                        qx.sourceNodeIdMap[source] = node.id
                                        qx.proxyMode = .splitBySource
                                        qx.isProxyEnabled = true
                                    }
                                }
                            }
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.04)))
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(red: 0.11, green: 0.12, blue: 0.15)))

            // 代理节点列表（软件内全局主节点选择 + 延迟测速 + 添加/导入节点）
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("代理服务器节点 ([server_local])", systemImage: "server.rack")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(.orange)
                    Spacer()

                    GlassPillButton(title: "导入QX配置", icon: "square.and.arrow.down", isSelected: false, minHeight: 32) {
                        isShowingImportConfSheet = true
                    }

                    GlassPillButton(title: "新增节点", icon: "plus", isSelected: true, activeColor: .orange, minHeight: 32) {
                        isShowingAddNodeSheet = true
                    }
                }

                ForEach(qx.nodes) { node in
                    let isGlobalSelected = (qx.selectedGlobalNodeId == node.id)
                    HStack(spacing: 12) {
                        Button {
                            qx.selectedGlobalNodeId = node.id
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: isGlobalSelected ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 18))
                                    .foregroundStyle(isGlobalSelected ? .orange : .secondary)

                                VStack(alignment: .leading, spacing: 3) {
                                    HStack(spacing: 6) {
                                        Text(node.tag)
                                            .font(.system(size: 14, weight: .bold))
                                            .foregroundStyle(.primary)
                                        if isGlobalSelected {
                                            Text("全局主节点")
                                                .font(.system(size: 9.5, weight: .bold))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(Capsule().fill(Color.orange))
                                        }
                                    }
                                    Text(node.summaryText)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(ResponsivePressButtonStyle())

                        if let ms = node.lastLatencyMs {
                            Text(ms > 0 ? "\(ms) ms" : "超时")
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .foregroundStyle(ms > 0 ? .green : .orange)
                        }

                        GlassPillButton(title: "测速", icon: "bolt.fill", isSelected: false, minHeight: 30) {
                            Task { await qx.testNodeLatency(nodeId: node.id) }
                        }

                        GlassIconButton(systemName: "trash", tint: .red, size: 32) {
                            qx.nodes.removeAll { $0.id == node.id }
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.11, green: 0.12, blue: 0.15)))
                }
            }
        }
    }

    // MARK: - 2. Quantumult X 脚本与重写规则管理
    private var scriptsAndRewriteSection: some View {
        @Bindable var bindableQX = qx

        return VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Quantumult X 脚本与重写引擎")
                        .font(.system(size: 16, weight: .bold))
                    Text("兼容 $request / $response / $done / $prefs / $notify 及 [rewrite_local] 语法")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: $bindableQX.isScriptEngineEnabled)
                    .labelsHidden()
                    .tint(.orange)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(red: 0.11, green: 0.12, blue: 0.15)))

            HStack {
                Label("已加载脚本与重写规则 (\(qx.scriptRules.count))", systemImage: "curlybraces.square.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.orange)
                Spacer()
                GlassPillButton(title: "导入配置", icon: "doc.badge.plus", isSelected: false, minHeight: 32) {
                    isShowingImportConfSheet = true
                }
                GlassPillButton(title: "新建脚本", icon: "plus", isSelected: true, activeColor: .orange, minHeight: 32) {
                    isShowingAddScriptSheet = true
                }
            }

            ForEach(qx.scriptRules) { rule in
                HStack(spacing: 12) {
                    Button {
                        editingScript = rule
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                if let target = rule.targetSource {
                                    Text(target.coverTopTag)
                                        .font(.system(size: 9.5, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(target.brandColor))
                                } else {
                                    Text("全局通用")
                                        .font(.system(size: 9.5, weight: .bold))
                                        .foregroundStyle(.white)
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 2)
                                        .background(Capsule().fill(Color.indigo))
                                }

                                Text(rule.name)
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }

                            Text("匹配正则：\(rule.urlPattern)")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            Text("类型：\(rule.actionType.displayTitle)")
                                .font(.system(size: 11))
                                .foregroundStyle(.orange.opacity(0.9))
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(ResponsivePressButtonStyle())

                    GlassPillButton(
                        title: rule.isEnabled ? "已启用" : "已停用",
                        isSelected: rule.isEnabled,
                        activeColor: .green,
                        minHeight: 32
                    ) {
                        if let idx = qx.scriptRules.firstIndex(where: { $0.id == rule.id }) {
                            qx.scriptRules[idx].isEnabled.toggle()
                        }
                    }

                    GlassIconButton(systemName: "trash", tint: .red, size: 32) {
                        qx.scriptRules.removeAll { $0.id == rule.id }
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.11, green: 0.12, blue: 0.15)))
            }
        }
    }

    // MARK: - 3. 实时代理路由与 QX 脚本命中日志
    private var trafficLogsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("软件内部实时请求与脚本日志 (\(qx.trafficLogs.count))", systemImage: "waveform.path.ecg.rectangle.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.orange)
                Spacer()
                GlassPillButton(title: "清空日志", icon: "trash", isSelected: false, minHeight: 30) {
                    qx.clearLogs()
                }
            }

            if qx.trafficLogs.isEmpty {
                Text("暂无请求记录，浏览书城或播放章节时将在此实时展示分源代理路由与 Quantumult X 脚本命中详情。")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(20)
                    .frame(maxWidth: .infinity)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color(red: 0.11, green: 0.12, blue: 0.15)))
            } else {
                ForEach(qx.trafficLogs) { log in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 6) {
                            Text(log.sourceName)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Color.orange))

                            Text(log.routeSummary)
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(.green)

                            if let sc = log.matchedScriptName {
                                Text("命中: \(sc)")
                                    .font(.system(size: 10.5, weight: .semibold))
                                    .foregroundStyle(.cyan)
                                    .lineLimit(1)
                            }

                            Spacer()

                            Text("\(log.statusCode) · \(log.durationMs)ms")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                        }

                        Text(log.urlString)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(red: 0.11, green: 0.12, blue: 0.15)))
                }
            }
        }
    }
}

// MARK: - 新增代理节点弹窗
struct AddQXProxyNodeSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(QuantumultXEngine.self) private var qx

    @State private var tag: String = "自定义代理节点"
    @State private var proto: QXProxyProtocol = .http
    @State private var host: String = "127.0.0.1"
    @State private var portText: String = "7890"
    @State private var username: String = ""
    @State private var password: String = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("节点信息") {
                    TextField("节点名称 (Tag)", text: $tag)
                    Picker("代理协议", selection: $proto) {
                        ForEach(QXProxyProtocol.allCases) { p in
                            Text(p.rawValue).tag(p)
                        }
                    }
                    TextField("服务器地址 (Host / IP)", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("端口 (Port)", text: $portText)
                        .keyboardType(.numberPad)
                }

                Section("可选认证 (Username / Password)") {
                    TextField("用户名 (选填)", text: $username)
                        .textInputAutocapitalization(.never)
                    SecureField("密码 (选填)", text: $password)
                }
            }
            .navigationTitle("新增内部代理节点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let port = Int(portText) ?? 7890
                        let node = QXProxyNode(
                            tag: tag.isEmpty ? "代理节点" : tag,
                            proto: proto,
                            host: host.trimmingCharacters(in: .whitespaces),
                            port: port,
                            username: username,
                            password: password
                        )
                        qx.nodes.append(node)
                        qx.selectedGlobalNodeId = node.id
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - 编辑 / 新建 Quantumult X 脚本弹窗
struct EditQXScriptRuleSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(QuantumultXEngine.self) private var qx

    let rule: QXScriptRule?

    @State private var name: String = ""
    @State private var targetChoice: Int = 0 // 0=全局, 1=喜马拉雅, 2=番茄畅听
    @State private var urlPattern: String = "ximalaya\\.com/"
    @State private var actionType: QXRewriteActionType = .scriptResponseBody
    @State private var jsCode: String = """
    var body = $response.body;
    try {
        var obj = JSON.parse(body);
        body = JSON.stringify(obj);
    } catch (e) {}
    $done({ body: body });
    """

    var body: some View {
        NavigationStack {
            Form {
                Section("规则基本配置") {
                    TextField("脚本/规则名称", text: $name)
                    Picker("作用书源范围", selection: $targetChoice) {
                        Text("全局双源通用").tag(0)
                        Text("仅喜马拉雅").tag(1)
                        Text("仅番茄畅听").tag(2)
                    }
                    TextField("URL 匹配正则表达式", text: $urlPattern)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Picker("Quantumult X 动作类型", selection: $actionType) {
                        ForEach(QXRewriteActionType.allCases) { act in
                            Text(act.displayTitle).tag(act)
                        }
                    }
                }

                Section("Quantumult X JavaScript 脚本代码 ($request / $response / $done / $prefs)") {
                    TextEditor(text: $jsCode)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minHeight: 220)
                }
            }
            .navigationTitle(rule == nil ? "新建 QX 脚本" : "编辑 QX 脚本")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if let rule {
                    name = rule.name
                    if rule.targetSource == .ximalaya { targetChoice = 1 }
                    else if rule.targetSource == .fanqie { targetChoice = 2 }
                    else { targetChoice = 0 }
                    urlPattern = rule.urlPattern
                    actionType = rule.actionType
                    jsCode = rule.jsCode
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let source: CoreSourceID? = (targetChoice == 1) ? .ximalaya : ((targetChoice == 2) ? .fanqie : nil)
                        let updated = QXScriptRule(
                            id: rule?.id ?? UUID().uuidString,
                            name: name.isEmpty ? "自定义QX脚本" : name,
                            targetSource: source,
                            urlPattern: urlPattern,
                            actionType: actionType,
                            jsCode: jsCode,
                            isEnabled: true
                        )
                        if let idx = qx.scriptRules.firstIndex(where: { $0.id == updated.id }) {
                            qx.scriptRules[idx] = updated
                        } else {
                            qx.scriptRules.insert(updated, at: 0)
                        }
                        dismiss()
                    }
                }
            }
        }
    }
}

// MARK: - 粘贴导入 Quantumult X 配置片段 ([server_local] / [rewrite_local])
struct ImportQXConfigSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(QuantumultXEngine.self) private var qx

    @State private var configText: String = #"""
    [server_local]
    http=127.0.0.1:7890, tag=本地HTTP代理
    socks5=127.0.0.1:7891, tag=本地SOCKS5代理

    [rewrite_local]
    ^https?:\/\/.*ximalaya\.com\/.*track.* url script-response-body xmly_vip_unlock.js
    ^https?:\/\/.*fanqiesdk\.com\/.* url script-response-body fanqie_free.js
    """#

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 12) {
                Text("支持直接粘贴 Quantumult X 的 [server_local] 节点配置与 [rewrite_local] 脚本重写规则：")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)

                TextEditor(text: $configText)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
            }
            .padding(16)
            .navigationTitle("导入 Quantumult X 配置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("解析导入") {
                        _ = qx.importQuantumultXConfigText(configText)
                        dismiss()
                    }
                }
            }
        }
    }
}
