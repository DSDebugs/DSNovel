'use strict';
/**
 * ep_fuzz.js
 * ---------------------------------------------------------------------------
 * 模糊测试：
 *   1) 当环境变量 XM_ORIGINAL 指向原始混淆脚本时：拿 ep_oracle.js 里的原始实现当
 *      oracle，对随机输入逐个比对 ximalaya_ep.js 的净版实现。
 *   2) 当未设置 XM_ORIGINAL 时（仓库独立运行模式）：启用「独立往返 + WHATWG 参考
 *      Oracle」模糊测试模式，使用独立 RC4 实现 + Node 原生 WHATWG atob / Buffer /
 *      TextDecoder 对 1200+ 往返向量与 3400 条 17 类模糊向量进行三环境逐条对拍。
 *
 * 运行：node parser-tools/ep_fuzz.js [用例数]
 */

const path = require('path');
const util = require('util');
const { loadOracle, hasOriginalOracle } = require(path.join(__dirname, 'ep_oracle.js'));
const MINE = require(path.join(__dirname, 'ximalaya_ep.js'));

/* ------------------------------------------------------------------ *
 * 确定性 PRNG（固定种子，保证结果可复现）
 * ------------------------------------------------------------------ */
function mulberry32(seed) {
  let a = seed >>> 0;
  return function () {
    a = (a + 0x6D2B79F5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}
const rnd = mulberry32(0x5EED1234);
const randInt = (n) => Math.floor(rnd() * n);
const pick = (arr) => arr[randInt(arr.length)];

/* ------------------------------------------------------------------ *
 * 独立实现的 RC4（故意不与净版共用代码，避免"自己和自己对"）
 * ------------------------------------------------------------------ */
function rc4Encrypt(bytes, keyStr) {
  const key = [];
  for (let i = 0; i < keyStr.length; i++) key.push(keyStr.charCodeAt(i) & 0xFF);
  const S = [];
  for (let i = 0; i < 256; i++) S[i] = i;
  let j = 0;
  for (let i = 0; i < 256; i++) {
    j = (j + S[i] + key[i % key.length]) & 0xFF;
    const t = S[i]; S[i] = S[j]; S[j] = t;
  }
  const out = Buffer.alloc(bytes.length);
  let i = 0; j = 0;
  for (let n = 0; n < bytes.length; n++) {
    i = (i + 1) & 0xFF;
    j = (j + S[i]) & 0xFF;
    const t = S[i]; S[i] = S[j]; S[j] = t;
    out[n] = bytes[n] ^ S[(S[i] + S[j]) & 0xFF];
  }
  return out;
}

const EXPECTED_KEY = 'MZe3GV3txvMOKb1p';
if (MINE.RC4_KEY !== EXPECTED_KEY) {
  throw new Error('RC4_KEY mismatch: expected ' + JSON.stringify(EXPECTED_KEY) + ', got ' + JSON.stringify(MINE.RC4_KEY));
}
const KEY = EXPECTED_KEY;              // 独立硬编码期望密钥（与净版启动断言一致）
const b64 = (buf) => Buffer.from(buf).toString('base64');
const toB64Url = (s) => s.replace(/\+/g, '-').replace(/\//g, '_');

/* ------------------------------------------------------------------ *
 * 独立参考 Oracle（无 XM_ORIGINAL 时使用：独立 RC4 + WHATWG atob/TextDecoder）
 * ------------------------------------------------------------------ */
function createStandaloneReferenceOracle(options) {
  options = options || {};
  const allowAtob = options.atob !== false;
  const useTextDecoder = options.textCodec !== false;
  const decoder = new util.TextDecoder('utf-8');

  function decrypt(input) {
    try {
      if (typeof input !== 'string') {
        if (Object.prototype.toString.call(input) !== '[object String]') return null;
        input = String(input);
      }
      if (!allowAtob) return null;
      const cleaned = input.replace(/[\r\n\s]/g, '');
      const bin = globalThis.atob(cleaned);
      const cipherBytes = Buffer.alloc(bin.length);
      for (let i = 0; i < bin.length; i++) cipherBytes[i] = bin.charCodeAt(i) & 0xFF;
      const plainBytes = rc4Encrypt(cipherBytes, KEY);
      if (useTextDecoder) {
        return decoder.decode(plainBytes);
      }
      return plainBytes.toString('latin1');
    } catch (e) {
      return null;
    }
  }

  function parse(input) {
    const decrypted = decrypt(input);
    if (!decrypted) throw new Error('EP解密失败');
    const parts = decrypted.split('-');
    if (parts.length !== 4) throw new Error('EP格式无效');
    return parts;
  }

  return {
    sourcePath: '(standalone WHATWG atob + Buffer + TextDecoder + independent RC4)',
    decrypt,
    parse,
    safeDecrypt(input) {
      try { return { ok: true, value: decrypt(input) }; }
      catch (e) { return { ok: false, message: String((e && e.message) || e) }; }
    },
    safeParse(input) {
      try { return { ok: true, value: parse(input) }; }
      catch (e) { return { ok: false, message: String((e && e.message) || e) }; }
    }
  };
}

/* ------------------------------------------------------------------ *
 * 造用例
 * ------------------------------------------------------------------ */
const CATEGORIES = [];
function addCase(cat, input, note) { CATEGORIES.push({ cat, input, note: note || '' }); }

const WS_POOL = [' ', '\t', '\n', '\r', '\f', '\v', '\u00A0', '\u3000', '\u2028', '\uFEFF', '\u2003'];
function sprinkleWs(s, times) {
  let out = s;
  for (let k = 0; k < times; k++) {
    const pos = randInt(out.length + 1);
    out = out.slice(0, pos) + pick(WS_POOL) + out.slice(pos);
  }
  return out;
}
function randomBytes(n) {
  const b = Buffer.alloc(n);
  for (let i = 0; i < n; i++) b[i] = randInt(256);
  return b;
}
function randomFrom(alphabet, len) {
  let s = '';
  for (let i = 0; i < len; i++) s += alphabet.charAt(randInt(alphabet.length));
  return s;
}
const B64_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
const JUNK = '%#@!*(){}[]<>?~^|;&$\'"`,:;= \\.\u0000\u001f\u007f\u00e9\u4e2d\ud83d\ude00';

function generate(count) {
  CATEGORIES.length = 0;

  const plan = [
    ['A_随机字节密文(合法base64)', 460],
    ['B_ASCII明文密文(合法base64)', 280],
    ['C_中文明文密文(合法base64)', 280],
    ['D_emoji/代理对明文密文', 180],
    ['E_四段格式明文密文', 260],
    ['F_合法base64无padding', 180],
    ['G_URL-safe base64(含-_)', 200],
    ['H_混入空白字符', 200],
    ['I_含非法字符', 220],
    ['J_长度%4==1', 180],
    ['K_纯padding/畸形padding', 120],
    ['L_空串/近空串', 60],
    ['M_短随机串', 240],
    ['N_超长串(5KB~50KB)', 60],
    ['O_随机unicode垃圾', 240],
    ['P_纯随机字节当字符串', 200],
    ['Q_非字符串类型', 40]
  ];

  const baseTotal = plan.reduce((s, [, n]) => s + n, 0);
  let activePlan = plan;
  if (count !== baseTotal) {
    const target = Math.max(plan.length, count);
    const items = plan.map(([cat, n]) => {
      const exact = (n * target) / baseTotal;
      const base = Math.max(1, Math.floor(exact));
      return { cat, count: base, frac: exact - base };
    });
    let sum = items.reduce((s, x) => s + x.count, 0);
    while (sum < target) {
      items.sort((a, b) => b.frac - a.frac);
      items[0].count++;
      items[0].frac = -1;
      sum++;
    }
    while (sum > target) {
      const shrinkable = items.filter(x => x.count > 1).sort((a, b) => a.frac - b.frac);
      if (!shrinkable.length) break;
      shrinkable[0].count--;
      shrinkable[0].frac = 2;
      sum--;
    }
    const counts = new Map(items.map(x => [x.cat, x.count]));
    activePlan = plan.map(([cat]) => [cat, counts.get(cat)]);
  }

  const limit = Math.max(activePlan.length, count);
  for (const [cat, n] of activePlan) {
    for (let i = 0; i < n; i++) {
      let input, note = '';
      switch (cat.charAt(0)) {
        case 'A': {
          const len = 1 + randInt(63);
          const pt = randomBytes(len);
          const ct = rc4Encrypt(pt, KEY);
          input = b64(ct);
          note = 'plaintextBytes=' + len;
          break;
        }
        case 'B': {
          const pt = Buffer.from(randomFrom('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_- .,:;', 1 + randInt(120)), 'utf8');
          input = b64(rc4Encrypt(pt, KEY));
          note = 'ascii len=' + pt.length;
          break;
        }
        case 'C': {
          const chars = '喜马拉雅会员解锁调试免费佩戴专辑音频音质等级下载播放器皮肤';
          let s = '';
          const m = 1 + randInt(40);
          for (let k = 0; k < m; k++) s += chars.charAt(randInt(chars.length));
          const pt = Buffer.from(s, 'utf8');
          input = b64(rc4Encrypt(pt, KEY));
          note = 'cjk len=' + pt.length;
          break;
        }
        case 'D': {
          const pool = ['😀', '🎵', '🔥', '𝕏', '👨‍👩‍👧', '中', 'é', '𐍈'];
          let s = '';
          const m = 1 + randInt(10);
          for (let k = 0; k < m; k++) s += pool[randInt(pool.length)];
          const pt = Buffer.from(s, 'utf8');
          input = b64(rc4Encrypt(pt, KEY));
          note = 'emoji bytes=' + pt.length;
          break;
        }
        case 'E': {
          const seg = () => randomFrom('abcdefghijklmnopqrstuvwxyz0123456789', 1 + randInt(24));
          const nseg = 1 + randInt(6);
          let s = [];
          for (let k = 0; k < nseg; k++) s.push(k === 0 ? seg() : (rnd() < 0.15 ? '' : seg()));
          const pt = Buffer.from(s.join('-'), 'utf8');
          input = b64(rc4Encrypt(pt, KEY));
          note = 'segments=' + nseg;
          break;
        }
        case 'F': {
          let s = b64(rc4Encrypt(randomBytes(1 + randInt(40)), KEY)).replace(/=+$/, '');
          input = s;
          note = 'len%4=' + (s.length % 4);
          break;
        }
        case 'G': {
          let raw = b64(rc4Encrypt(randomBytes(1 + randInt(40)), KEY));
          let guard = 0;
          while (!/[+/]/.test(raw) && guard++ < 50) raw = b64(rc4Encrypt(randomBytes(1 + randInt(40)), KEY));
          input = rnd() < 0.5 ? toB64Url(raw) : toB64Url(raw.replace(/=+$/, ''));
          note = 'urlsafe(含 - _ 替换)';
          break;
        }
        case 'H': {
          const raw = b64(rc4Encrypt(randomBytes(1 + randInt(30)), KEY));
          input = sprinkleWs(raw, 1 + randInt(4));
          note = 'ws injected';
          break;
        }
        case 'I': {
          const base = b64(rc4Encrypt(randomBytes(1 + randInt(20)), KEY));
          const pos = randInt(base.length + 1);
          input = base.slice(0, pos) + pick(JUNK.split('')) + base.slice(pos);
          note = 'junk injected';
          break;
        }
        case 'J': {
          let s = randomFrom(B64_ALPHABET, 4 * (1 + randInt(6)) + 1);
          input = s;
          note = 'len=' + s.length + ' (%4=1)';
          break;
        }
        case 'K': {
          input = pick(['=', '==', '===', '====', 'a=', 'ab=', 'abc=', 'a==', 'ab==', 'a===', '====a', 'AB=', 'ABCD==', 'ABCDE=']);
          note = 'padding edge';
          break;
        }
        case 'L': {
          input = pick(['', ' ', '\n', '\u00A0', '\t\u3000', '='.repeat(0)]);
          note = 'empty/blank';
          break;
        }
        case 'M': {
          input = randomFrom(B64_ALPHABET + '+-_=/.', 1 + randInt(8));
          note = 'short';
          break;
        }
        case 'N': {
          const kb = 5 * 1024 + randInt(45 * 1024);
          input = b64(rc4Encrypt(Buffer.alloc(kb).fill(0).map((_, idx) => (idx * 31 + randInt(256)) & 0xFF), KEY));
          note = 'len=' + input.length + ' (random bytes 密文)';
          break;
        }
        case 'O': {
          let s = '';
          const m = 1 + randInt(30);
          for (let k = 0; k < m; k++) s += String.fromCharCode(randInt(0xFFFF));
          input = s;
          note = 'unicode junk';
          break;
        }
        case 'P': {
          const m = 1 + randInt(60);
          let s = '';
          for (let k = 0; k < m; k++) s += String.fromCharCode(randInt(256));
          input = s;
          note = 'random latin1 string';
          break;
        }
        case 'Q': {
          input = pick([null, undefined, 0, 1.5, -3, true, false, {}, [], { a: 1 }, function () { }, Symbol('s'), 123n, new String('QUJD')]);
          note = 'typeof=' + (typeof input) + ' / ' + Object.prototype.toString.call(input);
          break;
        }
      }
      addCase(cat, input, note);
      if (CATEGORIES.length >= limit) break;
    }
    if (CATEGORIES.length >= limit) break;
  }
  return CATEGORIES.slice(0, limit);
}

/* ------------------------------------------------------------------ *
 * 独立往返模糊测试（1200 条随机明文：独立 RC4 + base64 → 净版解密还原）
 * ------------------------------------------------------------------ */
function runStandaloneRoundTrip(count) {
  const cjk = '喜马拉雅有声书免费佩戴专辑音频音质等级下载播放器皮肤测试中文';
  const emojis = ['😀', '🎵', '🔥', '𝕏', '👨‍👩‍👧', 'é', '𐍈'];
  let pass = 0;
  const fails = [];

  for (let i = 0; i < count; i++) {
    let pt = '';
    const mode = i % 5;
    if (mode === 0) {
      pt = randomFrom('abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_ .,:;/', 1 + randInt(120));
    } else if (mode === 1) {
      const m = 1 + randInt(40);
      for (let k = 0; k < m; k++) pt += cjk.charAt(randInt(cjk.length));
    } else if (mode === 2) {
      const m = 1 + randInt(12);
      for (let k = 0; k < m; k++) pt += pick(emojis) + randomFrom('abc123', 1 + randInt(4));
    } else if (mode === 3) {
      const s1 = randomFrom('abcdefghijklmnopqrstuvwxyz0123456789', 2 + randInt(12));
      const s2 = randomFrom('abcdefghijklmnopqrstuvwxyz0123456789', 2 + randInt(12));
      const s3 = randomFrom('abcdefghijklmnopqrstuvwxyz0123456789', 2 + randInt(12));
      const s4 = String(1700000000 + i);
      pt = [s1, s2, s3, s4].join('-');
    } else {
      const m = 1 + randInt(32);
      for (let k = 0; k < m; k++) {
        pt += (k % 2 === 0) ? cjk.charAt(randInt(cjk.length)) : randomFrom('0123456789ABCDEF', 2);
      }
    }

    let cipher = b64(rc4Encrypt(Buffer.from(pt, 'utf8'), KEY));
    if (i % 7 === 0) cipher = cipher.replace(/=+$/, '');
    if (i % 11 === 0) cipher = sprinkleWs(cipher, 1 + randInt(3));

    const got = MINE.epDecrypt(cipher);
    let ok = (got === pt);
    if (ok && mode === 3) {
      const parsed = MINE.epParse(cipher);
      ok = Array.isArray(parsed) && parsed.length === 4 && parsed.join('-') === pt;
    }
    if (ok) {
      pass++;
    } else if (fails.length < 5) {
      fails.push({ index: i, expected: pt, actual: got });
    }
  }
  return { total: count, pass, fails };
}

/* ------------------------------------------------------------------ *
 * 比对
 * ------------------------------------------------------------------ */
function desc(v) {
  if (v === null) return 'null';
  if (v === undefined) return 'undefined';
  if (typeof v === 'string') return JSON.stringify(v.length > 120 ? v.slice(0, 120) + '…' : v);
  if (Array.isArray(v)) return JSON.stringify(v);
  return String(v);
}
function sameValue(a, b) {
  if (Array.isArray(a) || Array.isArray(b)) {
    if (!Array.isArray(a) || !Array.isArray(b) || a.length !== b.length) return false;
    for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
    return true;
  }
  return a === b || (a === null && b === null);
}
function mySafeDecrypt(input, env) {
  try { return { ok: true, value: MINE.epDecrypt(input, env) }; }
  catch (e) { return { ok: false, message: String((e && e.message) || e) }; }
}
function mySafeParse(input, env) {
  try { return { ok: true, value: MINE.epParse(input, env) }; }
  catch (e) { return { ok: false, message: String((e && e.message) || e) }; }
}

function compare(label, oracle, cases, env, envDesc) {
  const res = { label, envDesc, total: cases.length, decryptPass: 0, parsePass: 0, fails: [], catTotal: {}, catPass: {} };
  for (const c of cases) {
    const oD = oracle.safeDecrypt(c.input);
    const mD = mySafeDecrypt(c.input, env);
    let okD;
    if (oD.ok !== mD.ok) okD = false;
    else if (oD.ok) okD = sameValue(oD.value, mD.value);
    else okD = String(oD.message) === String(mD.message);
    if (okD) res.decryptPass++; else if (res.fails.length < 12) {
      res.fails.push({ fn: 'decrypt', cat: c.cat, note: c.note, input: c.input,
        oracle: oD.ok ? desc(oD.value) : 'THROW:' + oD.message,
        mine: mD.ok ? desc(mD.value) : 'THROW:' + mD.message });
    }

    const oP = oracle.safeParse(c.input);
    const mP = mySafeParse(c.input, env);
    let okP;
    if (oP.ok !== mP.ok) okP = false;
    else if (oP.ok) okP = sameValue(oP.value, mP.value);
    else okP = String(oP.message) === String(mP.message);
    if (okP) res.parsePass++; else if (res.fails.length < 12) {
      res.fails.push({ fn: 'parse', cat: c.cat, note: c.note, input: c.input,
        oracle: oP.ok ? desc(oP.value) : 'THROW:' + oP.message,
        mine: mP.ok ? desc(mP.value) : 'THROW:' + mP.message });
    }

    res.catTotal[c.cat] = (res.catTotal[c.cat] || 0) + 1;
    if (okD && okP) res.catPass[c.cat] = (res.catPass[c.cat] || 0) + 1;
  }
  return res;
}

/* ------------------------------------------------------------------ *
 * 主流程
 * ------------------------------------------------------------------ */
function main() {
  const want = parseInt(process.argv[2] || '3400', 10) || 3400;
  const useOriginal = hasOriginalOracle({});

  console.log('==============================================================');
  console.log(useOriginal
    ? ' 喜马拉雅 ep 解密：净版实现 vs 原始混淆实现 模糊等价性比对'
    : ' 喜马拉雅 ep 解密：独立往返 + WHATWG 参考实现 模糊等价性比对');
  console.log('==============================================================');

  const t0 = Date.now();
  const oA = useOriginal ? loadOracle({ atob: true, textCodec: true }) : createStandaloneReferenceOracle({ atob: true, textCodec: true });
  const oB = useOriginal ? loadOracle({ atob: false, textCodec: true }) : createStandaloneReferenceOracle({ atob: false, textCodec: true });
  const oC = useOriginal ? loadOracle({ atob: true, textCodec: false }) : createStandaloneReferenceOracle({ atob: true, textCodec: false });

  console.log('[oracle] 参考源       :', oA.sourcePath);
  if (useOriginal) {
    console.log('[oracle] 顶层类       : _0x51df08  静态成员 =', oA.statics.join(', '));
    console.log('[oracle] 方法取值     : decrypt ->', oA.decryptName, '| parse ->', oA.parseName);
    console.log('[oracle] 加载期异常   :', oA.loadError ? String(oA.loadError.message || oA.loadError) : '(无)');
    console.log('[oracle] 桩环境网络调用: $httpClient/$task =', oA.record.http.length, '次（全部被桩拦截，零真实请求）');
  } else {
    console.log('[mode]   独立模糊模式 : 未设置 XM_ORIGINAL，启用独立 RC4 + WHATWG atob/TextDecoder 闭环对拍');
  }
  console.log('[净版]   还原 RC4 密钥:', JSON.stringify(MINE.RC4_KEY), '(由', JSON.stringify(MINE.OBFUSCATED_KEY), '+ 36 项替换表推出)');

  let rtPassAll = true;
  if (!useOriginal) {
    const rt = runStandaloneRoundTrip(1200);
    rtPassAll = (rt.pass === rt.total);
    console.log('[往返]   独立 RC4 加密 → 净版解密/解析:', rt.pass + '/' + rt.total + (rtPassAll ? '  ✅ 100%' : '  ❌'));
    if (rt.fails.length) {
      for (const f of rt.fails) {
        console.log('         FAIL #' + f.index + ' expected=' + desc(f.expected) + ' actual=' + desc(f.actual));
      }
    }
  }
  console.log('');

  const cases = generate(want);
  const byCat = {};
  for (const c of cases) byCat[c.cat] = (byCat[c.cat] || 0) + 1;
  console.log('[用例] 生成', cases.length, '条，分布：');
  for (const k of Object.keys(byCat)) console.log('        ', k.padEnd(34), byCat[k]);

  const t1 = Date.now();
  const rA = compare('A', oA, cases, undefined, '有 atob + 有 TextEncoder/TextDecoder（真实 iOS/JSC 环境）');
  const rB = compare('B', oB, cases, { atob: false }, '无 atob（原实现走未定义的 _fallbackB64Decode）');
  const rC = compare('C', oC, cases, { textDecoder: false }, '无 TextDecoder（原实现降级 latin1）');
  const t2 = Date.now();

  function report(r) {
    console.log('--------------------------------------------------------------');
    console.log('环境 ' + r.label + '：' + r.envDesc);
    console.log('  epDecrypt 通过: ' + r.decryptPass + '/' + r.total +
      (r.decryptPass === r.total ? '  ✅ 100%' : '  ❌'));
    console.log('  epParse   通过: ' + r.parsePass + '/' + r.total +
      (r.parsePass === r.total ? '  ✅ 100%' : '  ❌'));
    if (r.fails.length) {
      console.log('  前若干条不一致：');
      for (const f of r.fails) {
        console.log('   - [' + f.cat + '] ' + f.note + '  input=' + desc(f.input));
        console.log('       oracle: ' + f.oracle);
        console.log('       mine  : ' + f.mine);
      }
    }
  }
  report(rA);
  report(rB);
  report(rC);

  console.log('--------------------------------------------------------------');
  const allPass = rtPassAll &&
    rA.decryptPass === rA.total && rA.parsePass === rA.total &&
    rB.decryptPass === rB.total && rB.parsePass === rB.total &&
    rC.decryptPass === rC.total && rC.parsePass === rC.total;
  console.log('结论：');
  console.log('  A 环境 epDecrypt ' + rA.decryptPass + '/' + rA.total + '、epParse ' + rA.parsePass + '/' + rA.total);
  console.log('  B 环境 epDecrypt ' + rB.decryptPass + '/' + rB.total + '、epParse ' + rB.parsePass + '/' + rB.total);
  console.log('  C 环境 epDecrypt ' + rC.decryptPass + '/' + rC.total + '、epParse ' + rC.parsePass + '/' + rC.total);
  console.log('  ' + (allPass ? '全部通过：净版实现与参考实现逐条等价。' : '存在不一致，需要继续调试。'));
  console.log('  用例生成 ' + (t1 - t0) + ' ms，比对 ' + (t2 - t1) + ' ms，总计 ' + (Date.now() - t0) + ' ms');
  console.log('==============================================================');
  process.exitCode = allPass ? 0 : 1;
}

main();
