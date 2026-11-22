// 内置解析器公共引导脚本（宿主在加载解析脚本之前执行）
// 与书源 prelude.js 相互独立：这里只服务 registerBuiltinParser，不注册书源。
var __parsers = [];

// ---------- 取值与工具 ----------

/** 按路径读取，如 at(json, 'data.list.0.name')；数组下标可为负数 */
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

function bool(obj, path, def) {
  var v = (path === undefined || path === null) ? obj : at(obj, path);
  if (v === null || v === undefined) return def === undefined ? false : def;
  if (typeof v === 'boolean') return v;
  var s = String(v).toLowerCase();
  if (s === 'true' || s === '1' || s === 'yes') return true;
  if (s === 'false' || s === '0' || s === 'no' || s === '') return false;
  return def === undefined ? false : def;
}

function items(obj, path) {
  var v = (path === undefined || path === null) ? obj : at(obj, path);
  return Array.isArray(v) ? v.filter(function (x) { return x !== null && x !== undefined; }) : [];
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

/** 构造带语义 reason 码的错误，宿主会把它映射成「解析失败（原因）」文案 */
function parserError(reason, message) {
  var err = new Error(message || reason);
  err.reason = reason;
  return err;
}

// ---------- host 封装（最小权限暴露面，D-09 / H-06） ----------

function __makeParserHost(j) {
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
  function s(v) { return v === null || v === undefined ? null : String(v); }

  return {
    sourceId: String(j.getSourceId()),
    userAgent: function (desktop) { return j.userAgent(!!desktop); },
    webViewUA: function () { return j.webViewUA ? String(j.webViewUA() || '') : ''; },
    getString: function (url, o) { return un(j.request(String(url), opt(o))); },
    getJson: function (url, o) { return parseJson(un(j.request(String(url), opt(o)))); },
    cookies: function (url) { return j.cookies(String(url)); },
    getPref: function (key, def) {
      var v = j.getPref(String(key));
      return (v === null || v === undefined || v === '') ? (def === undefined ? null : def) : v;
    },
    setPref: function (key, value) { j.setPref(String(key), s(value)); },
    log: function (msg) { j.log(String(msg)); },
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
}

// ---------- 注册与调用契约 ----------

function __validateStringArray(arr, fieldName) {
  if (arr === undefined || arr === null) return [];
  if (!Array.isArray(arr)) {
    throw new Error('registerBuiltinParser：targets.' + fieldName + ' 必须为字符串数组');
  }
  var out = [];
  for (var i = 0; i < arr.length; i++) {
    if (typeof arr[i] !== 'string' || !arr[i].trim()) {
      throw new Error('registerBuiltinParser：targets.' + fieldName + ' 必须为非空字符串数组');
    }
    out.push(arr[i].trim());
  }
  return out;
}

/** AUD-13：初始化时通过局部闭包捕获 this.__bridge，宿主在执行用户脚本前立即 delete this.__bridge */
var registerBuiltinParser = (function (root) {
  var capturedBridge = root && root.__bridge;
  return function registerBuiltinParser(parser) {
    if (!parser || !parser.id || !parser.name) {
      throw new Error('registerBuiltinParser：缺少 id 或 name');
    }
    if (typeof parser.resolveAudio !== 'function') {
      throw new Error('registerBuiltinParser：必须实现 resolveAudio(request)');
    }
    if (!parser.targets || typeof parser.targets !== 'object') {
      throw new Error('registerBuiltinParser：必须在 targets 中声明 hosts 或 sourceIDs');
    }
    var hosts = __validateStringArray(parser.targets.hosts, 'hosts');
    var sourceIDs = __validateStringArray(parser.targets.sourceIDs, 'sourceIDs');
    var networkHosts = __validateStringArray(parser.targets.networkHosts, 'networkHosts');
    if (hosts.length === 0 && sourceIDs.length === 0) {
      throw new Error('registerBuiltinParser：必须在 targets 中声明 hosts 或 sourceIDs');
    }
    parser.targets = { hosts: hosts, sourceIDs: sourceIDs, networkHosts: networkHosts };
    if (__parsers.length > 0) {
      throw new Error('registerBuiltinParser：每个脚本仅支持注册一个内置解析器');
    }
    if (!capturedBridge || typeof capturedBridge.host !== 'function') {
      throw new Error('registerBuiltinParser：宿主桥接不可用');
    }
    parser.host = __makeParserHost(capturedBridge.host(String(parser.id), String(parser.name)));
    parser.config = parser.config || [];
    parser.version = parser.version || '1.0.0';
    __parsers.push(parser);
    return parser;
  };
})(this);

/** 返回解析器元数据（宿主用它生成 meta.json，不执行任何网络请求） */
function __metaParser() {
  return JSON.stringify(__parsers.map(function (p) {
    var methods = [];
    for (var k in p) {
      if (k === 'host') continue;
      if (typeof p[k] === 'function') methods.push(k);
    }
    var caps = p.capabilities || {};
    return {
      id: String(p.id),
      name: String(p.name),
      version: String(p.version || '1.0.0'),
      author: String(p.author || ''),
      summary: String(p.description || p.summary || ''),
      hosts: (p.targets && p.targets.hosts) || [],
      networkHosts: __validateStringArray(p.networkHosts || (p.targets && p.targets.networkHosts), 'networkHosts'),
      sourceIDs: (p.targets && p.targets.sourceIDs) || [],
      /** 解析器声明的音质档位（语义档位 id 列表，如 ['auto','saver','standard','high','lossless']） */
      qualities: Array.isArray(p.qualities) ? p.qualities : [],
      supportsPlayback: caps.playback !== false,
      supportsDownload: caps.download !== false,
      requiresCookie: caps.needsCookie !== false,
      config: (p.config || []).map(function (c) {
        return {
          key: String(c.key),
          title: String(c.title || c.key),
          defaultValue: String(c.defaultValue === undefined ? '' : c.defaultValue),
          kind: String(c.kind || 'text'),
          options: Array.isArray(c.options) ? c.options : []
        };
      }),
      methods: methods
    };
  }));
}

function __invokeParser(index, name, argsJson) {
  var p = __parsers[index];
  if (!p) return null;
  var f = p[name];
  if (typeof f !== 'function') return null;
  var r = f.apply(p, JSON.parse(argsJson));
  return (r === undefined || r === null) ? null : JSON.stringify(r);
}

function __invokeParserSafe(index, name, argsJson) {
  try {
    return JSON.stringify({ v: __invokeParser(index, name, argsJson) });
  } catch (e) {
    return JSON.stringify({
      e: String((e && e.message) || e),
      c: !!(e && e.cancelled),
      r: (e && e.reason) ? String(e.reason) : ''
    });
  }
}
