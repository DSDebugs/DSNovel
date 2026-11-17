import SwiftUI
import UIKit

// MARK: - 底部悬浮灵动坞三态枚举与全局控制器（方案一：原生 TabView 隐藏系统栏 + 顶层 AdaptiveBottomDock）
//
// 三态定义：
// 1. .expanded（展开双层态）：
//    - 上层：全宽玻璃迷你播放条（左封面、中章节与书名、右播放/暂停 + 下一章、底部 2pt 进度线）
//    - 下层：左侧展开三合一主导航舱（发现 · 书架 · 设置） + 右侧独立圆形搜索球
// 2. .collapsed（滚动收起三胶囊态）：
//    - 向下滚动阅读超过阈值或进入二级子页面时自动折叠为单排三胶囊（高度仅 50pt）：
//    - 左侧：当前主 Tab 圆形图标按钮（点击即刻展开为 .expanded）
//    - 中间：紧凑型胶囊迷你播放条（封面 + 滚动章节名 + 播放/暂停键 + 底部进度线）
//    - 右侧：独立圆形搜索球（点击进入 .searchInline）
// 3. .searchInline（搜索内联态）：
//    - 点击右侧圆形搜索球或切换到搜索 Tab 时：
//    - 上层：全宽玻璃迷你播放条（若有正在播放的书籍）
//    - 下层：左侧折叠为「返回上一主 Tab」圆形图标按钮 + 右侧横向舒展为圆角内联搜索输入框胶囊

enum BottomDockMode: Equatable, Sendable {
    case expanded
    case collapsed
    case searchInline
}

@MainActor
@Observable
final class BottomDockController {
    static let shared = BottomDockController()

    /// 当前激活的根 Tab（与 RootTabView 的 TabView selection 双向同步）
    var selectedTab: AppTab = .discover

    /// 记录进入搜索前的最后一个主 Tab（发现 / 书架 / 设置），供收起态与搜索态左侧圆球图标展示及一键返回
    var lastNonSearchTab: AppTab = .discover

    /// 当前底部灵动坞所处形态
    var mode: BottomDockMode = .expanded

    /// 是否请求聚焦底部内联搜索输入框
    var isSearchFieldFocused: Bool = false

    /// 书架多选编辑模式开启时隐藏底部灵动坞，将底部空间让位给多选操作栏
    var isSuppressedByEditing: Bool = false

    /// 当前激活 Tab 的 NavigationStack 深度（>0 表示处于书籍详情、书源管理等二级页面）
    var activeNavigationDepth: Int = 0

    /// 供底部内联搜索框按回车或点击搜索时触发的回调（由 SearchView 注入）
    var onSubmitInlineSearch: ((String) -> Void)?

    private var lastScrollY: CGFloat = 0
    private var accumulatedDelta: CGFloat = 0

    /// 点击展开态主导航舱中的某个主 Tab（发现 / 书架 / 设置）
    func selectMainTab(_ tab: AppTab) {
        guard tab != .search else {
            activateSearchInline(autoFocus: false)
            return
        }
        withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
            selectedTab = tab
            lastNonSearchTab = tab
            mode = activeNavigationDepth > 0 ? .collapsed : .expanded
            isSearchFieldFocused = false
        }
        resetScrollTracking()
    }

    /// 点击右侧圆形搜索球或从外部跳转到搜索页
    func activateSearchInline(autoFocus: Bool = false) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
            if selectedTab != .search {
                lastNonSearchTab = selectedTab
            }
            selectedTab = .search
            mode = .searchInline
            isSearchFieldFocused = autoFocus
        }
        resetScrollTracking()
    }

    /// 点击左侧圆形主 Tab 球：
    /// - 若当前处于搜索态（.searchInline），一键切回进入搜索前的主 Tab 并展开为双层导航态
    /// - 若当前处于滚动收起态（.collapsed），原地丝滑展开为双层导航态
    func expandFromLeftOrb() {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
            if selectedTab == .search {
                selectedTab = lastNonSearchTab
            }
            mode = .expanded
            isSearchFieldFocused = false
        }
        resetScrollTracking()
    }

    /// 同步当前激活 Tab 的导航栈深度：进入二级页面时自动收起为紧凑单排态，返回根页面时自动展开
    func updateNavigationDepth(_ depth: Int) {
        guard activeNavigationDepth != depth else { return }
        activeNavigationDepth = depth
        withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
            if selectedTab == .search {
                mode = depth > 0 ? .collapsed : .searchInline
                if depth > 0 { isSearchFieldFocused = false }
            } else {
                mode = depth > 0 ? .collapsed : .expanded
            }
        }
        resetScrollTracking()
    }

    /// 接收各页面 ScrollView / List 的滚动偏移或手势增量，带方向迟滞滤波（Hysteresis）防止抖动
    func handleScrollOffset(_ offsetY: CGFloat) {
        guard selectedTab != .search, activeNavigationDepth == 0 else { return }

        if offsetY <= 10 {
            if mode != .expanded {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                    mode = .expanded
                }
            }
            lastScrollY = max(0, offsetY)
            accumulatedDelta = 0
            return
        }

        let delta = offsetY - lastScrollY
        lastScrollY = offsetY

        if (delta > 0 && accumulatedDelta < 0) || (delta < 0 && accumulatedDelta > 0) {
            accumulatedDelta = 0
        }
        accumulatedDelta += delta

        if accumulatedDelta > 28, mode == .expanded {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                mode = .collapsed
            }
            accumulatedDelta = 0
        } else if accumulatedDelta < -20, mode == .collapsed {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                mode = .expanded
            }
            accumulatedDelta = 0
        }
    }

    /// 接收纵向拖动手势速度/位移（适用于原生 List 等不便插入 GeometryReader 探针的容器）
    func handleVerticalDrag(translationY: CGFloat) {
        guard selectedTab != .search else {
            if translationY < -16, isSearchFieldFocused {
                isSearchFieldFocused = false
            }
            return
        }
        if translationY < -26, mode == .expanded {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                mode = .collapsed
            }
        } else if translationY > 26, mode == .collapsed, activeNavigationDepth == 0 {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.84)) {
                mode = .expanded
            }
        }
    }

    func resetScrollTracking() {
        lastScrollY = 0
        accumulatedDelta = 0
    }
}

// MARK: - 悬浮灵动坞主视图（AdaptiveBottomDock）

struct AdaptiveBottomDock: View {
    @Bindable var dock: BottomDockController
    @Bindable var searchVM: SearchViewModel
    let onExpandFullPlayer: () -> Void

    @Namespace private var morphNS
    @FocusState private var searchFocused: Bool
    private var player = PlayerEngine.shared

    private let mainTabs: [AppTab] = [.discover, .shelf, .settings]

    // 显式 internal init：private/@Namespace/@FocusState 属性会使 memberwise init 变为 private，
    // 而 RootTabView 在另一个文件里构造本视图，故必须显式开放。
    init(dock: BottomDockController, searchVM: SearchViewModel, onExpandFullPlayer: @escaping () -> Void) {
        self._dock = Bindable(wrappedValue: dock)
        self._searchVM = Bindable(wrappedValue: searchVM)
        self.onExpandFullPlayer = onExpandFullPlayer
    }

    var body: some View {
        VStack(spacing: 10) {
            // 上层：在「展开态」或「搜索内联态（键盘未弹出时）」且有播放任务时展示全宽迷你播放条
            if player.isMiniPlayerVisible && (dock.mode == .expanded || (dock.mode == .searchInline && !searchFocused)) {
                FullWidthMiniPlayerPill(onTapExpand: onExpandFullPlayer)
                    .matchedGeometryEffect(id: "dock_mini_player", in: morphNS)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .bottom)),
                        removal: .opacity
                    ))
            }

            // 下层：左、中、右三态流体胶囊
            HStack(spacing: 10) {
                switch dock.mode {
                case .expanded:
                    expandedTabCapsule
                    searchCircleButton

                case .collapsed:
                    leftActiveTabOrb
                    if player.isMiniPlayerVisible {
                        CompactMiniPlayerPill(onTapExpand: onExpandFullPlayer)
                            .matchedGeometryEffect(id: "dock_mini_player", in: morphNS)
                    } else {
                        Spacer(minLength: 0)
                    }
                    searchCircleButton

                case .searchInline:
                    leftActiveTabOrb
                    expandedSearchBarPill
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 6)
        .onChange(of: dock.isSearchFieldFocused) { _, focused in
            if searchFocused != focused {
                searchFocused = focused
            }
        }
        .onChange(of: searchFocused) { _, focused in
            if dock.isSearchFieldFocused != focused {
                dock.isSearchFieldFocused = focused
            }
        }
    }

    // MARK: 1. 左侧展开态主导航舱（发现 · 书架 · 设置）

    private var expandedTabCapsule: some View {
        GlassEffectContainer(cornerRadius: 28) {
            HStack(spacing: 4) {
                ForEach(mainTabs, id: \.rawValue) { tab in
                    let isSelected = dock.selectedTab == tab
                    Button {
                        dock.selectMainTab(tab)
                    } label: {
                        VStack(spacing: 2) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 16, weight: .semibold))
                            Text(tab.title)
                                .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                        }
                        .foregroundStyle(isSelected ? DSColor.primary : .secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background {
                            if isSelected {
                                Capsule(style: .continuous)
                                    .fill(DSColor.primary.opacity(0.12))
                                    .matchedGeometryEffect(id: "dock_active_tab_pill", in: morphNS)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(4)
        }
        .matchedGeometryEffect(id: "dock_left_nav", in: morphNS)
        .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 4)
    }

    // MARK: 2. 左侧收起态 / 搜索态单圆球按钮（显示当前主 Tab 图标，点击展开或返回）

    private var leftActiveTabOrb: some View {
        GlassEffectContainer(cornerRadius: 25) {
            Button {
                dock.expandFromLeftOrb()
            } label: {
                Image(systemName: dock.lastNonSearchTab.icon)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(DSColor.primary)
                    .frame(width: 50, height: 50)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("展开导航栏（当前：\(dock.lastNonSearchTab.title)）")
        }
        .matchedGeometryEffect(id: "dock_left_nav", in: morphNS)
        .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 4)
    }

    // MARK: 3. 右侧独立圆形搜索球

    private var searchCircleButton: some View {
        GlassEffectContainer(cornerRadius: 25) {
            Button {
                dock.activateSearchInline(autoFocus: false)
            } label: {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 50, height: 50)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("打开搜索")
        }
        .matchedGeometryEffect(id: "dock_right_search", in: morphNS)
        .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 4)
    }

    // MARK: 4. 右侧展开态内联搜索输入框胶囊

    private var expandedSearchBarPill: some View {
        GlassEffectContainer(cornerRadius: 25) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)

                TextField("搜索书名、作者、演播…", text: $searchVM.keyword)
                    .textFieldStyle(.plain)
                    .font(.subheadline)
                    .focused($searchFocused)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.search)
                    .onSubmit {
                        dock.onSubmitInlineSearch?(searchVM.keyword)
                    }

                if !searchVM.keyword.isEmpty {
                    Button {
                        searchVM.clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("清空搜索词")
                }

                if searchVM.isSearching {
                    Button {
                        searchVM.cancelSearch()
                    } label: {
                        Text("停止")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.red)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                            .background(Color.red.opacity(0.12), in: Capsule())
                    }
                    .buttonStyle(.plain)
                } else if !searchVM.keyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button {
                        searchFocused = false
                        dock.onSubmitInlineSearch?(searchVM.keyword)
                    } label: {
                        Text("搜索")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(DSColor.primary, in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
        }
        .matchedGeometryEffect(id: "dock_right_search", in: morphNS)
        .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 4)
    }
}

// MARK: - 全宽迷你播放条（用于 .expanded 与 .searchInline 上层）

struct FullWidthMiniPlayerPill: View {
    let onTapExpand: () -> Void
    private var player = PlayerEngine.shared

    // 显式 internal init：private 存储属性会使编译器生成的 memberwise init 变为 private
    init(onTapExpand: @escaping () -> Void) {
        self.onTapExpand = onTapExpand
    }

    var body: some View {
        if let book = player.currentBook, let chapter = player.currentChapter {
            GlassEffectContainer(cornerRadius: 24) {
                VStack(spacing: 0) {
                    HStack(spacing: 12) {
                        CoverImageView(
                            url: book.cover,
                            title: book.title,
                            width: 38,
                            height: 38,
                            cornerRadius: 8
                        )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(chapter.title)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if case .failed(let errMsg) = player.state {
                                Text(errMsg)
                                    .font(.caption2)
                                    .foregroundStyle(.red)
                                    .lineLimit(1)
                            } else if player.state == .buffering {
                                Text("正在缓冲音频… · \(book.title)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            } else {
                                Text(book.title)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 4)

                        GlassButton {
                            player.togglePlayPause()
                        } label: {
                            if player.state == .buffering {
                                ProgressView()
                                    .controlSize(.small)
                                    .frame(width: 34, height: 34)
                            } else {
                                Image(systemName: player.state == .playing ? "pause.fill" : "play.fill")
                                    .font(.title3)
                                    .frame(width: 34, height: 34)
                            }
                        }
                        .accessibilityLabel(player.state == .playing ? "暂停" : "播放")

                        GlassButton {
                            player.playNextChapter()
                        } label: {
                            Image(systemName: "forward.end.fill")
                                .font(.subheadline)
                                .frame(width: 30, height: 30)
                        }
                        .accessibilityLabel("下一章")
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)

                    DockMiniProgressLine(clock: player.clock)
                        .padding(.horizontal, 12)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onTapExpand()
            }
            .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 4)
        }
    }
}

// MARK: - 紧凑型胶囊迷你播放条（用于 .collapsed 中间夹在左圆与右搜索球之间）

struct CompactMiniPlayerPill: View {
    let onTapExpand: () -> Void
    private var player = PlayerEngine.shared

    var body: some View {
        if let book = player.currentBook, let chapter = player.currentChapter {
            GlassEffectContainer(cornerRadius: 25) {
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        CoverImageView(
                            url: book.cover,
                            title: book.title,
                            width: 34,
                            height: 34,
                            cornerRadius: 8
                        )

                        VStack(alignment: .leading, spacing: 1) {
                            Text(chapter.title)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .lineLimit(1)
                            if case .failed(let errMsg) = player.state {
                                Text(errMsg)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.red)
                                    .lineLimit(1)
                            } else {
                                Text(book.title)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }

                        Spacer(minLength: 2)

                        GlassButton {
                            player.togglePlayPause()
                        } label: {
                            if player.state == .buffering {
                                ProgressView()
                                    .controlSize(.mini)
                                    .frame(width: 30, height: 30)
                            } else {
                                Image(systemName: player.state == .playing ? "pause.fill" : "play.fill")
                                    .font(.subheadline.weight(.bold))
                                    .frame(width: 30, height: 30)
                            }
                        }
                        .accessibilityLabel(player.state == .playing ? "暂停" : "播放")
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 48)

                    DockMiniProgressLine(clock: player.clock)
                        .padding(.horizontal, 12)
                }
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                onTapExpand()
            }
            .shadow(color: Color.black.opacity(0.08), radius: 10, x: 0, y: 4)
        }
    }
}

private struct DockMiniProgressLine: View {
    var clock: PlaybackClock

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.1))
                Capsule()
                    .fill(DSColor.primary)
                    .frame(width: geo.size.width * clock.progressFraction)
            }
        }
        .frame(height: 2)
    }
}

// MARK: - 滚动与底部安全区联动修饰器（兼容 iOS 17+ ScrollView 与 List）

private struct DockScrollAdaptiveModifier: ViewModifier {
    var dock = BottomDockController.shared
    var player = PlayerEngine.shared

    private var reservedHeight: CGFloat {
        guard !dock.isSuppressedByEditing else { return 16 }
        switch dock.mode {
        case .expanded, .searchInline:
            return player.isMiniPlayerVisible ? 128 : 68
        case .collapsed:
            return 68
        }
    }

    func body(content: Content) -> some View {
        content
            .simultaneousGesture(
                DragGesture(minimumDistance: 12, coordinateSpace: .local)
                    .onChanged { value in
                        dock.handleVerticalDrag(translationY: value.translation.height)
                    }
            )
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Color.clear
                    .frame(height: reservedHeight)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    /// 挂载于各页面的主列表或滚动容器上，自动感知上下滑动手势切换灵动坞形态并预留底部安全区高度
    func dsAdaptiveBottomDockScroll() -> some View {
        modifier(DockScrollAdaptiveModifier())
    }
}
