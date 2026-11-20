/**
 * 解析脚本离线自测（v1.2）：用桩宿主跑 prelude_parser.js + ximalaya_vip_parser.js
 * 不联网。覆盖：
 *   元数据注册（v1.2：qualities 声明 + config 只剩 sampleTrackId）
 *   ep 加解密往返（100 组随机明文，与独立实现交叉核对）
 *   请求顺序（免费/试听优先 → 付费链路）、付费直链完整性、not_vip 归类
 *   档位映射：5 个语义档位码 + 7 个旧码 + 未识别码（最接近，并列向上）
 *   逐级回落（ATMOS_24 → FLAC_24 → FLAC_16 → M4A_128）
 *   免费兜底按档取流（saver/standard/high/lossless）+ 如实标注 quality + qualityLevel 按档填
 *   Cookie 来源（user/pref/remote 兜底/远端缓存）、checkStatus（lastTrackId 探测）
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

// 路径解析核对：测试实际加载的是哪一个脚本文件
console.log(`夹具路径核对：ROOT=${ROOT}`);
console.log(`  prelude = ${PRELUDE}  (exists=${fs.existsSync(PRELUDE)})`);
console.log(`  parser  = ${PARSER}  (exists=${fs.existsSync(PARSER)})`);
console.log(`  ep 参考 = ${EP_MODULE}  (exists=${fs.existsSync(EP_MODULE)})`);
console.log(`  node    = ${process.version}\n`);

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
const allLogs = [];
const state = {
  prefs: {},
  cache: {},
  logs: [],
  requests: [],
  cookieHeader: '',
  aesPlain: undefined,
  responder: () => { throw new Error('no responder'); }
};

/** 每个用例开始时重置桩状态，保证用例之间互不污染 */
function reset(setup) {
  setup = setup || {};
  state.prefs = Object.assign({}, setup.prefs || {});
  state.cache = Object.assign({}, setup.cache || {});
  state.logs = [];
  state.requests = [];
  state.cookieHeader = setup.cookieHeader || '';
  state.aesPlain = setup.aesPlain;
  state.responder = setup.responder || (() => { throw new Error('no responder'); });
}

function hostStub(id, name) {
  return {
    getSourceId: () => id,
    userAgent: (d) => (d ? 'desktop-UA' : 'mobile-UA'),
    webViewUA: () => 'mobile-UA',
    request: (url, opts) => {
      state.requests.push(String(url));
      return JSON.stringify({ v: state.responder(String(url), opts || {}, name) });
    },
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
    log: (msg) => { state.logs.push(msg); allLogs.push(msg); },
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
      // 桩：不解真 AES，直接返回预设路径
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

// ---------- 用例骨架 ----------
const ctx = buildContext();

function invoke(name, args) {
  const payload = JSON.stringify(JSON.stringify(args === undefined ? [] : args));
  return JSON.parse(vm.runInContext(`__invokeParserSafe(0, '${name}', ${payload})`, ctx));
}
const resolveAudio = (req) => invoke('resolveAudio', [req]);
const checkStatus = () => invoke('checkStatus', []);

const FREE_MARK = '/fmobile/track/playpage';
const PAY_MARK = '/mobile/track/pay';
const payLevels = () => state.requests.filter((u) => u.indexOf(PAY_MARK) >= 0)
  .map((u) => { const m = /trackQualityLevel=(\d+)/.exec(u); return m ? m[1] : '?'; });
const freeLevels = () => state.requests.filter((u) => u.indexOf(FREE_MARK) >= 0)
  .map((u) => { const m = /[?&]qualityLevel=(\d+)/.exec(u); return m ? m[1] : '?'; });
const logHas = (re) => state.logs.some((l) => re.test(l));

function freeTrackInfo(fields) {
  return JSON.stringify({ ret: 0, trackInfo: Object.assign({
    title: '试听', duration: 60000, albumId: 9, downloadSize: 1234
  }, fields) });
}
const FREE_REFUSE = JSON.stringify({ ret: 101, msg: '免费接口不可用' });

// ---------- 用例 1：元数据（v1.2） ----------
check('1. 元数据：id/name/version 1.2.0 + qualities + config 只剩 sampleTrackId', () => {
  const meta = JSON.parse(vm.runInContext('__metaParser()', ctx));
  assert(meta.length === 1, '应注册 1 个解析器，实际 ' + meta.length);
  const m = meta[0];
  assert(m.id === 'ximalaya-vip', 'id 不符：' + m.id);
  assert(m.name === '喜马拉雅 VIP 解析', 'name 不符：' + m.name);
  assert(m.version === '1.2.0', '版本应为 1.2.0，实际 ' + m.version);
  assert(m.hosts.indexOf('ximalaya.com') >= 0, '缺少 ximalaya.com 目标');
  assert(m.sourceIDs.indexOf('6e2b9c4d8a1f4d37b5c0e73a9f1d2b64') >= 0, '缺少内置源 sourceID 兜底');
  assert(m.methods.indexOf('resolveAudio') >= 0, '未导出 resolveAudio');
  assert(m.methods.indexOf('checkStatus') >= 0, '未导出 checkStatus');

  const keys = m.config.map((c) => c.key);
  assert(m.config.length === 1, 'config 应只剩 1 项，实际 ' + m.config.length + ' [' + keys.join(',') + ']');
  assert(keys[0] === 'sampleTrackId', 'config 唯一项应为 sampleTrackId，实际 ' + keys[0]);
  ['quality', 'cookieSource', 'allowRemoteCookie', 'remoteCookieURL', 'linkTTL'].forEach((k) => {
    assert(keys.indexOf(k) < 0, '不应再声明配置项 ' + k);
  });

  const declared = JSON.parse(vm.runInContext(
    'JSON.stringify({q: __parsers[0].qualities, caps: __parsers[0].capabilities, cfg: __parsers[0].config.length})', ctx));
  assert(JSON.stringify(declared.q) === JSON.stringify(['auto', 'saver', 'standard', 'high', 'lossless']),
    'qualities 声明不符：' + JSON.stringify(declared.q));
  assert(declared.caps.playback === true && declared.caps.download === true && declared.caps.needsCookie === true,
    'capabilities 不符：' + JSON.stringify(declared.caps));
  assert(declared.cfg === 1, '注册对象上的 config 也只有 1 项');
  return `id=${m.id} v=${m.version} qualities=${declared.q.join('/')} config=${keys.join(',')}`;
});

// ---------- 用例 2：ep 加解密往返（100 组） ----------
check('2. ep 加解密往返（100 组随机明文）', () => {
  const ref = fs.existsSync(EP_MODULE) ? require(EP_MODULE) : null;
  reset({ prefs: { cookie: '1&_token=fixture' }, aesPlain: 'storages/roundtrip.m4a' });
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
      if (url.indexOf(PAY_MARK) >= 0) {
        return JSON.stringify({ ret: 0, fileId: 'C', ep: ep, domain: 'https://audio.xmcdn.com', duration: 1, title: 't' });
      }
      throw new Error('意外请求：' + url);
    };
    const env = resolveAudio({ episodeURL: 'xm:1', trackId: '1', quality: 'M4A_48' });
    assert(!env.e, '第 ' + i + ' 组执行报错：' + env.e);
    const url = JSON.parse(env.v).url;
    for (let k = 0; k < 4; k++) {
      const key = ['buy_key', 'sign', 'token', 'timestamp'][k];
      assert(url.indexOf('?' + key + '=' + expected[k]) > 0 || url.indexOf('&' + key + '=' + expected[k]) > 0,
        `第 ${i} 组 ${key} 不符：期望 ${expected[k]}，URL=${url}`);
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

const PAID_OK = JSON.stringify({
  ret: 0, fileId: 'BASE64CIPHER', ep: goodEp, domain: 'https://audio.xmcdn.com',
  duration: 180000, highestQualityLevel: 'M4A_128', title: '第1集', albumId: 12345, totalLength: 4096000
});

// ---------- 用例 3：请求顺序（high 优先走付费直达 1 次，standard 先免费再付费） ----------
check('3. 请求顺序：high 优先付费直达 + standard 先免费后付费', () => {
  reset({ prefs: { cookie: '1&_token=fixture; domain=.ximalaya.com' }, aesPlain: '/storages/ab/cd/track.m4a' });
  state.responder = (url) => {
    if (url.indexOf(FREE_MARK) >= 0) return FREE_REFUSE;
    if (url.indexOf(PAY_MARK) >= 0) return PAID_OK;
    throw new Error('意外请求：' + url);
  };
  const env = resolveAudio({ sourceID: 's', episodeURL: 'xm:998877', trackId: '998877', forDownload: false, quality: 'high' });
  assert(!env.e, '执行报错：' + env.e);
  const res = JSON.parse(env.v);
  assert(state.requests.length === 1, 'high 应优先走付费直达 1 次请求，实际 ' + state.requests.length + '：' + state.requests.join(' | '));
  assert(state.requests[0].indexOf(PAY_MARK) >= 0, '第 1 次请求应是付费接口：' + state.requests[0]);
  assert(payLevels()[0] === '1', 'high 应请求 trackQualityLevel=1，实际 ' + payLevels()[0]);
  assert(res.isPaid === true, 'isPaid 应为 true');
  assert(res.url.indexOf('https://audio.xmcdn.com/download/1.0.0/storages/ab/cd/track.m4a?') === 0, '直链前缀不应出现双斜杠：' + res.url);
  assert(res.url.indexOf('buy_key=BUYKEY') > 0 && res.url.indexOf('sign=ABC123') > 0 && res.url.indexOf('token=TOKENXYZ') > 0, '签名参数缺失：' + res.url);
  assert(res.url.indexOf('timestamp=1700000000') > 0, 'timestamp 缺失');
  assert(res.kind === 'onDemand', 'kind 异常：' + res.kind);
  const delta = res.expiresAt - Math.floor(Date.now() / 1000);
  assert(delta > 0 && delta <= 900, 'expiresAt 应为脚本内 linkTTL(<=900) 秒内，实际差 ' + delta);

  // standard 档位：先免费失败再转付费
  reset({ prefs: { cookie: '1&_token=fixture; domain=.ximalaya.com' }, aesPlain: 'storages/ab/cd/track.m4a' });
  state.responder = (url) => {
    if (url.indexOf(FREE_MARK) >= 0) return FREE_REFUSE;
    if (url.indexOf(PAY_MARK) >= 0) return PAID_OK;
    throw new Error('意外请求：' + url);
  };
  const envStd = resolveAudio({ sourceID: 's', episodeURL: 'xm:998877', trackId: '998877', forDownload: false, quality: 'standard' });
  assert(!envStd.e, 'standard 执行报错：' + envStd.e);
  assert(state.requests.length === 2, 'standard 应先免费后付费共 2 次请求，实际 ' + state.requests.length);
  assert(state.requests[0].indexOf(FREE_MARK) >= 0 && state.requests[1].indexOf(PAY_MARK) >= 0, 'standard 请求顺序异常');
  assert(logHas(/免费接口拒绝/) && logHas(/转付费链路/), '缺少免费拒绝/转付费链路的日志');
  return `high 1 次直达 · standard 先免后付 2 次 · TTL≈${delta}s`;
});

// ---------- 用例 4：付费接口 ret=1001 → not_vip ----------
check('4. 付费接口 ret=1001 → reason=not_vip', () => {
  reset({ prefs: { cookie: '1&_token=fixture' } });
  state.responder = () => JSON.stringify({ ret: 1001, msg: '该专辑需要购买后才能收听' });
  const env = resolveAudio({ episodeURL: 'xm:1', trackId: '1', quality: 'M4A_128' });
  assert(env.e, '应当抛错');
  assert(env.r === 'not_vip', 'reason 应为 not_vip，实际 ' + env.r);
  assert(logHas(/付费接口 ret=1001 需会员/), '缺少「付费接口 ret=1001 需会员」日志');
  return 'reason=' + env.r + ' msg=' + env.e;
});

// ---------- 用例 5：免费命中（standard 档 → 1 次请求拿到直链且不向免费 CDN 透传 Cookie） ----------
check('5. 免费命中：1 次请求拿到直链，不透传 Cookie 且如实标注质量', () => {
  reset({ prefs: { cookie: '1&_token=fixture' } });
  state.responder = (url) => {
    if (url.indexOf(FREE_MARK) >= 0) {
      return freeTrackInfo({ playPathAacv164: '//audio.xmcdn.com/free/track.m4a' });
    }
    throw new Error('意外请求：' + url);
  };
  const env = resolveAudio({ episodeURL: 'xm:5', trackId: '5', quality: 'standard' });
  assert(!env.e, '执行报错：' + env.e);
  const res = JSON.parse(env.v);
  assert(state.requests.length === 1, '免费命中时只应有 1 次请求，实际 ' + state.requests.length);
  assert(res.isPaid === false, 'isPaid 应为 false');
  assert(res.url.indexOf('xmcdn.com/free/track.m4a') > 0, '免费直链异常：' + res.url);
  assert(res.qualityKey === 'playPathAacv164', '命中字段应为 playPathAacv164，实际 ' + res.qualityKey);
  assert(res.quality === 'M4A_64', 'playPathAacv164 应如实标注 M4A_64，实际 ' + res.quality);
  assert(!res.headers || !res.headers.Cookie, 'M-11：免费直链不应携带 Cookie 请求头');
  assert(logHas(/免费接口命中 playPathAacv164（AAC v1 64k）/), '缺少免费命中日志');
  return `1 次请求 · ${res.qualityKey} → quality=${res.quality} · 无 Cookie 透传`;
});

// ---------- 用例 6：免费兜底按档取流（saver/standard/lossless） ----------
check('6. 免费按档取流：saver→低码率、standard→64k、lossless→HQ，quality 如实标注', () => {
  const cases = [
    { q: 'saver', fields: { playUrl32: 'https://audio.xmcdn.com/32.m4a', playPathAacv224: 'https://audio.xmcdn.com/24.m4a', playUrl64: 'https://audio.xmcdn.com/64.m4a' },
      key: 'playUrl32', quality: 'M4A_32', level: '0' },
    { q: 'M4A_24', fields: { playPathAacv224: 'https://audio.xmcdn.com/24.m4a', playUrl64: 'https://audio.xmcdn.com/64.m4a' },
      key: 'playPathAacv224', quality: 'M4A_24', level: '0' },
    { q: 'standard', fields: { playUrl64: 'https://audio.xmcdn.com/64.m4a', playPathAacv164: 'https://audio.xmcdn.com/v1.m4a', playUrl32: 'https://audio.xmcdn.com/32.m4a' },
      key: 'playUrl64', quality: 'M4A_64', level: '0' },
    { q: 'M4A_64', fields: { playPathAacv164: 'https://audio.xmcdn.com/v1.m4a', playPathAacv224: 'https://audio.xmcdn.com/24.m4a' },
      key: 'playPathAacv164', quality: 'M4A_64', level: '0' },
    { q: 'lossless', fields: { playPathHq: 'https://audio.xmcdn.com/hq.m4a', playPathAacv164: 'https://audio.xmcdn.com/v1.m4a' },
      key: 'playPathHq', quality: 'HQ', level: '2' },
    { q: 'FLAC_24', fields: { playPathAacv164: 'https://audio.xmcdn.com/v1.m4a', playUrl64: 'https://audio.xmcdn.com/64.m4a' },
      key: 'playPathAacv164', quality: 'M4A_64', level: '3' }
  ];
  const notes = [];
  for (const c of cases) {
    reset({ prefs: { cookie: '1&_token=fixture' } });
    state.responder = (url) => {
      if (url.indexOf(FREE_MARK) >= 0) return freeTrackInfo(c.fields);
      throw new Error('意外请求：' + url);
    };
    const env = resolveAudio({ episodeURL: 'xm:77', trackId: '77', quality: c.q });
    assert(!env.e, c.q + ' 执行报错：' + env.e);
    const res = JSON.parse(env.v);
    assert(res.isPaid === false, c.q + ' 应命中免费直链');
    assert(res.qualityKey === c.key, c.q + ' 命中字段应为 ' + c.key + '，实际 ' + res.qualityKey);
    assert(res.quality === c.quality, c.q + ' quality 应为 ' + c.quality + '，实际 ' + res.quality);
    assert(res.quality !== 'M4A_128', c.q + ' 不得虚标 M4A_128');
    assert(freeLevels()[0] === c.level, c.q + ' 免费 qualityLevel 应为 ' + c.level + '，实际 ' + freeLevels()[0]);
    notes.push(`${c.q}→${c.key}(${res.quality})/L${c.level}`);
  }
  return notes.join(' · ');
});

// ---------- 用例 7：档位映射（语义档位 + 旧码 + 未识别码） ----------
check('7. 档位 → trackQualityLevel：5 语义档 + 7 旧码 + 未识别码（最接近，并列向上）', () => {
  const cases = [
    ['auto', '1'], ['saver', '0'], ['standard', '0'], ['high', '1'], ['lossless', '2'],
    ['M4A_24', '0'], ['M4A_48', '0'], ['M4A_64', '0'], ['M4A_128', '1'],
    ['FLAC_16', '2'], ['FLAC_24', '3'], ['ATMOS_24', '12'],
    ['m4a_64', '0'],                       // 大小写不敏感
    ['atmos', '12'],                       // 语义档位表里的 atmos（防御性兼容，不写进 qualities 声明）
    ['M4A_96', '1'],                       // 未识别：64/128 并列 → 向上 → 128
    ['M4A_56', '0'],                       // 未识别：48/64 并列 → 向上 → 64（仍 level 0）
    ['M4A_192', '1'],                      // 未识别：超出 128 → 最接近 128
    ['FLAC_20', '2'],                      // 未识别：flac 家族 → FLAC_16
    ['unknown-tier', '1'],                 // 未识别字符串 → high
    ['', '1']                              // 空档位 → auto → high
  ];
  const notes = [];
  for (const [code, expect] of cases) {
    reset({ prefs: { cookie: '1&_token=fixture' }, aesPlain: 'storages/t.m4a' });
    state.responder = (url) => {
      if (url.indexOf(FREE_MARK) >= 0) return FREE_REFUSE;
      if (url.indexOf(PAY_MARK) >= 0) return PAID_OK;
      throw new Error('意外请求：' + url);
    };
    const env = resolveAudio({ episodeURL: 'xm:42', trackId: '42', quality: code });
    assert(!env.e, `档位 ${code || '(空)'} 执行报错：` + env.e);
    assert(payLevels()[0] === expect, `档位 ${code || '(空)'} 应映射 level ${expect}，实际 ${payLevels()[0]}`);
    if (['M4A_96', 'M4A_56', 'M4A_192', 'FLAC_20', 'unknown-tier'].indexOf(code) >= 0) {
      assert(logHas(new RegExp('未识别档位 ' + code.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'))),
        `档位 ${code} 应有「未识别档位」日志`);
    }
    notes.push(`${code || '(空)'}→L${expect}`);
  }
  return notes.join(' ');
});

// ---------- 用例 8：高音质失败逐级回落 ----------
check('8. 逐级回落：ATMOS_24 → FLAC_24 → FLAC_16 → M4A_128', () => {
  reset({ prefs: { cookie: '1&_token=fixture' }, aesPlain: 'storages/fallback.m4a' });
  state.responder = (url) => {
    if (url.indexOf(FREE_MARK) >= 0) return FREE_REFUSE;
    if (url.indexOf(PAY_MARK) >= 0) {
      const m = /trackQualityLevel=(\d+)/.exec(url);
      const level = m ? m[1] : '?';
      if (level === '1') return PAID_OK;
      return JSON.stringify({ ret: 500, msg: '该音质暂不可用' });
    }
    throw new Error('意外请求：' + url);
  };
  const env = resolveAudio({ episodeURL: 'xm:88', trackId: '88', quality: 'ATMOS_24' });
  assert(!env.e, '执行报错：' + env.e);
  const res = JSON.parse(env.v);
  assert(res.isPaid === true, '应回落到付费直链');
  assert(payLevels().join(',') === '12,3,2,1', '回落顺序应为 12,3,2,1，实际 ' + payLevels().join(','));
  assert(logHas(/已回落到 M4A_128/), '缺少回落日志');
  return 'level 请求序列 = ' + payLevels().join(' → ');
});

// ---------- 用例 9：Cookie 判定（匿名 Cookie 不算登录态） ----------
check('9. Cookie 判定：匿名 Cookie 不算登录态 → no_cookie', () => {
  reset({ cookieHeader: 'channel=ios-b1; impl=com.ximalaya.tingLite' }); // 无 1&_token
  state.responder = () => { throw new Error('不应发生任何业务请求'); };
  const env = resolveAudio({ episodeURL: 'xm:6', trackId: '6' });
  assert(env.e, '应当抛错');
  assert(env.r === 'no_cookie', 'reason 应为 no_cookie，实际 ' + env.r);
  const business = state.requests.filter((u) => u.indexOf(FREE_MARK) >= 0 || u.indexOf(PAY_MARK) >= 0);
  assert(business.length === 0, '未取到 Cookie 前不应发起业务请求，实际 ' + business.join(' | '));
  assert(state.requests.filter((u) => u.indexOf('raw.githubusercontent') >= 0).length === 1,
    '应尝试过 1 次远端共享 Cookie 兜底，实际 ' + state.requests.length + ' 次');
  assert(logHas(/远端共享 Cookie 获取失败/), '缺少远端兜底失败日志');
  return 'reason=' + env.r + '（本机匿名 → 远端兜底失败 → 抛错，业务请求 0 次）';
});

// ---------- 用例 10：远端共享 Cookie 兜底 ----------
check('10. 远端共享 Cookie 兜底：本机/pref 都没有时自动取用并缓存 1 小时', () => {
  reset({ aesPlain: 'storages/remote.m4a' });
  state.responder = (url) => {
    if (url.indexOf('raw.githubusercontent') >= 0) return JSON.stringify({ cookie: '1&_token=shared; domain=.ximalaya.com' });
    if (url.indexOf(FREE_MARK) >= 0) return FREE_REFUSE;
    if (url.indexOf(PAY_MARK) >= 0) return PAID_OK;
    throw new Error('意外请求：' + url);
  };
  const env = resolveAudio({ episodeURL: 'xm:8', trackId: '8', quality: 'high' });
  assert(!env.e, '执行报错：' + env.e);
  assert(state.requests[0].indexOf('raw.githubusercontent') >= 0, '第 1 次请求应是远端 Cookie 兜底：' + state.requests[0]);
  const cached = state.cache['remote_cookie.json'];
  assert(cached, '应缓存远端 Cookie');
  const ttl = Date.now() - JSON.parse(cached).t;
  assert(ttl >= 0 && ttl < 3600000, '缓存应带 1 小时内的写入时间戳，实际 ' + ttl + 'ms');
  assert(logHas(/Cookie 来源=remote（远端共享）/), '缺少 Cookie 来源=remote 日志');
  return '已取到并缓存远端 Cookie（' + state.requests.length + ' 次请求）';
});

// ---------- 用例 11：远端 Cookie 缓存命中 ----------
check('11. 远端 Cookie 缓存命中：1 小时内不再访问远端', () => {
  reset({
    cache: { 'remote_cookie.json': JSON.stringify({ cookie: '1&_token=cached; domain=.ximalaya.com', t: Date.now() }) },
    aesPlain: 'storages/cache.m4a'
  });
  state.responder = (url) => {
    if (url.indexOf(FREE_MARK) >= 0) return FREE_REFUSE;
    if (url.indexOf(PAY_MARK) >= 0) return PAID_OK;
    throw new Error('意外请求：' + url);
  };
  const env = resolveAudio({ episodeURL: 'xm:9', trackId: '9', quality: 'high' });
  assert(!env.e, '执行报错：' + env.e);
  assert(state.requests.filter((u) => u.indexOf('raw.githubusercontent') >= 0).length === 0, '不应再访问远端地址');
  assert(logHas(/Cookie 来源=remote（缓存）/), '缺少缓存命中日志');
  return '命中缓存，请求数=' + state.requests.length;
});

// ---------- 用例 12：checkStatus（无样本章节，不探测） ----------
check('12. checkStatus：读用户信息（无样本章节则不探测）', () => {
  reset({ prefs: { sampleTrackId: '' }, cookieHeader: '1&_token=fixture' });
  state.responder = (url) => {
    if (url.indexOf('/revision/main/getCurrentUser') >= 0) {
      return JSON.stringify({ ret: 200, data: { nickname: '测试会员', vipInfo: { expireTime: 1794671999000 } } });
    }
    throw new Error('意外请求：' + url);
  };
  const env = checkStatus();
  assert(!env.e, '执行报错：' + env.e);
  const res = JSON.parse(env.v);
  assert(res.ok === true, 'ok 应为 true，message=' + res.message);
  assert(res.nickname === '测试会员', '昵称不符：' + res.nickname);
  assert(/^(\d{4}-\d{2}-\d{2}|已过期\(\d{4}-\d{2}-\d{2}\))$/.test(res.vipExpireAt), '到期时间格式异常：' + res.vipExpireAt);
  assert(/未配置样本章节/.test(res.message), '应说明未做探测：' + res.message);
  return `${res.nickname} · ${res.vipExpireAt} · ${res.latencyMs}ms`;
});

// ---------- 用例 13：checkStatus 用 lastTrackId 探测成功 ----------
check('13. checkStatus：sampleTrackId 为空 → 用 lastTrackId 做真实解析探测', () => {
  reset({ prefs: { sampleTrackId: '', lastTrackId: '998877' }, cookieHeader: '1&_token=fixture' });
  state.responder = (url) => {
    if (url.indexOf('/revision/main/getCurrentUser') >= 0) {
      return JSON.stringify({ ret: 200, data: { nickname: '测试会员', vipInfo: { expireTime: 1794671999000 } } });
    }
    if (url.indexOf(FREE_MARK) >= 0) return freeTrackInfo({ playPathAacv164: 'https://audio.xmcdn.com/x.m4a' });
    throw new Error('意外请求：' + url);
  };
  const env = checkStatus();
  assert(!env.e, '执行报错：' + env.e);
  const res = JSON.parse(env.v);
  assert(res.ok === true, 'ok 应为 true，message=' + res.message);
  assert(/试解析成功/.test(res.message), '应包含试解析成功：' + res.message);
  assert(/lastTrackId=998877/.test(res.message), '应标注探测来源：' + res.message);
  return res.message;
});

// ---------- 用例 14：checkStatus 探测失败如实报错 ----------
check('14. checkStatus：探测失败如实返回原因（不报 ok=true）', () => {
  reset({ prefs: { sampleTrackId: '555555' }, cookieHeader: '1&_token=fixture' });
  state.responder = (url) => {
    if (url.indexOf('/revision/main/getCurrentUser') >= 0) {
      return JSON.stringify({ ret: 200, data: { nickname: '测试会员', vipInfo: { expireTime: 1794671999000 } } });
    }
    if (url.indexOf(FREE_MARK) >= 0) return FREE_REFUSE;
    if (url.indexOf(PAY_MARK) >= 0) return JSON.stringify({ ret: 500, msg: '服务暂不可用' });
    throw new Error('意外请求：' + url);
  };
  const env = checkStatus();
  assert(!env.e, '执行报错：' + env.e);
  const res = JSON.parse(env.v);
  assert(res.ok === false, 'ok 应为 false，实际 message=' + res.message);
  assert(/探测章节解析失败/.test(res.message), '应说明探测失败：' + res.message);
  assert(/paid_api_failed/.test(res.message), '应带真实原因码：' + res.message);
  assert(res.nickname === '测试会员', '探测失败时仍应回填昵称');
  return res.message;
});

// ---------- 用例 15：成功后记录 lastTrackId + 下载标记 ----------
check('15. 解析成功记录 lastTrackId，下载请求 note=free-download', () => {
  reset({ prefs: { cookie: '1&_token=fixture' } });
  state.responder = (url) => {
    if (url.indexOf(FREE_MARK) >= 0) return freeTrackInfo({ playUrl64: 'https://audio.xmcdn.com/64.m4a' });
    throw new Error('意外请求：' + url);
  };
  const env = resolveAudio({ episodeURL: 'xm:424242', trackId: '424242', forDownload: true, quality: 'standard' });
  assert(!env.e, '执行报错：' + env.e);
  const res = JSON.parse(env.v);
  assert(state.prefs.lastTrackId === '424242', '应记录 lastTrackId=424242，实际 ' + state.prefs.lastTrackId);
  assert(res.note === 'free-download', 'note 应为 free-download，实际 ' + res.note);
  assert(res.downloadUrl === res.url, 'downloadUrl 应与 url 一致');
  return `lastTrackId=${state.prefs.lastTrackId} · note=${res.note}`;
});

// ---------- 用例 16（H-04 / BB-1）：免费试听片段拒绝，不误判成功 ----------
check('16. 试听校验（H-04）：未授权付费试听片段被拒绝并转付费链路', () => {
  reset({ prefs: { cookie: '1&_token=fixture' }, aesPlain: 'storages/full/track.m4a' });
  state.responder = (url) => {
    if (url.indexOf(FREE_MARK) >= 0) {
      return JSON.stringify({
        ret: 0,
        trackInfo: {
          isPaid: true,
          isAuthorized: false,
          duration: 60000,
          sampleDuration: 60000,
          playPathAacv164: 'https://audio.xmcdn.com/trial_64k.m4a'
        }
      });
    }
    if (url.indexOf(PAY_MARK) >= 0) return PAID_OK;
    throw new Error('意外请求：' + url);
  };
  const env = resolveAudio({ episodeURL: 'xm:16', trackId: '16', quality: 'standard' });
  assert(!env.e, '执行报错：' + env.e);
  const res = JSON.parse(env.v);
  assert(res.isPaid === true, '应拒绝试听片段并命中付费直链');
  assert(res.url.indexOf('trial_64k') < 0, '绝不能返回试听片段 URL：' + res.url);
  assert(logHas(/试听片段/), '应记录跳过试听日志');
  return '已拦截 60s 试听片段并转付费链路';
});

// ---------- 用例 17（M-08）：远端共享 Cookie 失效后立即清除缓存 ----------
check('17. 远端 Cookie 失效清缓存（M-08）', () => {
  reset({ cache: { 'remote_cookie.json': JSON.stringify({ cookie: '1&_token=stale_remote', t: Date.now() }) } });
  state.responder = () => JSON.stringify({ ret: 500, msg: 'invalid cookie' });
  const env = resolveAudio({ episodeURL: 'xm:17', trackId: '17', quality: 'standard' });
  assert(env.e && env.r === 'no_cookie', '远端 Cookie 失败应报 no_cookie，实际：' + JSON.stringify(env));
  assert(state.cache['remote_cookie.json'] === '', '远端 Cookie 失效后应立即清空缓存');
  return '已清空失效的 remote_cookie.json';
});

// ---------- 用例 18（M-09）：共享 Cookie 自检不暴露他人昵称 ----------
check('18. 共享 Cookie 自检隐私保护（M-09）：不暴露他人昵称', () => {
  reset({ cache: { 'remote_cookie.json': JSON.stringify({ cookie: '1&_token=remote_ok', t: Date.now() }) } });
  state.responder = (url) => {
    if (url.indexOf('/revision/main/getCurrentUser') >= 0) {
      return JSON.stringify({ ret: 200, data: { nickname: '他人敏感昵称', vipInfo: { expireTime: 1893456000 } } });
    }
    throw new Error('意外请求：' + url);
  };
  const env = checkStatus();
  assert(!env.e, '执行报错：' + env.e);
  const res = JSON.parse(env.v);
  assert(res.nickname === '', '共享 Cookie 自检不应返回他人昵称，实际：' + res.nickname);
  assert(/非本人账号/.test(res.message), '应明确标注非本人账号：' + res.message);
  return 'nickname 已隐藏 · message 标注非本人账号';
});

// ---------- 用例 19（P2-03 / L-07）：ep 参数 URL 编码 ----------
check('19. 付费直链 ep 参数 URL 编码（P2-03）', () => {
  const specialEp = b64encode(rc4Encrypt(utf8Encode('BUY+KEY-SIGN/1-TOK=EN-1700000000')));
  reset({ prefs: { cookie: '1&_token=fixture' }, aesPlain: '/storages/a/b.flac' });
  state.responder = (url) => {
    if (url.indexOf(PAY_MARK) >= 0) {
      return JSON.stringify({
        ret: 0, fileId: 'BASE64CIPHER', ep: specialEp, domain: 'https://audio.xmcdn.com/',
        duration: 180000, highestQualityLevel: 'FLAC_16'
      });
    }
    throw new Error('意外请求：' + url);
  };
  const env = resolveAudio({ episodeURL: 'xm:19', trackId: '19', quality: 'lossless' });
  assert(!env.e, '执行报错：' + env.e);
  const res = JSON.parse(env.v);
  assert(res.url.indexOf('https://audio.xmcdn.com/download/1.0.0/storages/a/b.flac?') === 0, '域名/路径拼接不应出现双斜杠：' + res.url);
  assert(res.url.indexOf('buy_key=BUY%2BKEY') > 0 && res.url.indexOf('sign=SIGN%2F1') > 0 && res.url.indexOf('token=TOK%3DEN') > 0, '特殊字符应做 URL 编码：' + res.url);
  return '特殊字符已编码且无双斜杠';
});

// ---------- 用例 20（P1-09）：prelude_parser.js 拦截非法 targets 类型 ----------
check('20. prelude_parser.js 校验 targets.hosts 非数组直接拒绝（P1-09）', () => {
  const ctx = vm.createContext({ __bridge: { host: () => ({ getSourceId: () => 'bad' }) } });
  vm.runInContext(fs.readFileSync(PRELUDE, 'utf8'), ctx);
  let threw = false;
  try {
    vm.runInContext("registerBuiltinParser({ id: 'bad', name: 'bad', targets: { hosts: 'ximalaya.com' }, resolveAudio: function() {} });", ctx);
  } catch (e) {
    threw = /必须为字符串数组/.test(String(e && e.message));
  }
  assert(threw, 'hosts 传字符串时应抛出类型错误');
  return '已拦截非数组 targets.hosts';
});

// ---------- 输出 ----------
let passed = 0;
for (const r of results) {
  if (r.ok) passed++;
  console.log(`${r.ok ? 'PASS' : 'FAIL'}  ${r.name}${r.detail ? '  → ' + r.detail : ''}`);
}
console.log(`\n结果：${passed}/${results.length} 通过`);
// 只挑「链路可见性」相关的日志去重展示（对应改造项 9）
const interesting = /未识别档位|已回落到|转付费链路|Cookie 来源|免费接口命中|免费接口拒绝|免费直链实际音质|付费接口 ret|远端共享 Cookie 获取失败|记录 lastTrackId|未配置样本章节|自检解析探测失败/;
const seen = [];
for (const l of allLogs) { if (interesting.test(l) && seen.indexOf(l) < 0) seen.push(l); }
console.log(`解析脚本日志抽样（全程去重 ${seen.length} 条，展示 14 条）：`);
seen.slice(0, 14).forEach((l) => console.log('  · ' + l));
process.exit(passed === results.length ? 0 : 1);
