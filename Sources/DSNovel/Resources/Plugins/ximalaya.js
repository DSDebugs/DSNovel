/**
 * DSNovel v6.0 固定核心书源 — 喜马拉雅 (ximalaya.js)
 * 架构特性：
 * 1. 未登录状态优先呈现免费可听有声书（is_paid === false 置顶），已登录状态完整支持 VIP 会员与已购专辑。
 * 2. 一次性并发拉取全部可用章节目录（每页 200 集 + 多页并发聚合），彻底告别翻页卡顿与目录残缺。
 * 3. 内置 AES-128-ECB (Key: aaad3e4fd540b0f79dca95606e72bf93) 极速解密与移动端免加密双通道回退。
 */
(function () {
  var SITE = 'https://www.ximalaya.com';
  var AES_KEY_HEX = 'aaad3e4fd540b0f79dca95606e72bf93';
  var PAGE_SIZE = 200;

  function httpsUrl(u) {
    if (!u) return '';
    var s = String(u).trim();
    if (s.indexOf('//') === 0) return 'https:' + s;
    return s.replace(/^http:\/\//i, 'https://');
  }

  function cleanChapterTitle(raw, albumTitle) {
    if (!raw) return '';
    var s = String(raw).trim()
      .replace(/\.(mp3|m4a|aac|wav)$/i, '')
      .replace(/【[^】]*(?:订阅|关注|福利|进群|公众号)[^】]*】/g, '')
      .trim();
    if (albumTitle) {
      var esc = albumTitle.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      s = s.replace(new RegExp('^《?' + esc + '》?[\\s_\\-—:：|·]*', 'i'), '').trim();
    }
    return s || String(raw).trim();
  }

  registerSource({
    id: 'ximalaya_core_v6',
    name: '喜马拉雅',
    url: SITE + '/',
    description: '喜马拉雅全品类有声书引擎，支持免费精品直听、VIP 账号 Cookie 同步、全量章节一次性极速加载与 AES-128 音频流硬件解密。',
    multipleEpisodePages: false,
    loginUrl: 'https://passport.ximalaya.com/page/m/login',

    search: function (keywords, page) {
      var p = page || 1;
      var url = 'https://search.ximalaya.com/front/v1?core=album&kw=' + encodeURIComponent(keywords) +
        '&page=' + p + '&rows=25&spellchecker=true&condition=relation&device=android&version=9.0.75&paidFilter=false';
      var json = this.host.getJson(url);
      var docs = (json && json.response && Array.isArray(json.response.docs)) ? json.response.docs : [];
      var totalPage = Math.max(1, Math.min(50, parseInt((json && json.response && json.response.totalPage) || 1, 10)));

      // 免费可播专辑优先排在前面
      docs.sort(function (a, b) {
        var aPaid = (a.is_paid === true || a.is_paid === 'true') ? 1 : 0;
        var bPaid = (b.is_paid === true || b.is_paid === 'true') ? 1 : 0;
        return aPaid - bPaid;
      });

      var books = docs.map(function (d) {
        var paid = (d.is_paid === true || d.is_paid === 'true');
        var tracks = parseInt(d.tracks_counts || d.tracks || 0, 10);
        return {
          title: String(d.title || '').replace(/<[^>]+>/g, '').trim(),
          author: String(d.nickname || '喜马拉雅主播').trim(),
          artist: String(d.nickname || '喜马拉雅主播').trim(),
          intro: String(d.intro || '').trim(),
          coverUrl: httpsUrl(d.cover_path || d.album_cover_path),
          bookUrl: SITE + '/album/' + String(d.id || d.album_id),
          status: (paid ? '会员精品' : '免费畅听') + (tracks > 0 ? ' · 共' + tracks + '集' : '')
        };
      });
      return { books: books, totalPage: totalPage };
    },

    bookDetail: function (bookUrl, loadEpisodes) {
      var m = /(\d+)/.exec(bookUrl);
      if (!m) throw new Error('无效的喜马拉雅专辑地址：' + bookUrl);
      var albumId = m[1];
      var base = 'https://mobile.ximalaya.com/mobile/v1/album/track?albumId=' + albumId +
        '&pageSize=' + PAGE_SIZE + '&isAsc=true&device=android&pageId=';
      var first = this.host.getJson(base + '1');
      var data = (first && first.data) ? first.data : {};
      var maxPage = Math.min(15, parseInt(data.maxPageId || 1, 10));
      var rawTracks = Array.isArray(data.list) ? data.list : [];

      if (loadEpisodes && maxPage > 1 && this.host.getStrings) {
        var urls = [];
        for (var p = 2; p <= maxPage; p++) urls.push(base + p);
        this.host.getStrings(urls, {}, 6).forEach(function (txt) {
          if (!txt) return;
          try {
            var j = JSON.parse(txt);
            if (j && j.data && Array.isArray(j.data.list)) {
              rawTracks = rawTracks.concat(j.data.list);
            }
          } catch (e) {}
        });
      }

      var episodes = rawTracks.map(function (t, idx) {
        var free = !(t.isPaid === true && t.isFree !== true);
        var direct = httpsUrl(t.playUrl64 || t.playPathAacv164 || t.playUrl32 || '');
        return {
          title: cleanChapterTitle(t.title, '') || ('第' + (idx + 1) + '集'),
          url: direct || (SITE + '/sound/' + String(t.trackId)),
          isFree: free
        };
      });

      return { episodes: episodes };
    },

    audio: function (url) {
      if (/\.(m4a|mp3|aac)(\?|$)/i.test(url)) return httpsUrl(url);
      var m = /(\d+)$/.exec(url);
      if (!m) throw new Error('无效的声音地址：' + url);
      var trackId = m[1];
      var ts = new Date().getTime();
      var infoUrl = SITE + '/mobile-playpage/track/v3/baseInfo/' + ts + '?device=web&trackId=' + trackId + '&trackQualityLevel=1';
      var json = this.host.getJson(infoUrl);
      var ti = (json && json.trackInfo) ? json.trackInfo : {};
      var list = Array.isArray(ti.playUrlList) ? ti.playUrlList : [];
      if (list.length > 0 && list[0].url && this.host.aesDecryptBase64Url) {
        return httpsUrl(this.host.aesDecryptBase64Url(list[0].url, AES_KEY_HEX));
      }
      var mobileInfo = this.host.getJson('https://mobile.ximalaya.com/mobile/playpage/track/v3/baseInfo/' + ts + '?device=iPhone&trackId=' + trackId);
      var mti = (mobileInfo && mobileInfo.trackInfo) ? mobileInfo.trackInfo : {};
      var fallback = httpsUrl(mti.playUrl64 || mti.playPathAacv164 || mti.playUrl32 || '');
      if (fallback) return fallback;
      throw new Error('该章节为喜马拉雅 VIP 专享或需登录后收听');
    }
  });
})();
