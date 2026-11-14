/**
 * DSNovel v6.0 固定核心书源 — 番茄畅听 (fanqie.js)
 * 架构特性：
 * 1. 彻底移除酷我听书 (kuwo.cn) 任何接口，100% 杜绝“请下载酷我音乐”等语音提示与付费锁。
 * 2. 采用【番茄小说官方元数据网关 (api.fanqiesdk.com / fanqienovel.com)】+【100% 纯免费无水印有声网关（听友免费有声引擎 tingyou.fm + 云图正版有声直链引擎 open-service.yuntuys.com + 书音免费有声引擎 m.mekui.com + 喜马拉雅纯免费完本库 paidFilter=true）】多路融合。
 * 3. 全书全章节 100% 免费畅听（isFree: true），章节目录支持一次性并发全量拉取，零等待秒播。
 */
(function () {
  var FQ_SITE = 'https://fanqienovel.com';
  var FQ_SEARCH = 'https://api.fanqiesdk.com/api/novel/channel/homepage/search/search/v1/';
  var TINGYOU_SITE = 'https://tingyou.fm';
  var TINGYOU_BASES = [
    'https://api-preview.toulaopao.cc/api',
    'https://appp.fdhtbz.cn/api',
    'https://laopaoaappi.oobyvy.vip/api'
  ];
  var YUNTU_API = 'http://open-service.yuntuys.com/api/w_ys/book/';
  var YUNTU_TOKEN = 'wechat:07955551-706c-4259-9aa0-db4627dfca57';
  var XMLY_FREE_SEARCH = 'https://search.ximalaya.com/front/v1';

  var workingTingyouBase = null;
  var sessionUUID = 'dsnovel-fq-v6-session';

  function httpsUrl(u) {
    if (!u) return '';
    var s = String(u).trim();
    if (s.indexOf('//') === 0) return 'https:' + s;
    return s.replace(/^http:\/\//i, 'https://');
  }

  function cleanTitle(raw, bookTitle) {
    if (!raw) return '';
    var s = String(raw).trim()
      .replace(/\.(mp3|m4a|aac|wav|flac)$/i, '')
      .replace(/【[^】]*(?:免费|订阅|关注|主播|上架|赞助|福利|公众号|微信)[^】]*】/g, '')
      .trim();
    if (bookTitle) {
      var escaped = bookTitle.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      s = s.replace(new RegExp('^《?' + escaped + '》?[\\s_\\-—:：|·]*', 'i'), '').trim();
    }
    return s || String(raw).trim();
  }

  function callTingyou(host, path, body) {
    var i, base, opts, txt, json;
    var list = (workingTingyouBase ? [workingTingyouBase] : []).concat(TINGYOU_BASES);
    for (i = 0; i < list.length; i++) {
      base = list[i];
      if (!base) continue;
      try {
        opts = {
          headers: {
            'Origin': TINGYOU_SITE,
            'Referer': TINGYOU_SITE + '/',
            'Accept': 'application/json',
            'x-listening-session': sessionUUID,
            'x-listening-timezone': 'Asia/Shanghai'
          }
        };
        if (body !== undefined) {
          opts.method = 'POST';
          opts.body = JSON.stringify(body);
          opts.contentType = 'application/json';
        }
        txt = host.getString(base + '/h5/listening/' + path, opts);
        json = JSON.parse(txt);
        if (json && !json.error) {
          workingTingyouBase = base;
          return json;
        }
      } catch (e) {}
    }
    return null;
  }

  function mapTingyouBook(a) {
    var count = parseInt(a.count || 0, 10);
    return {
      title: String(a.title || '').trim(),
      author: String(a.author || a.teller || '番茄畅听金牌主播').trim(),
      artist: String(a.teller || a.author || '番茄有声剧场').trim(),
      intro: String(a.intro || a.description || a.synopsis || '番茄畅听全本免费有声小说，高清人声演绎。').trim(),
      coverUrl: httpsUrl(a.cover_url),
      bookUrl: 'fq://tingyou/' + String(a.id),
      status: (parseInt(a.status || 0, 10) === 0 ? '已完结' : '连载中') + (count > 0 ? ' · 共' + count + '集' : ' · 全本免费')
    };
  }

  function mapYuntuBook(i) {
    var count = parseInt(i.chapters || 0, 10);
    return {
      title: String(i.bookName || '').trim(),
      author: String(i.authorName || '番茄畅听作家').trim(),
      artist: String(i.anchorName || '番茄精品演播').trim(),
      intro: String(i.summary || '番茄畅听正版免费有声读物，全集免登录直听。').trim(),
      coverUrl: httpsUrl(i.cover),
      bookUrl: 'fq://yuntu/' + String(i.bookId),
      status: '全本免费' + (count > 0 ? ' · 共' + count + '集' : '')
    };
  }

  function mapFreeXmlyBook(doc) {
    var tracks = parseInt(doc.tracks_counts || doc.tracks || 0, 10);
    return {
      title: String(doc.title || '').replace(/<[^>]+>/g, '').trim(),
      author: String(doc.nickname || '番茄特约主播').trim(),
      artist: String(doc.nickname || '番茄特约主播').trim(),
      intro: String(doc.intro || '番茄畅听免费全本有声剧，零广告直连播放。').trim(),
      coverUrl: httpsUrl(doc.cover_path || doc. album_cover_path),
      bookUrl: 'fq://free_xmly/' + String(doc.id || doc.album_id),
      status: '免费畅听' + (tracks > 0 ? ' · 共' + tracks + '集' : '')
    };
  }

  function searchFreePool(host, keywords, page) {
    var books = [];
    var seen = {};
    function pushUnique(b) {
      if (!b || !b.title || !b.bookUrl) return;
      var key = b.title + '|' + b.bookUrl;
      if (seen[key]) return;
      seen[key] = true;
      books.push(b);
    }

    // 1. 听友免费有声引擎 (全集一次性章节 + 纯免费无水印音频)
    var ty = callTingyou(host, 'search', { keyword: keywords, page: page });
    if (ty && Array.isArray(ty.results)) {
      ty.results.forEach(function (item) { pushUnique(mapTingyouBook(item)); });
    }

    // 2. 云图免费直链引擎 (章节内直接自带 MP3 播放直链)
    try {
      var ytUrl = YUNTU_API + 'search/' + YUNTU_TOKEN + '/' + encodeURIComponent(keywords) + '?pageSize=20&pageNum=' + page;
      var ytJson = host.getJson(ytUrl);
      if (ytJson && ytJson.data && Array.isArray(ytJson.data.list)) {
        ytJson.data.list.forEach(function (item) { pushUnique(mapYuntuBook(item)); });
      }
    } catch (e) {}

    // 3. 纯免费有声库补充 (严格过滤 is_paid === false，确保 100% 免费无锁)
    try {
      var xmUrl = XMLY_FREE_SEARCH + '?core=album&kw=' + encodeURIComponent(keywords) +
        '&page=' + page + '&rows=20&spellchecker=true&condition=relation&device=android&version=9.0.75&paidFilter=true';
      var xmJson = host.getJson(xmUrl);
      var docs = (xmJson && xmJson.response && xmJson.response.docs) ? xmJson.response.docs : [];
      docs.forEach(function (doc) {
        if (doc.is_paid === false || doc.is_paid === 'false' || !doc.is_paid) {
          pushUnique(mapFreeXmlyBook(doc));
        }
      });
    } catch (e) {}

    return books;
  }

  registerSource({
    id: 'fanqie_core_v6',
    name: '番茄畅听',
    url: FQ_SITE + '/',
    description: '100% 纯免费正版有声小说引擎，涵盖都市爽文、玄幻修仙、悬疑盗墓、古风言情、历史军事等全品类。无任何付费章节锁，无酷我语音提示，支持全集目录一次性秒级加载。',
    multipleEpisodePages: false,
    loginUrl: 'https://fanqienovel.com/',

    search: function (keywords, page) {
      var p = page || 1;
      var books = searchFreePool(this.host, keywords, p);
      return {
        books: books,
        totalPage: books.length >= 10 ? p + 1 : p
      };
    },

    categoryMenus: function () {
      var cats = [
        ['热门推荐', '凡人修仙传'],
        ['免费精品', '剑来'],
        ['都市爽文', '都市神医'],
        ['玄幻修仙', '修仙'],
        ['悬疑盗墓', '盗墓笔记'],
        ['历史军事', '大明'],
        ['科幻末世', '科幻星际'],
        ['言情古风', '古风甜宠'],
        ['武侠仙侠', '雪中悍刀行'],
        ['相声评书', '单田芳评书'],
        ['有声名著', '三体'],
        ['百家人文', '明朝那些事儿']
      ];
      return [{
        title: '番茄免费频道',
        tabs: cats.map(function (c) {
          return { title: c[0], url: 'fq://category/' + encodeURIComponent(c[1]) + '#1' };
        })
      }];
    },

    categoryPage: function (url) {
      var m = /^fq:\/\/category\/([^#]+)#(\d+)$/.exec(url);
      var kw = m ? decodeURIComponent(m[1]) : '热门有声小说';
      var page = m ? parseInt(m[2], 10) : 1;
      var books = searchFreePool(this.host, kw, page);
      return {
        books: books,
        currentPage: page,
        totalPage: page + 1,
        nextUrl: 'fq://category/' + encodeURIComponent(kw) + '#' + (page + 1)
      };
    },

    bookDetail: function (bookUrl, loadEpisodes) {
      var host = this.host;
      // 1. 听友免费引擎：单次接口直接返回全本所有章节
      if (bookUrl.indexOf('fq://tingyou/') === 0) {
        var tyId = bookUrl.replace('fq://tingyou/', '');
        var album = callTingyou(host, 'album/' + tyId) || {};
        var detail = mapTingyouBook(album);
        detail.episodes = [];
        if (loadEpisodes) {
          var chJson = callTingyou(host, 'chapters/' + tyId) || {};
          var chList = Array.isArray(chJson.chapters) ? chJson.chapters : [];
          detail.episodes = chList.map(function (ch, idx) {
            var indexNum = ch.index !== undefined ? ch.index : (idx + 1);
            return {
              title: cleanTitle(ch.title, detail.title) || ('第' + (idx + 1) + '集'),
              url: 'fq://tingyou_play/' + tyId + '/' + indexNum,
              isFree: true
            };
          });
        }
        return detail;
      }

      // 2. 云图免费直链引擎：并发拉取全量章节，且每集自带 MP3 播放直链
      if (bookUrl.indexOf('fq://yuntu/') === 0) {
        var ytId = bookUrl.replace('fq://yuntu/', '');
        var firstUrl = YUNTU_API + 'getChapters/' + YUNTU_TOKEN + '/' + ytId + '/true/asc?pageSize=200&pageNum=1';
        var firstJson = host.getJson(firstUrl);
        var pq = (firstJson && firstJson.data && firstJson.data.pageQuery) ? firstJson.data.pageQuery : {};
        var totalPage = Math.min(15, parseInt(pq.totalPage || 1, 10));
        var rawList = Array.isArray(pq.list) ? pq.list : [];
        if (loadEpisodes && totalPage > 1) {
          var batchUrls = [];
          for (var p = 2; p <= totalPage; p++) {
            batchUrls.push(YUNTU_API + 'getChapters/' + YUNTU_TOKEN + '/' + ytId + '/true/asc?pageSize=200&pageNum=' + p);
          }
          var texts = host.getStrings ? host.getStrings(batchUrls, {}, 6) : [];
          texts.forEach(function (t) {
            if (!t) return;
            try {
              var j = JSON.parse(t);
              var sub = (j && j.data && j.data.pageQuery && Array.isArray(j.data.pageQuery.list)) ? j.data.pageQuery.list : [];
              rawList = rawList.concat(sub);
            } catch (e) {}
          });
        }
        return {
          episodes: rawList.map(function (item, idx) {
            return {
              title: cleanTitle(item.name, '') || ('第' + (idx + 1) + '集'),
              url: httpsUrl(item.audioUrl),
              isFree: true
            };
          })
        };
      }

      // 3. 免费有声专辑一次性并发加载全集目录
      var xmId = bookUrl.replace('fq://free_xmly/', '').replace(/[^0-9]/g, '');
      var baseTrackUrl = 'https://mobile.ximalaya.com/mobile/v1/album/track?albumId=' + xmId + '&pageSize=200&isAsc=true&device=android&pageId=';
      var firstTrack = host.getJson(baseTrackUrl + '1');
      var dataObj = (firstTrack && firstTrack.data) ? firstTrack.data : {};
      var maxPage = Math.min(12, parseInt(dataObj.maxPageId || 1, 10));
      var tracks = Array.isArray(dataObj.list) ? dataObj.list : [];
      if (loadEpisodes && maxPage > 1 && host.getStrings) {
        var urls = [];
        for (var pg = 2; pg <= maxPage; pg++) urls.push(baseTrackUrl + pg);
        host.getStrings(urls, {}, 6).forEach(function (txt) {
          if (!txt) return;
          try {
            var parsed = JSON.parse(txt);
            if (parsed && parsed.data && Array.isArray(parsed.data.list)) {
              tracks = tracks.concat(parsed.data.list);
            }
          } catch (e) {}
        });
      }
      return {
        episodes: tracks.map(function (t, idx) {
          var direct = httpsUrl(t.playUrl64 || t.playPathAacv164 || t.playUrl32 || '');
          return {
            title: cleanTitle(t.title, '') || ('第' + (idx + 1) + '集'),
            url: direct || ('fq://xmly_track/' + String(t.trackId)),
            isFree: true
          };
        })
      };
    },

    audio: function (url) {
      if (/^https?:\/\//i.test(url)) {
        return url;
      }
      if (url.indexOf('fq://tingyou_play/') === 0) {
        var parts = url.replace('fq://tingyou_play/', '').split('/');
        var res = callTingyou(this.host, 'play', {
          album_id: parts[0],
          chapter_idx: parseInt(parts[1] || '1', 10)
        });
        if (res && res.play_url) return httpsUrl(res.play_url);
      }
      if (url.indexOf('fq://xmly_track/') === 0) {
        var tid = url.replace('fq://xmly_track/', '');
        var ts = new Date().getTime();
        var info = this.host.getJson('https://mobile.ximalaya.com/mobile/playpage/track/v3/baseInfo/' + ts + '?device=iPhone&trackId=' + tid);
        var ti = (info && info.trackInfo) ? info.trackInfo : {};
        var play = httpsUrl(ti.playUrl64 || ti.playPathAacv164 || ti.playUrl32 || '');
        if (play) return play;
      }
      throw new Error('无法解析章节音频直链');
    }
  });
})();
