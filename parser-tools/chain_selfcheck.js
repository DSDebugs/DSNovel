#!/usr/bin/env node
/**
 * ximalaya_parser-v1.5.6.js 多候选试听与短路状态机回归自检
 * 覆盖 6 组核心闭环场景：
 *   1. user 返 trial_only → 自动切换 remote 拿到正片，且不碰免费接口，写入 30m 非 VIP 短路记忆
 *   2. 短路记忆生效期内，第二次付费解析直接优先尝试 remote（付费请求数 = 1）
 *   3. 本机单购回退：短路期内 remote 返 no_permission → 自动回退 user 拿到正片并清除短路记忆
 *   4. user + remote 均返 trial_only → 抛出 trial_only，免费接口调用次数 = 0
 *   5. user 返 trial_only + remote 返 no_permission → 抛出 trial_only，免费接口调用次数 = 0
 *   6. S3.3 超清加强 r2 返试听 → 保留 r1 已获取的 level 2 正片，不抛异常
 */
'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const crypto = require('crypto');

const parsersDir = path.join(__dirname, '..', 'App', 'Resources', 'BundledParsers');
const matched = fs.readdirSync(parsersDir).filter(f => /^ximalaya_parser-v.+\.js$/.test(f)).sort();
if (matched.length !== 1) throw new Error('Expected exactly 1 ximalaya_parser-v*.js, found: ' + matched.join(', '));
const parserName = matched[0];
const parserPath = path.join(parsersDir, parserName);
const parserCode = fs.readFileSync(parserPath, 'utf8');

// 复用真实可用 ep 样本（先用脚本自带测试向量或动态生成可解 ep）

function makeValidEp() {
  // 构造一个可被 epParse 解出 4 段的最小合法 ep：用脚本内部同款 RC4 + base64 编码
  const key = 'MZe3GV3txvMOKb1p';
  const plain = '123456-7890-tok-1700000000';
  const s = new Array(256);
  for (let i = 0; i < 256; i++) s[i] = i;
  let j = 0;
  for (let i = 0; i < 256; i++) {
    j = (j + s[i] + key.charCodeAt(i % key.length)) & 255;
    const tmp = s[i]; s[i] = s[j]; s[j] = tmp;
  }
  const out = Buffer.alloc(plain.length);
  let a = 0, b = 0;
  for (let k = 0; k < plain.length; k++) {
    a = (a + 1) & 255;
    b = (b + s[a]) & 255;
    const tmp = s[a]; s[a] = s[b]; s[b] = tmp;
    out[k] = plain.charCodeAt(k) ^ s[(s[a] + s[b]) & 255];
  }
  return out.toString('base64');
}

const VALID_EP = makeValidEp();

function loadParser(mockHost) {
  let registered = null;
  const ctx = vm.createContext({
    console,
    Date,
    Math,
    JSON,
    RegExp,
    Array,
    Object,
    String,
    Number,
    Boolean,
    Error,
    parseInt,
    parseFloat,
    isNaN,
    encodeURIComponent,
    decodeURIComponent,
    registerBuiltinParser: (def) => {
      registered = Object.assign({ host: mockHost }, def);
    }
  });
  vm.runInContext(parserCode, ctx, { filename: parserName });
  if (!registered) throw new Error('registerBuiltinParser 未被调用');
  return registered;
}

function createMockHost(handler) {
  const prefs = {};
  const cache = {};
  const stats = { paidCalls: [], freeCalls: [], profileCalls: [], logs: [] };
  const host = {
    cookies: () => handler.userCookie || '1&_token=USER_NONVIP_TOKEN_001',
    getPref: (k, d) => (k in prefs ? prefs[k] : (d !== undefined ? d : '')),
    setPref: (k, v) => { prefs[k] = v; },
    readCache: (k) => cache[k] || '',
    writeCache: (k, v) => { cache[k] = v; },
    userAgent: () => 'MockUA/1.0',
    md5: (s) => crypto.createHash('md5').update(String(s)).digest('hex'),
    aesEcbDecrypt: () => 'group1/M00/01/02/test-full-track.m4a',
    log: (m) => stats.logs.push(String(m)),
    getJson: (url, opts) => {
      stats.profileCalls.push({ url, cookie: opts && opts.headers && opts.headers.Cookie });
      return { ret: 200, data: { nickname: 'MockUser', isVip: true } };
    },
    getString: (url, opts) => {
      const cookie = (opts && opts.headers && opts.headers.Cookie) || '';
      if (url.includes('xmly_data.json')) {
        return JSON.stringify({ cookie: handler.remoteCookie || '1&_token=REMOTE_VIP_TOKEN_999' });
      }
      if (url.includes('/mobile/track/pay/')) {
        const m = url.match(/trackQualityLevel=(\d+)/);
        const level = m ? parseInt(m[1], 10) : 1;
        const origin = cookie.includes('REMOTE') ? 'remote' : 'user';
        stats.paidCalls.push({ url, level, origin });
        return JSON.stringify(handler.onPaid(origin, level, url));
      }
      if (url.includes('/playpage/')) {
        stats.freeCalls.push({ url });
        return JSON.stringify({ ret: 0, trackInfo: { playUrl64: 'https://audio.xmcdn.com/free.m4a' } });
      }
      throw new Error('Unexpected URL: ' + url);
    }
  };
  return { host, stats, cache, prefs };
}

function fullPaidJson(level, highest) {
  return {
    ret: 0,
    isAuthorized: true,
    sampleDuration: 0,
    sampleLength: 0,
    totalLength: 7465111,
    duration: 560,
    fileId: 'DUMMY_ENC',
    ep: VALID_EP,
    domain: 'https://audio.xmcdn.com',
    downloadQualityLevel: level,
    highestQualityLevel: highest !== undefined ? highest : level,
    title: 'TestChapter'
  };
}

function trialPaidJson() {
  return {
    ret: 0,
    isAuthorized: true,
    sampleDuration: 180,
    sampleLength: 1187511,
    totalLength: 7465111,
    duration: 560,
    fileId: 'DUMMY_ENC',
    ep: VALID_EP,
    domain: 'https://audio.xmcdn.com',
    downloadQualityLevel: 1,
    highestQualityLevel: 2
  };
}

let passed = 0;
let total = 0;
function check(name, fn) {
  total++;
  try {
    fn();
    passed++;
    console.log('  PASS:', name);
  } catch (e) {
    console.error('  FAIL:', name, '->', e && e.message ? e.message : e);
    process.exitCode = 1;
  }
}

function assert(cond, msg) {
  if (!cond) throw new Error(msg || 'assertion failed');
}

console.log('Running ' + parserName + ' state-machine selfcheck...');

// Case 1 & 2 & 3 share a single mock host to verify short-circuit persistence & single-purchase fallback
{
  let mode = 'vip';
  const { host, stats } = createMockHost({
    onPaid: (origin, level) => {
      if (mode === 'vip') {
        return origin === 'user' ? trialPaidJson() : fullPaidJson(level, 2);
      }
      // single_purchase mode: remote has no_permission, user owns it!
      return origin === 'remote' ? { ret: 726, msg: '无权限' } : fullPaidJson(level, 2);
    }
  });
  const parser = loadParser(host);

  check('1. user 返 trial_only → 切 remote 成功，不碰免费接口，写入非 VIP 短路记忆', () => {
    const res = parser.resolveAudio({ trackId: '69328304', quality: 'uhd', bypassCache: true });
    assert(res && res.isPaid === true, '应返回付费正片');
    assert(res.hitCredential && res.hitCredential.origin === 'remote', '命中凭据应为 remote');
    assert(stats.paidCalls.length === 2, '应依次请求 user 与 remote（实际 ' + stats.paidCalls.length + '）');
    assert(stats.paidCalls[0].origin === 'user' && stats.paidCalls[1].origin === 'remote', '顺序应为 user -> remote');
    assert(stats.freeCalls.length === 0, '不应触发免费接口');
  });

  check('2. 30 分钟非 VIP 短路期内，第二章直接优先 remote（单次请求命中）', () => {
    stats.paidCalls.length = 0;
    const res = parser.resolveAudio({ trackId: '69328305', quality: 'uhd', bypassCache: true });
    assert(res && res.hitCredential && res.hitCredential.origin === 'remote', '应直接由 remote 命中');
    assert(stats.paidCalls.length === 1 && stats.paidCalls[0].origin === 'remote', '短路期应只发 1 次 remote 请求');
  });

  check('3. 单购回退：短路期内 remote 无权 → 回退 user 拿到正片并清除短路记忆', () => {
    mode = 'single_purchase';
    stats.paidCalls.length = 0;
    const res = parser.resolveAudio({ trackId: '69328306', quality: 'hd', bypassCache: true });
    assert(res && res.hitCredential && res.hitCredential.origin === 'user', '应回退本机 user 拿到正片');
    assert(stats.paidCalls.length === 2 && stats.paidCalls[0].origin === 'remote' && stats.paidCalls[1].origin === 'user', '顺序应为 remote -> user');
    // 验证短路记忆已被清除：下一章恢复 user 优先
    stats.paidCalls.length = 0;
    const res2 = parser.resolveAudio({ trackId: '69328307', quality: 'hd', bypassCache: true });
    assert(res2 && res2.hitCredential && res2.hitCredential.origin === 'user', '清除短路后应直接 user 优先');
    assert(stats.paidCalls.length === 1 && stats.paidCalls[0].origin === 'user', '应恢复 user 首次命中');
  });
}

// Case 4: both trial_only
check('4. user 与 remote 均返 trial_only → 抛 trial_only 且免费接口调用为 0', () => {
  const { host, stats } = createMockHost({
    onPaid: () => trialPaidJson()
  });
  const parser = loadParser(host);
  let err = null;
  try {
    parser.resolveAudio({ trackId: '70000001', quality: 'hd', bypassCache: true });
  } catch (e) { err = e; }
  assert(err && err.reason === 'trial_only', '应抛出 trial_only，实际: ' + (err && err.reason));
  assert(stats.paidCalls.length === 2, '两候选都应被尝试');
  assert(stats.freeCalls.length === 0, '绝不可落入免费接口兜底');
});

// Case 5: user trial_only + remote no_permission
check('5. user 返 trial_only + remote 返 no_permission → 抛 trial_only 且不碰免费接口', () => {
  const { host, stats } = createMockHost({
    onPaid: (origin) => (origin === 'user' ? trialPaidJson() : { ret: 726, msg: '无权限' })
  });
  const parser = loadParser(host);
  let err = null;
  try {
    parser.resolveAudio({ trackId: '70000002', quality: 'hd', bypassCache: true });
  } catch (e) { err = e; }
  assert(err && err.reason === 'trial_only', '应抛出 trial_only，实际: ' + (err && err.reason));
  assert(stats.freeCalls.length === 0, '绝不可落入免费接口兜底');
});

// Case 6: S3.3 r2 trial_only keeps r1 full track
check('6. S3.3 超清加强 r2 返试听 → 忽略 r2 并保留 r1 已获取的 level 2 正片', () => {
  const { host, stats } = createMockHost({
    onPaid: (_origin, level) => (level >= 3 ? trialPaidJson() : fullPaidJson(2, 3))
  });
  const parser = loadParser(host);
  const res = parser.resolveAudio({ trackId: '70000003', quality: 'uhd', bypassCache: true });
  assert(res && res.isPaid === true && res.actualLevel === 2, '应保留 r1 的 level 2 正片');
  assert(stats.paidCalls.length === 2 && stats.paidCalls[0].level === 2 && stats.paidCalls[1].level === 3, '应触发 level 2 + level 3 探测');
});

console.log(`chain_selfcheck: ${passed}/${total} passed`);
if (passed !== total) process.exit(1);
