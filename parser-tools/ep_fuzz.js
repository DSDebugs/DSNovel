'use strict';
/**
 * ep_fuzz.js
 * ---------------------------------------------------------------------------
 * 模糊测试：拿 ep_oracle.js 里的 **原始实现** 当 oracle，对随机输入逐个比对
 * ximalaya_ep.js 的净版实现，输出「N/M 通过」。
 *
 * 覆盖的输入类别（见 CATEGORIES）：
 *   合法 base64 / URL-safe base64 / 含 - 与 _ 的串 / 空白混入 / 非法字符 /
 *   长度非法（%4==1）/ 只有 padding / 空串 / 超长串（最长 50KB）/ 中文与 emoji 明文 /
 *   4 段期望格式 / 随机 unicode 垃圾 / 纯随机字节 / 非字符串类型。
 *
 * 三个环境分别比对（与原始实现里存在的分支一一对应）：
 *   A. 有 atob + 有 TextEncoder/TextDecoder —— 真实 iOS JSC / Surge 环境（主环境）
 *   B. 无 atob                            —— 原实现走 this._fallbackB64Decode（未定义）→ 必然失败
 *   C. 无 TextDecoder                     —— 原实现降级为逐字节 fromCharCode（latin1）
 *
 * 运行：node ep_fuzz.js [用例数]
 */

const path = require('path');
const { loadOracle } = require(path.join(__dirname, 'ep_oracle.js'));
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
 * 只用来造密文样本，配合 oracle 解密做闭环校验。
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

const KEY = MINE.RC4_KEY;              // 净版还原出来的密钥
const b64 = (buf) => Buffer.from(buf).toString('base64');
const toB64Url = (s) => s.replace(/\+/g, '-').replace(/\//g, '_');

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
function randomPlaintext(len) {
  let s = '';
  for (let i = 0; i < len; i++) s += String.fromCharCode(randInt(0x2E00));   // 含 CJK 区
  return s;
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
const B64_URL_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
const JUNK = '%#@!*(){}[]<>?~^|;&$\'"`,:;= \\.\u0000\u001f\u007f\u00e9\u4e2d\ud83d\ude00';

function generate(count) {
  CATEGORIES.length = 0;

  const plan = [
    // [类别, 数量]
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

  for (const [cat, n] of plan) {
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
          const n = 1 + randInt(40);
          for (let k = 0; k < n; k++) s += chars.charAt(randInt(chars.length));
          const pt = Buffer.from(s, 'utf8');
          input = b64(rc4Encrypt(pt, KEY));
          note = 'cjk len=' + pt.length;
          break;
        }
        case 'D': {
          const pool = ['😀', '🎵', '🔥', '𝕏', '👨‍👩‍👧', '中', 'é', '𐍈'];
          let s = '';
          const n = 1 + randInt(10);
          for (let k = 0; k < n; k++) s += pool[randInt(pool.length)];
          const pt = Buffer.from(s, 'utf8');
          input = b64(rc4Encrypt(pt, KEY));
          note = 'emoji bytes=' + pt.length;
          break;
        }
        case 'E': {
          const seg = () => randomFrom('abcdefghijklmnopqrstuvwxyz0123456789', 1 + randInt(24));
          const nseg = 1 + randInt(6);                       // 故意出现 1~6 段
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
          input = b64(rc4Encrypt(Buffer.alloc(kb).fill(0).map((_, i) => (i * 31 + randInt(256)) & 0xFF), KEY));
          note = 'len=' + input.length + ' (random bytes 密文)';
          break;
        }
        case 'O': {
          let s = '';
          const n = 1 + randInt(30);
          for (let k = 0; k < n; k++) s += String.fromCharCode(randInt(0xFFFF));
          input = s;
          note = 'unicode junk';
          break;
        }
        case 'P': {
          const n = 1 + randInt(60);
          let s = '';
          for (let k = 0; k < n; k++) s += String.fromCharCode(randInt(256));
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
      if (CATEGORIES.length >= count) break;
    }
    if (CATEGORIES.length >= count) break;
  }
  return CATEGORIES.slice(0, count);
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

  console.log('==============================================================');
  console.log(' 喜马拉雅 ep 解密：净版实现 vs 原始混淆实现 模糊等价性比对');
  console.log('==============================================================');

  const t0 = Date.now();
  const oA = loadOracle({ atob: true, textCodec: true });     // 环境 A（主）
  const oB = loadOracle({ atob: false, textCodec: true });    // 环境 B
  const oC = loadOracle({ atob: true, textCodec: false });    // 环境 C

  console.log('[oracle] 原始脚本     :', oA.sourcePath);
  console.log('[oracle] 顶层类       : _0x51df08  静态成员 =', oA.statics.join(', '));
  console.log('[oracle] 方法取值     : decrypt ->', oA.decryptName, '| parse ->', oA.parseName);
  console.log('[oracle] 加载期异常   :', oA.loadError ? String(oA.loadError.message || oA.loadError) : '(无)');
  console.log('[oracle] 桩环境网络调用: $httpClient/$task =', oA.record.http.length, '次（全部被桩拦截，零真实请求）');
  console.log('[净版] 还原出的 RC4 密钥:', JSON.stringify(MINE.RC4_KEY), '(由', JSON.stringify(MINE.OBFUSCATED_KEY), '+ 36 项替换表推出)');

  // 常量核对：直接从原始脚本的运行环境里读 _0x22fc81['A'] / ['g'] 与净版内置常量逐项对齐
  const kc = oA.lexical('_0x22fc81');
  if (kc.ok) {
    const sameKey = kc.value.A === MINE.OBFUSCATED_KEY;
    const sameTbl = JSON.stringify(Array.prototype.slice.call(kc.value.g)) === JSON.stringify(MINE.SUBST_TABLE);
    console.log('[核对] 原始 _0x22fc81.A =', JSON.stringify(kc.value.A), sameKey ? '== 净版 OBFUSCATED_KEY ✅' : '❌');
    console.log('[核对] 原始 _0x22fc81.g 长度 =', kc.value.g.length, sameTbl ? '与净版 SUBST_TABLE 逐项一致 ✅' : '❌ 不一致');
    console.log('[核对] deriveKey(原始密钥串) =', JSON.stringify(MINE.deriveKey(kc.value.A)), '| 净版 RC4_KEY =', JSON.stringify(MINE.RC4_KEY),
      MINE.deriveKey(kc.value.A) === MINE.RC4_KEY ? '✅' : '❌');
  } else {
    console.log('[核对] 无法从 context 读取 _0x22fc81:', kc.message);
  }
  console.log('');

  const cases = generate(want);
  const byCat = {};
  for (const c of cases) byCat[c.cat] = (byCat[c.cat] || 0) + 1;
  console.log('[用例] 生成', cases.length, '条，分布：');
  for (const k of Object.keys(byCat)) console.log('        ', k.padEnd(34), byCat[k]);

  // 闭环自检：随机明文 → RC4(独立实现) + base64 → 原始实现解密
  console.log('');
  console.log('[闭环] 独立 RC4 加密再交给 **原始 oracle** 解密（10 条）：');
  let rtOk = 0;
  for (let i = 0; i < 10; i++) {
    const pt = i % 3 === 0 ? '中文测试-' + i + '-🎵' : 'buy' + i + '-sign' + i + '-tok' + i + '-170000' + i;
    const ct = b64(rc4Encrypt(Buffer.from(pt, 'utf8'), KEY));
    const got = oA.decrypt(ct);
    const got2 = MINE.epDecrypt(ct);
    const ok = got === pt && got2 === pt;
    if (ok) rtOk++;
    console.log('        ', ok ? 'OK  ' : 'FAIL', 'plain=' + JSON.stringify(pt), 'cipher=' + ct.slice(0, 40) + '…', 'oracle=' + JSON.stringify(got));
  }
  console.log('[闭环] 结果:', rtOk + '/10');
  console.log('');

  // 代表性样例（给报告直接引用）：oracle 与净版逐一对照
  console.log('[样例] 代表性输入与两端输出：');
  const samples = [];
  const seg = 'buy1-sign1-token1-1700000000';
  samples.push(['合法完整密文(→4段)', b64(rc4Encrypt(Buffer.from(seg, 'utf8'), KEY))]);
  samples.push(['中文明文密文', b64(rc4Encrypt(Buffer.from('免费佩戴-中文-音质-等级', 'utf8'), KEY))]);
  samples.push(['URL-safe 变体(含 -/_)', (function () {
    let raw = b64(rc4Encrypt(Buffer.from(seg, 'utf8'), KEY)), g = 0;
    while (!/[+/]/.test(raw) && g++ < 50) raw = b64(rc4Encrypt(Buffer.from(randomFrom('abcdefgh', 20) + seg, 'utf8'), KEY));
    return toB64Url(raw);
  }())]);
  samples.push(['无 padding', b64(rc4Encrypt(Buffer.from(seg, 'utf8'), KEY)).replace(/=+$/, '')]);
  samples.push(['混入空白与换行', sprinkleWs(b64(rc4Encrypt(Buffer.from(seg, 'utf8'), KEY)), 3)]);
  samples.push(['非法字符', '%%%%' + b64(rc4Encrypt(Buffer.from(seg, 'utf8'), KEY))]);
  samples.push(['长度 %4==1', 'ABCDE']);
  samples.push(['空串', '']);
  samples.push(['段数=3', b64(rc4Encrypt(Buffer.from('a-b-c', 'utf8'), KEY))]);
  for (const [label, inp] of samples) {
    const oD = oA.safeDecrypt(inp);
    const mD = mySafeDecrypt(inp);
    const oP = oA.safeParse(inp);
    const mP = mySafeParse(inp);
    const ok = (oD.ok === mD.ok && (oD.ok ? oD.value === mD.value : oD.message === mD.message)) &&
      (oP.ok === mP.ok && (oP.ok ? sameValue(oP.value, mP.value) : oP.message === mP.message));
    console.log('   ' + (ok ? 'OK  ' : 'FAIL') + ' ' + label);
    console.log('        input  = ' + desc(inp));
    console.log('        decrypt: oracle=' + (oD.ok ? desc(oD.value) : 'THROW:' + oD.message) +
      '  mine=' + (mD.ok ? desc(mD.value) : 'THROW:' + mD.message));
    console.log('        parse  : oracle=' + (oP.ok ? desc(oP.value) : 'THROW:' + oP.message) +
      '  mine=' + (mP.ok ? desc(mP.value) : 'THROW:' + mP.message));
  }
  console.log('');

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
  console.log('[分类明细 · 环境 A]');
  for (const k of Object.keys(rA.catTotal)) {
    const p = rA.catPass[k] || 0;
    console.log('   ' + String(k).padEnd(34) + p + '/' + rA.catTotal[k] + (p === rA.catTotal[k] ? ' ✅' : ' ❌'));
  }
  console.log('--------------------------------------------------------------');
  const allPass = rA.decryptPass === rA.total && rA.parsePass === rA.total &&
    rB.decryptPass === rB.total && rB.parsePass === rB.total &&
    rC.decryptPass === rC.total && rC.parsePass === rC.total;
  console.log('结论：');
  console.log('  A 环境 epDecrypt ' + rA.decryptPass + '/' + rA.total + '、epParse ' + rA.parsePass + '/' + rA.total);
  console.log('  B 环境 epDecrypt ' + rB.decryptPass + '/' + rB.total + '、epParse ' + rB.parsePass + '/' + rB.total);
  console.log('  C 环境 epDecrypt ' + rC.decryptPass + '/' + rC.total + '、epParse ' + rC.parsePass + '/' + rC.total);
  console.log('  ' + (allPass ? '全部通过：净版实现与原始实现逐条等价。' : '存在不一致，需要继续调试。'));
  console.log('  用例生成 ' + (t1 - t0) + ' ms，比对 ' + (t2 - t1) + ' ms，总计 ' + (Date.now() - t0) + ' ms');
  console.log('==============================================================');
  process.exitCode = allPass ? 0 : 1;
}

main();
