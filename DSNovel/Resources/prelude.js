// 宿主在加载插件脚本之前执行的公共引导脚本：registerSource、host 封装与路径取值辅助函数
var __sources = [];

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

function str(obj, path) {
  var v = (path === undefined || path === null) ? obj : at(obj, path);
  if (v === null || v === undefined) return '';
  return typeof v === 'object' ? JSON.stringify(v) : String(v);
}

function int(obj, path, def) {
  var n = parseInt(str(obj, path), 10);
  return isNaN(n) ? (def === undefined ? 0 : def) : n;
}

function items(obj, path) {
  var v = (path === undefined || path === null) ? obj : at(obj, path);
  return Array.isArray(v) ? v.filter(function (x) { return x !== null && x !== undefined; }) : [];
}

function regexInt(input, re, def) {
  var m = re.exec(input || '');
  var n = m ? parseInt(m[1], 10) : NaN;
  return isNaN(n) ? (def === undefined ? 1 : def) : n;
}

function parseJson(text) {
  text = String(text).trim();
  var c = text.charAt(0);
  if (c !== '{' && c !== '[') {
    var l = text.search(/[{[]/);
    var r = Math.max(text.lastIndexOf('}'), text.lastIndexOf(']'));
    if (l >= 0 && r > l) text = text.substring(l, r + 1);
  }
  return JSON.parse(text);
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
    getHtml: function (url, o) { return j.parseHtml(h.getString(url, o), String(url)); },
    getJson: function (url, o) { return parseJson(h.getString(url, o)); },
    getStrings: function (urls, o, concurrency) { return un(j.requestAll(JSON.stringify(urls), opt(o), concurrency || 4)); },
    finalUrl: function (url, o) { return un(j.finalUrl(String(url), opt(o))); },
    fetch: function (url, o) { return un(j.fetch(String(url), opt(o))); },
    status: function (url, o) { return un(j.status(String(url), opt(o))); },
    parseHtml: function (html, baseUrl) { return j.parseHtml(String(html), s(baseUrl)); },
    render: function (url, o) { return un(j.render(String(url), opt(o), fn(o, 'parse'))); },
    sniff: function (url, o) { return un(j.sniff(String(url), opt(o), fn(o, 'validate'))); },
    cookies: function (url) { return j.cookies(String(url)); },
    playsAnyDownload: true,
    getPref: function (key, def) { var v = j.getPref(String(key)); return v === null ? (def === undefined ? null : def) : v; },
    setPref: function (key, value) { j.setPref(String(key), s(value)); },
    toast: function (msg) { j.toast(String(msg)); },
    log: function (msg) { j.log(String(msg)); },
    progress: function (info) { j.progress(s(info)); },
    sleep: function (ms) { j.sleep(Math.max(0, Math.round(ms))); },
    readCache: function (name) { return j.readCache(String(name)); },
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

function registerSource(source) {
  if (!source || !source.id || !source.name) throw new Error('registerSource：缺少 id 或 name');
  source.host = __makeHost(__bridge.host(String(source.id), String(source.name)));
  __sources.push(source);
  return source;
}

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

function __invoke(index, name, argsJson) {
  var src = __sources[index];
  if (!src) return null;
  var f = src[name];
  if (typeof f !== 'function') return null;
  var r = f.apply(src, JSON.parse(argsJson));
  return (r === undefined || r === null) ? null : JSON.stringify(r);
}
