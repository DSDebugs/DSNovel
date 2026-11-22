// 宿主在加载插件脚本之前执行的公共引导脚本：registerSource、host 封装与路径取值辅助函数
var __sources = [];

/** 按路径读取，如 at(json, 'data.list.0.name')；数组下标可以为负数 */
function at(obj, path) {
  if (obj === null || obj === undefined) return null;
  var parts = String(path).split('.');
  for (var i = 0; i < parts.length; i++) {
    var k = parts[i];
    if (k === '') continue;
    if (obj === null || obj === undefined) return null;
    if (Array.isArray(obj)) {
      var n = parseInt(k, 10);
      if (isNaN(n)) return null;
      if (n < 0) n += obj.length;
      obj = obj[n];
    } else if (typeof obj === 'object') {
      obj = obj[k];
    } else {
      return null;
    }
  }
  return obj === undefined ? null : obj;
}

/** 读取字符串（数字、布尔也会转成字符串），不存在返回空字符串 */
function str(obj, path) {
  var v = (path === undefined || path === null) ? obj : at(obj, path);
  if (v === null || v === undefined) return '';
  return typeof v === 'object' ? JSON.stringify(v) : String(v);
}

function int(obj, path, def) {
  var n = parseInt(str(obj, path), 10);
  return isNaN(n) ? (def === undefined ? 0 : def) : n;
}

/** 读取数组，不存在返回空数组 */
function items(obj, path) {
  var v = (path === undefined || path === null) ? obj : at(obj, path);
  return Array.isArray(v) ? v.filter(function (x) { return x !== null && x !== undefined; }) : [];
}

/** 用正则取第一个分组并转成整数 */
function regexInt(input, re, def) {
  var m = re.exec(input || '');
  var n = m ? parseInt(m[1], 10) : NaN;
  return isNaN(n) ? (def === undefined ? 1 : def) : n;
}

/** AUD-89：解析 JSON，仅剥离 BOM / XSSI ()]}' ) / 合法 JSONP 回调后解析，禁止盲目截取任意文本中的 [...] */
function parseJson(text) {
  text = String(text === undefined || text === null ? '' : text);
  if (text.charCodeAt(0) === 0xFEFF) {
    text = text.slice(1);
  }
  text = text.trim();
  if (text.indexOf(")]}'") === 0) {
    text = text.replace(/^\)\]\}'[,\s]*/, '').trim();
  }
  try {
    return JSON.parse(text);
  } catch (e) {}
  var m = /^[a-zA-Z_$][\w$.]*\s*\(([\s\S]*)\)\s*;?\s*(?:\/\*[\s\S]*?\*\/\s*|\/\/[^\n]*\s*)*$/.exec(text);
  if (m) {
    return JSON.parse(m[1].trim());
  }
  throw new SyntaxError('Invalid JSON payload');
}

var __nullNode = {
  __isWrappedNode: true,
  exists: function () { return false; },
  text: function () { return ''; },
  ownText: function () { return ''; },
  html: function () { return ''; },
  attr: function () { return ''; },
  absUrl: function () { return ''; },
  tagName: function () { return ''; },
  children: function () { return __wrapList([]); },
  select: function () { return __wrapList([]); },
  first: function () { return __nullNode; },
  selectFirst: function () { return null; }
};

function __wrapList(rawList) {
  var arr = [];
  if (rawList) {
    var len = typeof rawList.length === 'number' ? rawList.length : (typeof rawList.size === 'function' ? rawList.size() : 0);
    var hasGet = typeof rawList.get === 'function';
    for (var i = 0; i < len; i++) {
      var item = hasGet ? rawList.get(i) : rawList[i];
      if (item !== null && item !== undefined) arr.push(__wrapNode(item));
    }
  }
  arr.size = function () { return arr.length; };
  arr.get = function (i) { return (i >= 0 && i < arr.length) ? arr[i] : __nullNode; };
  arr.first = function () { return arr.length > 0 ? arr[0] : __nullNode; };
  arr.last = function () { return arr.length > 0 ? arr[arr.length - 1] : __nullNode; };
  arr.text = function () {
    var parts = [];
    for (var i = 0; i < arr.length; i++) {
      var t = arr[i].text();
      if (t) parts.push(t);
    }
    return parts.join(' ').trim();
  };
  arr.attr = function (name) {
    for (var i = 0; i < arr.length; i++) {
      var v = arr[i].attr(name);
      if (v) return v;
    }
    return '';
  };
  arr.select = function (css) {
    var out = [];
    for (var i = 0; i < arr.length; i++) {
      var sub = arr[i].select(css);
      for (var k = 0; k < sub.length; k++) out.push(sub[k]);
    }
    return __wrapList(out);
  };
  return arr;
}

function __wrapNode(raw) {
  if (!raw) return __nullNode;
  if (raw.__isWrappedNode) return raw;
  return {
    __isWrappedNode: true,
    exists: function () { return true; },
    text: function () { return typeof raw.text === 'function' ? String(raw.text() || '') : ''; },
    ownText: function () { return typeof raw.ownText === 'function' ? String(raw.ownText() || '') : ''; },
    html: function () { return typeof raw.html === 'function' ? String(raw.html() || '') : ''; },
    attr: function (name) { return typeof raw.attr === 'function' ? String(raw.attr(String(name)) || '') : ''; },
    absUrl: function (name) { return typeof raw.absUrl === 'function' ? String(raw.absUrl(String(name)) || '') : ''; },
    tagName: function () { return typeof raw.tagName === 'function' ? String(raw.tagName() || '') : ''; },
    children: function () { return __wrapList(typeof raw.children === 'function' ? raw.children() : []); },
    select: function (css) { return __wrapList(typeof raw.select === 'function' ? raw.select(String(css)) : []); },
    first: function (css) {
      var hit = typeof raw.selectFirst === 'function' ? raw.selectFirst(String(css)) : null;
      return hit ? __wrapNode(hit) : __nullNode;
    },
    selectFirst: function (css) {
      var hit = typeof raw.selectFirst === 'function' ? raw.selectFirst(String(css)) : null;
      return hit ? __wrapNode(hit) : null;
    }
  };
}

function __makeHost(j) {
  function un(s) {
    var r = JSON.parse(s);
    if (r.e !== undefined) {
      var err = new Error(r.e);
      var m = /^HTTP (\d+)/.exec(r.e);
      if (m) err.status = parseInt(m[1], 10);
      if (r.c) err.cancelled = true;
      throw err;
    }
    return r.v;
  }
  function opt(o) { return o ? JSON.stringify(o) : null; }
  function fn(o, name) { return o && typeof o[name] === 'function' ? o[name] : null; }
  function s(v) { return v === null || v === undefined ? null : String(v); }

  var h = {
    sourceId: String(j.getSourceId()),
    userAgent: function (desktop) { return j.userAgent(!!desktop); },
    webViewUA: function () { try { return j.webViewUA ? String(j.webViewUA() || '') : ''; } catch (e) { return ''; } },
    getString: function (url, o) { return un(j.request(String(url), opt(o))); },
    getHtml: function (url, o) { return __wrapNode(j.parseHtml(h.getString(url, o), String(url))); },
    getJson: function (url, o) { return parseJson(h.getString(url, o)); },
    getStrings: function (urls, o, concurrency) { return un(j.requestAll(JSON.stringify(urls), opt(o), concurrency || 4)); },
    finalUrl: function (url, o) { return un(j.finalUrl(String(url), opt(o))); },
    fetch: function (url, o) { return un(j.fetch(String(url), opt(o))); },
    status: function (url, o) { return un(j.status(String(url), opt(o))); },
    parseHtml: function (html, baseUrl) { return __wrapNode(j.parseHtml(String(html), s(baseUrl))); },
    render: function (url, o) { return un(j.render(String(url), opt(o), fn(o, 'parse'))); },
    sniff: function (url, o) { return un(j.sniff(String(url), opt(o), fn(o, 'validate'))); },
    cookies: function (url) { return j.cookies(String(url)); },
    playsAnyDownload: true,
    getPref: function (key, def) {
      var v = j.getPref(String(key));
      return (v === null || v === undefined || v === '') ? (def === undefined ? null : def) : v;
    },
    setPref: function (key, value) { j.setPref(String(key), s(value)); },
    toast: function (msg) { j.toast(String(msg)); },
    log: function (msg) { j.log(String(msg)); },
    progress: function (info) { j.progress(s(info)); },
    sleep: function (ms) { j.sleep(Math.max(0, Math.round(ms))); },
    readCache: function (name) {
      var v = j.readCache(String(name));
      return v === undefined ? null : v;
    },
    writeCache: function (name, text) { j.writeCache(String(name), String(text)); },
    cacheAge: function (name) { return j.cacheAge(String(name)); },
    base64Decode: function (v) { return j.base64Decode(String(v)); },
    base64Encode: function (v) { return j.base64Encode(String(v)); },
    md5: function (v) { return j.md5(String(v)); },
    sha256: function (v) { return j.sha256(String(v)); },
    aesEcbDecrypt: function (data, key) { return j.aesEcbDecrypt(String(data), String(key)); },
    uuid: function () { return j.uuid(); },
    htmlDecode: function (v) { return j.htmlDecode(String(v)); }
  };
  return h;
}

/** AUD-13：初始化时通过局部闭包捕获 this.__bridge，宿主在执行用户脚本前立即 delete this.__bridge */
var registerSource = (function (root) {
  var capturedBridge = root && root.__bridge;
  return function registerSource(source) {
    if (!source || !source.id || !source.name) throw new Error('registerSource：缺少 id 或 name');
    if (!capturedBridge || typeof capturedBridge.host !== 'function') {
      throw new Error('registerSource：宿主桥接不可用');
    }
    source.host = __makeHost(capturedBridge.host(String(source.id), String(source.name)));
    var sid = String(source.id);
    for (var i = 0; i < __sources.length; i++) {
      if (String(__sources[i].id) === sid) {
        __sources[i] = source;
        return source;
      }
    }
    __sources.push(source);
    return source;
  };
})(this);

function __meta() {
  return JSON.stringify(__sources.map(function (src) {
    var meta = { methods: [] };
    for (var k in src) {
      if (k === 'host') continue;
      if (typeof src[k] === 'function') meta.methods.push(k);
      else meta[k] = src[k];
    }
    return meta;
  }));
}

function __findSourceById(sourceId) {
  if (!sourceId) return __sources[0] || null;
  for (var i = 0; i < __sources.length; i++) {
    if (String(__sources[i].id) === String(sourceId)) return __sources[i];
  }
  return null;
}

function __resolveMethodOn(src, name) {
  if (typeof src[name] === 'function') return src[name];
  var aliases = {
    discoverCategories: ['categoryMenus'],
    categoryMenus: ['discoverCategories'],
    discover: ['categoryPage'],
    categoryPage: ['discover'],
    detail: ['bookDetail'],
    bookDetail: ['detail']
  };
  var list = aliases[name] || [];
  for (var i = 0; i < list.length; i++) {
    if (typeof src[list[i]] === 'function') return src[list[i]];
  }
  return null;
}

function __invoke(index, name, argsJson) {
  var src = __sources[index];
  if (!src) return JSON.stringify({ __dsMissingMethod: name });
  var f = __resolveMethodOn(src, name);
  if (typeof f !== 'function') return JSON.stringify({ __dsMissingMethod: name });
  try {
    var r = f.apply(src, JSON.parse(argsJson));
    return (r === undefined || r === null) ? null : JSON.stringify(r);
  } catch (e) {
    return JSON.stringify({
      __dsError: String((e && e.message) || e),
      __dsCancelled: !!(e && e.cancelled)
    });
  }
}

function __invokeById(sourceId, name, argsJson) {
  var src = __findSourceById(sourceId);
  if (!src) return JSON.stringify({ __dsMissingMethod: name });
  var f = __resolveMethodOn(src, name);
  if (typeof f !== 'function') return JSON.stringify({ __dsMissingMethod: name });
  try {
    var r = f.apply(src, JSON.parse(argsJson));
    return (r === undefined || r === null) ? null : JSON.stringify(r);
  } catch (e) {
    return JSON.stringify({
      __dsError: String((e && e.message) || e),
      __dsCancelled: !!(e && e.cancelled)
    });
  }
}
