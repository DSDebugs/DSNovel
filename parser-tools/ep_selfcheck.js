'use strict';
/**
 * ep_selfcheck.js
 * ---------------------------------------------------------------------------
 * 净版实现的自检（独立于模糊测试的补充证据）：
 *   1) 用 acorn 以 ecmaVersion:5 解析 ximalaya_ep.js —— 证明没有 ES6+ 语法
 *   2) 把 ximalaya_ep.js 丢进一个"裸" vm context（没有 atob / btoa / TextEncoder /
 *      TextDecoder / module / require / Buffer / process，模拟最小 JSC 宿主），
 *      验证它仍然能独立解密 —— 证明不依赖宿主 API
 *   3) 用 golden 向量（密文来自原始实现的运行结果）同时校验 oracle 与净版
 *   4) 校验密钥还原：deriveKey("MZ4uGVu3dvMOKb1k") === "MZe3GV3txvMOKb1p"
 *
 * 运行：node ep_selfcheck.js
 */
const fs = require('fs');
const vm = require('vm');
const path = require('path');
const { loadOracle, hasOriginalOracle } = require(path.join(__dirname, 'ep_oracle.js'));
const MINE = require(path.join(__dirname, 'ximalaya_ep.js'));

const SRC = fs.readFileSync(path.join(__dirname, 'ximalaya_ep.js'), 'utf8');
let pass = 0, fail = 0;
function check(name, cond, detail) {
  if (cond) { pass++; console.log('  ✅ ' + name + (detail ? '  ' + detail : '')); }
  else { fail++; console.log('  ❌ ' + name + (detail ? '  ' + detail : '')); }
}

console.log('==============================================================');
console.log(' ximalaya_ep.js 自检');
console.log('==============================================================');

/* ---- 1. ES5 语法检查（acorn） ---- */
console.log('[1] ES5 语法检查');
const acornCandidates = [
  process.env.ACORN_PATH || '',
  path.join(__dirname, '..', 'node_modules', 'acorn'),
  'acorn'
].filter(Boolean);
let acorn = null, acornPathUsed = '';
for (const c of acornCandidates) {
  try { acorn = require(c); acornPathUsed = c; break; } catch (e) { /* 继续找 */ }
}
if (acorn) {
  try {
    acorn.parse(SRC, { ecmaVersion: 5, sourceType: 'script' });
    check('acorn ecmaVersion:5 解析通过', true, '(acorn @ ' + acornPathUsed + ')');
  } catch (e) {
    check('acorn ecmaVersion:5 解析通过', false, String(e.message));
  }
} else {
  check('acorn 可用', false, '未找到 acorn，请运行 `npm install --no-save acorn@8.14.0` 或设置 ACORN_PATH 后重试（其余检查继续）');
}
const es6Tokens = [
  [/=>/, '箭头函数'], [/\bconst\b/, 'const'], [/\blet\s/, 'let'], [/`/, '模板字符串'],
  [/\bclass\b/, 'class'], [/\.\.\./, '展开/剩余'], [/\bfor\s*\([^)]*\bof\b/, 'for-of'],
  [/\basync\b/, 'async'], [/\bawait\b/, 'await'], [/\?\./, '可选链'], [/\?\?/, '空值合并']
];
// 注释里出现 `code` / class / ... 之类的词不算语法，扫描前按词法剥掉注释并跳过字符串字面量
function stripJSCommentsPreservingStrings(src) {
  let out = '';
  let i = 0;
  const n = src.length;
  while (i < n) {
    const ch = src[i];
    if (ch === "'" || ch === '"') {
      const quote = ch;
      out += ch;
      i++;
      while (i < n) {
        const c = src[i];
        out += c;
        i++;
        if (c === '\\' && i < n) {
          out += src[i];
          i++;
        } else if (c === quote) {
          break;
        }
      }
    } else if (ch === '/' && i + 1 < n && src[i + 1] === '/') {
      i += 2;
      while (i < n && src[i] !== '\n') i++;
    } else if (ch === '/' && i + 1 < n && src[i + 1] === '*') {
      i += 2;
      while (i + 1 < n && !(src[i] === '*' && src[i + 1] === '/')) {
        if (src[i] === '\n') out += '\n';
        i++;
      }
      i += 2;
    } else {
      out += ch;
      i++;
    }
  }
  return out;
}
const CODE = stripJSCommentsPreservingStrings(SRC);
for (const [re, label] of es6Tokens) check('无「' + label + '」语法', !re.test(CODE));

/* ---- 2. 裸 JSC context 运行 ---- */
console.log('[2] 裸宿主 context（无 atob / TextEncoder / TextDecoder / module）');
const bare = vm.createContext({ console: { log: function () { } } }, { name: 'bare-jsc' });
check('宿主确实没有 atob', vm.runInContext('typeof atob', bare) === 'undefined');
check('宿主确实没有 TextEncoder', vm.runInContext('typeof TextEncoder', bare) === 'undefined');
check('宿主确实没有 TextDecoder', vm.runInContext('typeof TextDecoder', bare) === 'undefined');
check('宿主确实没有 module', vm.runInContext('typeof module', bare) === 'undefined');
check('宿主确实没有 Buffer', vm.runInContext('typeof Buffer', bare) === 'undefined');
let bareOk = true, bareErr = '';
try {
  vm.runInContext(SRC, bare, { filename: 'ximalaya_ep.js' });
  check('在裸宿主中加载成功并挂到 globalThis.XimalayaEp', vm.runInContext('typeof XimalayaEp', bare) === 'object');
} catch (e) {
  bareOk = false; bareErr = String(e.message);
  check('在裸宿主中加载成功', false, bareErr);
}

/* ---- 3. golden 向量（密文由原始实现侧运行产生） ---- */
console.log('[3] golden 向量（原始实现 vs 净版 vs 裸宿主净版）');
const GOLDEN = [
  ['A3neiEHTceJXSZArLco3C3NZtTEa5fLMbl22ug==', 'buy1-sign1-token1-1700000000'],
  ['hIkqUdgZ/DiQnjXrb0XqyKTiAyvDSnEU6sWrbcUx5fxZ', '免费佩戴-中文-音质-等级'],
  ['hbQKX/on/jCykBLKb5F/ld36MQ==', '中文测试-0-🎵']
];
const oracle = hasOriginalOracle({}) ? loadOracle({}) : null;
for (const [ct, want] of GOLDEN) {
  if (oracle) {
    const o = oracle.safeDecrypt(ct);
    check('oracle 解密 ' + JSON.stringify(ct.slice(0, 24) + '…') + ' -> ' + JSON.stringify(want),
      o.ok && o.value === want, o.ok ? '' : 'THROW:' + o.message);
  }
  const m = MINE.epDecrypt(ct);
  check('净版(Node) 解密结果 ' + JSON.stringify(ct.slice(0, 16) + '…'), m === want, JSON.stringify(m));
  if (bareOk) {
    const b = vm.runInContext('XimalayaEp.epDecrypt(' + JSON.stringify(ct) + ')', bare);
    check('净版(裸宿主) 解密结果相同', b === want, JSON.stringify(b));
  }
}
const mP = MINE.epParse(GOLDEN[0][0]);
check('净版 epParse 返回 4 段数组', Array.isArray(mP) && mP.length === 4, JSON.stringify(mP));
if (oracle) {
  const oP = oracle.safeParse(GOLDEN[0][0]);
  const sameArr = oP.ok && Array.isArray(mP) && oP.value.length === mP.length &&
    Array.prototype.every.call(oP.value, function (v, i) { return v === mP[i]; });
  check('epParse 结果一致', sameArr,
    'oracle=' + (oP.ok ? JSON.stringify(Array.prototype.slice.call(oP.value)) : 'THROW:' + oP.message) +
    ' mine=' + JSON.stringify(mP));
}

/* ---- 4. 密钥还原 ---- */
console.log('[4] 密钥还原');
check('deriveKey("MZ4uGVu3dvMOKb1k") === "MZe3GV3txvMOKb1p"',
  MINE.deriveKey(MINE.OBFUSCATED_KEY) === 'MZe3GV3txvMOKb1p',
  JSON.stringify(MINE.deriveKey(MINE.OBFUSCATED_KEY)));
check('替换表长度 = 36 且为 0..35 的置换',
  MINE.SUBST_TABLE.length === 36 &&
  MINE.SUBST_TABLE.slice().sort(function (a, b) { return a - b; }).every(function (v, i) { return v === i; }));
if (oracle) {
  const kc = oracle.lexical('_0x22fc81');
  if (kc.ok) {
    check('净版常量与原始脚本运行时 _0x22fc81 完全一致',
      kc.value.A === MINE.OBFUSCATED_KEY &&
      JSON.stringify(Array.prototype.slice.call(kc.value.g)) === JSON.stringify(MINE.SUBST_TABLE));
  }
}

console.log('==============================================================');
console.log(' 自检结果: ' + pass + ' 通过 / ' + fail + ' 失败');
console.log('==============================================================');
process.exitCode = fail === 0 ? 0 : 1;
