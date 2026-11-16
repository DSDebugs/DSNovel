/**
 * 解析脚本离线自测：用桩宿主跑 prelude_parser.js + ximalaya_vip_parser.js
 * 不联网；覆盖：元数据注册、付费链路、ep 解密往返、not_vip 归类、免费兜底、Cookie 三来源、checkStatus
 */
const fs = require('fs');
const path = require('path');
const vm = require('vm');

// 目录定位：从脚本所在目录向上找包含 DSNovel/Resources/prelude_parser.js 的项目根
function findProjectRoot(start) {
  let dir = start;
  for (let i = 0; i < 6; i++) {
    if (fs.existsSync(path.join(dir, 'DSNovel', 'Resources', 'prelude_parser.js'))) return dir;
    const parent = path.dirname(dir);
    if (parent === dir) break;
    dir = parent;
  }
  throw new Error('未找到项目根（应包含 DSNovel/Resources/prelude_parser.js）');
}
const ROOT = findProjectRoot(__dirname);
const PRELUDE = path.join(ROOT, 'DSNovel', 'Resources', 'prelude_parser.js');
const PARSER = path.join(ROOT, 'ximalaya_vip_parser.js');
const EP_MODULE = path.join(__dirname, 'ximalaya_ep.js');

// ---------- 加密侧工具（仅测试用：构造合法 ep） ----------
function utf8Encode(str) {
  const out = [];
  for (const ch of str) {
    const cp = ch.codePointAt(0);
    if (cp < 0x80) out.push(cp);
    else if (cp < 0x800) out.push(0xC0 | (cp >> 6), 0x80 | (cp & 0x3F));
    else if (cp < 0x10000) out.push(0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F));
    else out.push(0xF0 | (cp >> 18), 0x80 | ((cp >> 12) & 0x3F), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F));
  }
  return out;
}
function b64encode(bytes) {
  const A = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  let out = '';
  for (let i = 0; i < bytes.length; i += 3) {
    const b0 = bytes[i], b1 = bytes[i + 1], b2 = bytes[i + 2];
    out += A[b0 >> 2];
    out += A[((b0 & 3) << 4) | ((b1 === undefined ? 0 : b1) >> 4)];
    out += b1 === undefined ? '=' : A[((b1 & 15) << 2) | ((b2 === undefined ? 0 : b2) >> 6)];
    out += b2 === undefined ? '=' : A[b2 & 63];
  }
  return out;
}

// ---------- 桩宿主 ----------
const state = {
  prefs: {},
  cache: {},
  logs: [],
  requests: [],
  cookieHeader: '',
  responder: () => { throw new Error('no responder'); }
};

function hostStub(id, name) {
  return {
    getSourceId: () => id,
    userAgent: (d) => (d ? 'desktop-UA' : 'mobile-UA'),
    webViewUA: () => 'mobile-UA',
    request: (url, opts) => JSON.stringify({ v: state.responder(url, opts || {}, name) }),
    requestAll: (urlsJson) => JSON.stringify({ v: JSON.parse(urlsJson).map((u) => state.responder(u, {}, name)) }),
    finalUrl: (url) => JSON.stringify({ v: url }),
    status: () => JSON.stringify({ v: '200' }),
    fetch: (url) => JSON.stringify({ v: { status: 200, body: state.responder(url, {}, name) } }),
    parseHtml: () => null,
    render: () => JSON.stringify({ v: '' }),
    sniff: () => JSON.stringify({ v: '' }),
    cookies: () => state.cookieHeader,
    getPref: (key) => (state.prefs[key] === undefined ? null : state.prefs[key]),
    setPref: (key, value) => { state.prefs[key] = value; },
    toast: () => {},
    log: (msg) => state.logs.push(msg),
    progress: () => {},
    sleep: () => {},
    readCache: (n) => (state.cache[n] === undefined ? null : state.cache[n]),
    writeCache: (n, t) => { state.cache[n] = t; },
    cacheAge: () => -1,
    base64Decode: (v) => Buffer.from(v, 'base64').toString('binary'),
    base64Encode: (v) => Buffer.from(v, 'binary').toString('base64'),
    md5: (v) => require('crypto').createHash('md5').update(v).digest('hex'),
    sha256: (v) => require('crypto').createHash('sha256').update(v).digest('hex'),
    aesEcbDecrypt: (data, key) => {
      // 桩：用固定密钥解开一段 base64(AES-ECB) —— 测试里直接返回预设路径
      if (state.aesPlain !== undefined) return state.aesPlain;
      throw new Error('aes stub not configured');
    },
    uuid: () => 'uuid',
    htmlDecode: (v) => v
  };
}

function buildContext() {
  const ctx = vm.createContext({
    console,
    __bridge: { host: hostStub },
    JSON, Math, Date, String, Number, Boolean, Object, Array, RegExp, Error, isNaN, parseInt, parseFloat
  });
  vm.runInContext(fs.readFileSync(PRELUDE, 'utf8'), ctx, { filename: 'prelude_parser.js' });
  vm.runInContext(fs.readFileSync(PARSER, 'utf8'), ctx, { filename: 'ximalaya_vip_parser.js' });
  return ctx;
}

const results = [];
let rc4KeyBytes = null;
function check(name, fn) {
  try {
    const detail = fn();
    results.push({ name, ok: true, detail: detail === undefined ? '' : String(detail) });
  } catch (e) {
    results.push({ name, ok: false, detail: e && e.message ? e.message : String(e) });
  }
}
function assert(cond, msg) { if (!cond) throw new Error(msg); }

// ---------- 用例 ----------
const ctx = buildContext();

check('1. 注册元数据（__metaParser）', () => {
  const meta = JSON.parse(vm.runInContext('__metaParser()', ctx));
  assert(meta.length === 1, '应注册 1 个解析器，实际 ' + meta.length);
  const m = meta[0];
  assert(m.id === 'ximalaya-vip', 'id 不符：' + m.id);
  assert(m.hosts.indexOf('ximalaya.com') >= 0, '缺少 ximalaya.com 目标');
  assert(m.sourceIDs.indexOf('6e2b9c4d8a1f4d37b5c0e73a9f1d2b64') >= 0, '缺少内置源 sourceID 兜底');
  assert(m.methods.indexOf('resolveAudio') >= 0, '未导出 resolveAudio');
  assert(m.methods.indexOf('checkStatus') >= 0, '未导出 checkStatus');
  assert(m.config.length === 6, '配置项应 6 个，实际 ' + m.config.length);
  return `id=${m.id} v=${m.version} hosts=${m.hosts.join('|')} config=${m.config.map(c => c.key).join(',')}`;
});

// ep 往返（顺带交叉验证解析脚本内联的 EP 实现）：100 组随机明文，经 resolveAudio 观察解出的 4 段
check('2. ep 加解密往返（100 组随机明文）', () => {
  const ref = fs.existsSync(EP_MODULE) ? require(EP_MODULE) : null;
  state.prefs = { cookieSource: 'pref', cookie: '1&_token=fixture' };
  state.aesPlain = 'storages/roundtrip.m4a';
  const alphabet = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  function rand(n) { let s = ''; for (let i = 0; i < n; i++) s += alphabet[Math.floor(Math.random() * alphabet.length)]; return s; }
  let refChecked = 0;
  for (let i = 0; i < 100; i++) {
    const expected = [rand(1 + Math.floor(Math.random() * 12)), rand(1 + Math.floor(Math.random() * 16)),
                      rand(1 + Math.floor(Math.random() * 20)), String(Math.floor(Date.now() / 1000))];
    const plain = expected.join('-');
    const ep = b64encode(rc4Encrypt(utf8Encode(plain)));
    if (ref) {
      assert(ref.epDecrypt(ep) === plain, '独立实现的 epDecrypt 与本用例不一致：' + plain);
      refChecked++;
    }
    state.responder = (url) => {
      if (url.indexOf('/mobile/track/pay') >= 0) {
        return JSON.stringify({ ret: 0, fileId: 'C', ep: ep, domain: 'https://audio.xmcdn.com', duration: 1, title: 't' });
      }
      throw new Error('意外请求：' + url);
    };
    const env = JSON.parse(vm.runInContext(`__invokeParserSafe(0, 'resolveAudio', ${JSON.stringify(JSON.stringify([{ episodeURL: 'xm:1', trackId: '1', quality: 'M4A_48' }]))})`, ctx));
    assert(!env.e, '第 ' + i + ' 组执行报错：' + env.e);
    const url = JSON.parse(env.v).url;
    for (let k = 0; k < 4; k++) {
      const key = ['buy_key', 'sign', 'token', 'timestamp'][k];
      const mapped = k === 2 ? expected[2] : k === 3 ? expected[3] : expected[k];
      assert(url.indexOf('?' + key + '=' + mapped) > 0 || url.indexOf('&' + key + '=' + mapped) > 0,
        `第 ${i} 组 ${key} 不符：期望 ${mapped}，URL=${url}`);
    }
  }
  return `100 组全部一致${refChecked ? `（并与独立实现交叉核对 ${refChecked} 次）` : ''}`;
});

let rc4KeyBytesUnusedGuard = null;
function rc4Encrypt(dataBytes) {
  if (!rc4KeyBytes) {
    // 还原 RC4 密钥：'MZ4uGVu3dvMOKb1k' 经替换表
    const TABLE = [33, 1, 24, 23, 2, 30, 10, 3, 7, 14, 15, 28, 32, 16, 5, 31, 13, 9, 22, 0, 29, 21, 17, 25, 8, 26, 35, 27, 6, 19, 4, 20, 18, 34, 12, 11];
    let key = '';
    const s = 'MZ4uGVu3dvMOKb1k';
    for (let i = 0; i < s.length; i++) {
      const c = s.charAt(i);
      let v = s.charCodeAt(i) - ((c >= 'a' && c <= 'z') ? 97 : 22);
      if (v >= 0 && v < TABLE.length) v = TABLE[v];
      key += String.fromCharCode(v <= 25 ? 97 + v : 22 + v);
    }
    rc4KeyBytes = utf8Encode(key);
  }
  const sbox = [];
  for (let i = 0; i < 256; i++) sbox[i] = i;
  let j = 0;
  for (let i = 0; i < 256; i++) {
    j = (j + sbox[i] + rc4KeyBytes[i % rc4KeyBytes.length]) & 0xFF;
    const t = sbox[i]; sbox[i] = sbox[j]; sbox[j] = t;
  }
  const out = [];
  let a = 0, b = 0;
  for (let n = 0; n < dataBytes.length; n++) {
    a = (a + 1) & 0xFF;
    b = (b + sbox[a]) & 0xFF;
    const t = sbox[a]; sbox[a] = sbox[b]; sbox[b] = t;
    out[n] = dataBytes[n] ^ sbox[(sbox[a] + sbox[b]) & 0xFF];
  }
  return out;
}

const goodEp = b64encode(rc4Encrypt(utf8Encode('BUYKEY-ABC123-TOKENXYZ-1700000000')));

// 3. 付费链路
check('3. 付费接口 → /download/1.0.0/ 直链', () => {
  state.prefs = { cookieSource: 'pref', cookie: '1&_token=fixture; domain=.ximalaya.com' };
  state.cookieHeader = '1&_token=fixture; domain=.ximalaya.com';
  state.aesPlain = 'storages/ab/cd/track.m4a';
  state.responder = (url) => {
    if (url.indexOf('/mobile/track/pay') >= 0) {
      return JSON.stringify({ ret: 0, fileId: 'BASE64CIPHER', ep: goodEp, domain: 'https://audio.xmcdn.com',
        duration: 180000, highestQualityLevel: 'M4A_128', title: '第1集', albumId: 12345, totalLength: 4096000 });
    }
    throw new Error('意外请求：' + url);
  };
  const env = JSON.parse(vm.runInContext(`__invokeParserSafe(0, 'resolveAudio', ${JSON.stringify(JSON.stringify([{ sourceID: 's', episodeURL: 'xm:998877', trackId: '998877', forDownload: false, quality: 'M4A_128' }]))})`, ctx));
  assert(!env.e, '执行报错：' + env.e);
  const res = JSON.parse(env.v);
  assert(res.isPaid === true, 'isPaid 应为 true');
  assert(res.url.indexOf('https://audio.xmcdn.com/download/1.0.0/storages/ab/cd/track.m4a?') === 0, '直链前缀不符：' + res.url);
  assert(res.url.indexOf('buy_key=BUYKEY') > 0 && res.url.indexOf('sign=ABC123') > 0 && res.url.indexOf('token=TOKENXYZ') > 0, '签名参数缺失：' + res.url);
  assert(res.url.indexOf('timestamp=1700000000') > 0, 'timestamp 缺失');
  assert(res.kind === 'onDemand' && res.expiresAt > Math.floor(Date.now() / 1000), 'kind/expiresAt 异常');
  return res.url.slice(0, 96) + '…';
});

// 4. 付费接口 ret=1001 → not_vip
check('4. 付费接口 ret=1001 → reason=not_vip', () => {
  state.aesPlain = undefined;
  state.responder = () => JSON.stringify({ ret: 1001, msg: '该专辑需要购买后才能收听' });
  const env = JSON.parse(vm.runInContext(`__invokeParserSafe(0, 'resolveAudio', ${JSON.stringify(JSON.stringify([{ episodeURL: 'xm:1', trackId: '1', quality: 'M4A_128' }]))})`, ctx));
  assert(env.e, '应当抛错');
  assert(env.r === 'not_vip', 'reason 应为 not_vip，实际 ' + env.r);
  return 'reason=' + env.r + ' msg=' + env.e;
});

// 5. 付费失败 → 免费接口兜底
check('5. 付费失败 → 免费接口兜底', () => {
  state.aesPlain = 'storages/xx.m4a';
  state.responder = (url) => {
    if (url.indexOf('/mobile/track/pay') >= 0) return JSON.stringify({ ret: 0, fileId: '', ep: '' });
    if (url.indexOf('/fmobile/track/playpage') >= 0) {
      return JSON.stringify({ ret: 0, trackInfo: { playPathAacv164: '//audio.xmcdn.com/free/track.m4a', playUrl64: 'http://a/b.m4a', title: '试听', duration: 60000, albumId: 9, downloadSize: 1234 } });
    }
    throw new Error('意外请求：' + url);
  };
  const env = JSON.parse(vm.runInContext(`__invokeParserSafe(0, 'resolveAudio', ${JSON.stringify(JSON.stringify([{ episodeURL: 'xm:5', trackId: '5', quality: 'M4A_128' }]))})`, ctx));
  assert(!env.e, '执行报错：' + env.e);
  const res = JSON.parse(env.v);
  assert(res.isPaid === false, 'isPaid 应为 false');
  assert(res.url === 'https://m.ximalaya.com//audio.xmcdn.com/free/track.m4a' || res.url.indexOf('xmcdn.com/free/track.m4a') > 0, '免费直链异常：' + res.url);
  assert(res.quality === 'M4A_128', '音质标注应为 M4A_128，实际 ' + res.quality);
  return res.url;
});

// 6. Cookie 三来源：user 无登录态 → 不误用匿名 Cookie
check('6. Cookie 判定：匿名 Cookie 不算登录态', () => {
  state.prefs = { cookieSource: 'user' };
  state.cookieHeader = 'channel=ios-b1; impl=com.ximalaya.tingLite'; // 无 1&_token
  const env = JSON.parse(vm.runInContext(`__invokeParserSafe(0, 'resolveAudio', ${JSON.stringify(JSON.stringify([{ episodeURL: 'xm:6', trackId: '6' }]))})`, ctx));
  assert(env.e, '应当抛错');
  assert(env.r === 'no_cookie', 'reason 应为 no_cookie，实际 ' + env.r);
  return 'reason=' + env.r;
});

// 7. checkStatus：读用户信息 + 会员到期
check('7. checkStatus（桩用户信息）', () => {
  state.prefs = { cookieSource: 'user', sampleTrackId: '' };
  state.cookieHeader = '1&_token=fixture';
  state.responder = (url) => {
    if (url.indexOf('/revision/main/getCurrentUser') >= 0) {
      return JSON.stringify({ ret: 200, data: { nickname: '测试会员', vipInfo: { expireTime: 1794671999000 } } });
    }
    throw new Error('意外请求：' + url);
  };
  const env = JSON.parse(vm.runInContext(`__invokeParserSafe(0, 'checkStatus', '[]')`, ctx));
  assert(!env.e, '执行报错：' + env.e);
  const res = JSON.parse(env.v);
  assert(res.ok === true, 'ok 应为 true');
  assert(res.nickname === '测试会员', '昵称不符：' + res.nickname);
  assert(/^(\d{4}-\d{2}-\d{2}|已过期\(\d{4}-\d{2}-\d{2}\))$/.test(res.vipExpireAt), '到期时间格式异常：' + res.vipExpireAt);
  return `${res.nickname} · ${res.vipExpireAt} · ${res.latencyMs}ms`;
});

// 8. 远端共享 Cookie 默认关闭
check('8. 远端共享 Cookie 默认关闭', () => {
  state.prefs = { cookieSource: 'user' };
  state.cookieHeader = '';
  state.cache = {};
  let touchedRemote = false;
  state.responder = (url) => { if (url.indexOf('raw.githubusercontent') >= 0) touchedRemote = true; return '{}'; };
  const env = JSON.parse(vm.runInContext(`__invokeParserSafe(0, 'resolveAudio', ${JSON.stringify(JSON.stringify([{ episodeURL: 'xm:7', trackId: '7' }]))})`, ctx));
  assert(env.e, '应当抛错');
  assert(!touchedRemote, '默认不应访问远端共享 Cookie 地址');
  return '未访问远端，reason=' + env.r;
});

// 9. 显式开启远端后可取到共享 Cookie
check('9. 显式开启远端共享 Cookie', () => {
  state.prefs = { cookieSource: 'remote', allowRemoteCookie: 'true' };
  state.cookieHeader = '';
  state.cache = {};
  state.aesPlain = 'storages/remote.m4a';
  state.responder = (url) => {
    if (url.indexOf('raw.githubusercontent') >= 0) return JSON.stringify({ cookie: '1&_token=shared; domain=.ximalaya.com' });
    if (url.indexOf('/mobile/track/pay') >= 0) {
      return JSON.stringify({ ret: 0, fileId: 'C', ep: goodEp, domain: 'https://audio.xmcdn.com', duration: 1000, title: 't' });
    }
    throw new Error('意外请求：' + url);
  };
  const env = JSON.parse(vm.runInContext(`__invokeParserSafe(0, 'resolveAudio', ${JSON.stringify(JSON.stringify([{ episodeURL: 'xm:8', trackId: '8' }]))})`, ctx));
  assert(!env.e, '执行报错：' + env.e);
  assert(state.cache['remote_cookie.json'], '应缓存远端 Cookie');
  return '已取到并缓存远端 Cookie';
});

// ---------- 输出 ----------
let passed = 0;
for (const r of results) {
  if (r.ok) passed++;
  console.log(`${r.ok ? 'PASS' : 'FAIL'}  ${r.name}${r.detail ? '  → ' + r.detail : ''}`);
}
console.log(`\n结果：${passed}/${results.length} 通过`);
console.log('解析脚本日志（前 8 条）：');
state.logs.slice(0, 8).forEach((l) => console.log('  · ' + l));
process.exit(passed === results.length ? 0 : 1);
