import SwiftUI

struct AggregateSearchView: View {
    @Environment(DualSourceEngine.self) private var engine
    @Environment(AudioPlayerEngine.self) private var player
    @Environment(LibraryStore.self) private var library

    let onOpenFullPlayer: () -> Void

    @State private var query: String = ""
    @State private var selectedBookForDetail: BookItem? = nil

    private let hotKeywords = [
        "凡人修仙传", "剑来", "庆余年", "盗墓笔记",
        "雪中悍刀行", "诡秘之主", "大奉打更人", "遮天",
        "三体", "明朝那些事儿", "郭德纲相声", "单田芳评书"
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 单层极简搜索控制栏（无需选择书源，自动并发检索全网并按封面上方标签展示来源）
                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        HStack(spacing: 8) {
                            Image(systemName: "magnifyingglass")
                                .foregroundStyle(.secondary)

                            TextField("搜索书名、主角或主播，自动聚合全网有声书", text: $query)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .submitLabel(.search)
                                .onSubmit {
                                    triggerSearch(query)
                                }

                            if !query.isEmpty {
                                Button {
                                    query = ""
                                    engine.clearSearchResults()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 16))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 34, height: 34)
                                        .contentShape(Rectangle())
                                }
                                .buttonStyle(ResponsivePressButtonStyle())
                            }
                        }
                        .padding(.leading, 12)
                        .padding(.trailing, 4)
                        .frame(height: 42)
                        .background(
                            Capsule().fill(Color.white.opacity(0.08))
                        )

                        GlassPillButton(
                            title: "搜索",
                            icon: "sparkle.magnifyingglass",
                            isSelected: true,
                            activeColor: .orange,
                            minHeight: 42
                        ) {
                            triggerSearch(query)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .glassEffect(.regular, in: .rect(cornerRadius: 18))
                }
                .padding(.horizontal, 12)
                .padding(.top, 4)

                // 搜索内容区（纯净滚动区）
                ScrollView {
                    if engine.isSearching {
                        HStack {
                            Spacer()
                            ProgressView("正在全网检索并匹配最佳可用章节...")
                                .padding(.top, 60)
                            Spacer()
                        }
                    } else if !engine.searchResults.isEmpty {
                        LazyVStack(spacing: 12) {
                            HStack {
                                Text("共找到 \(engine.searchResults.count) 部匹配有声书（封面上方已标注来源）")
                                    .font(.system(size: 12, weight: .medium))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                GlassPillButton(title: "清空", icon: "xmark", isSelected: false, minHeight: 28) {
                                    query = ""
                                    engine.clearSearchResults()
                                }
                            }
                            .padding(.horizontal, 4)

                            ForEach(engine.searchResults) { book in
                                CleanBookRow(
                                    book: book,
                                    onOpenDetail: {
                                        selectedBookForDetail = book
                                    },
                                    onQuickPlay: {
                                        Task {
                                            await player.quickPlay(book: book)
                                            onOpenFullPlayer()
                                        }
                                    }
                                )
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 12)
                        .padding(.bottom, 125)
                    } else {
                        discoverySearchChips
                            .padding(.horizontal, 16)
                            .padding(.top, 16)
                            .padding(.bottom, 125)
                    }
                }
            }
            .background(Color(red: 0.06, green: 0.07, blue: 0.09).ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $selectedBookForDetail) { book in
                BookDetailView(book: book, onOpenFullPlayer: onOpenFullPlayer)
            }
        }
    }

    private var discoverySearchChips: some View {
        VStack(alignment: .leading, spacing: 22) {
            if let err = engine.searchError {
                Text(err)
                    .font(.system(size: 13))
                    .foregroundStyle(.orange)
                    .padding(.vertical, 6)
            }

            VStack(alignment: .leading, spacing: 12) {
                Label("热门全本有声小说", systemImage: "flame.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.orange)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 10)], spacing: 10) {
                    ForEach(hotKeywords, id: \.self) { word in
                        GlassPillButton(title: word, isSelected: false, minHeight: 36) {
                            query = word
                            triggerSearch(word)
                        }
                    }
                }
            }

            if !library.searchHistory.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Label("最近搜索", systemImage: "clock.arrow.circlepath")
                            .font(.system(size: 15, weight: .bold))
                        Spacer()
                        GlassPillButton(title: "清空历史", icon: "trash", isSelected: false, minHeight: 30) {
                            library.clearSearchHistory()
                        }
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 105), spacing: 10)], spacing: 10) {
                        ForEach(library.searchHistory, id: \.self) { word in
                            GlassPillButton(title: word, isSelected: false, minHeight: 34) {
                                query = word
                                triggerSearch(word)
                            }
                        }
                    }
                }
            }
        }
    }

    private func triggerSearch(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        library.recordSearch(trimmed)
        Task {
            await engine.performSearch(keyword: trimmed)
        }
    }
}
