/**
 * ximalaya_ep.js
 * ===========================================================================
 * 喜马拉雅 `ep` 字段解密逻辑的净版实现（行为等价于混淆脚本里 class _0x51df08
 * 的静态方法 decrypt / parse）。
 *
 * 目标环境：iOS JavaScriptCore（Surge / Loon / Scriptable 之类）以及 Node.js。
 * 约束：只用 ES5 语法；不用 CryptoJS、不用 eval、不依赖 atob/TextEncoder/
 *       TextDecoder/TextDecoder 等宿主 API、不用 TypedArray（纯 number 数组）。
 *
 * 算法链路（与原始实现逐步对应）：
 *   1) 去除串内空白（ECMAScript \s 全集）
 *   2) forgiving-base64 解码（= atob 的宽松解码规则）
 *   3) 与固定密钥 "MZe3GV3txvMOKb1p" 做 RC4（KSA + PRGA）
 *      —— 该密钥由固定串 "MZ4uGVu3dvMOKb1k" 经 36 项替换表还原而来
 *   4) 结果字节按 UTF-8 解码成字符串（非法序列 → U+FFFD，与 WHATWG/TextDecoder 一致）
 *   5) 原实现把整条链路包在 try/catch 里：任何一步失败 → 返回 null
 *
 * 注意：替换表只作用在 **RC4 密钥的还原** 上，不参与密文负载（密文只做 base64）。
 * 这一点容易看错，报告的"未能确认/易错点"一节有说明。
 * ===========================================================================
 */

var XimalayaEp = (function () {
  'use strict';

  /* ---------------------------------------------------------------------- *
   * 1. 固定密钥与替换表
   * ---------------------------------------------------------------------- */

  /** 原脚本里 _0x22fc81.A（deob 版 65 行附近）。混淆后的字面量。 */
  var OBFUSCATED_KEY = 'MZ4uGVu3dvMOKb1k';

  /**
   * 原脚本里 _0x22fc81.g —— 36 个整数（任务描述里写"35 个"，实测长度是 36）。
   * 它是 0..35 的一个置换，用来把 OBFUSCATED_KEY 还原成真正的 RC4 密钥。
   */
  var SUBST_TABLE = [
    33, 1, 24, 23, 2, 30, 10, 3, 7, 14,
    15, 28, 32, 16, 5, 31, 13, 9, 22, 0,
    29, 21, 17, 25, 8, 26, 35, 27, 6, 19,
    4, 20, 18, 34, 12, 11
  ];

  /**
   * 还原密钥：原始实现是 _0x93e00d(_0x22fc81.A)，等价于下面这段映射。
   *   对每个字符 c：
   *     v = c.charCodeAt(0) - (('a' <= c <= 'z') ? 97 : 22)   // 小写字母偏移 97，其余偏移 22
   *     if 0 <= v < 36: v = SUBST_TABLE[v]                     // 只在这段区间查表
   *     输出 fromCharCode(v <= 25 ? 97 + v : 22 + v)
   * 结果："MZ4uGVu3dvMOKb1k" -> "MZe3GV3txvMOKb1p"
   */
  function deriveKey(obfuscated) {
    var out = '';
    for (var i = 0; i < obfuscated.length; i++) {
      var c = obfuscated.charAt(i);
      var code = obfuscated.charCodeAt(i);
      var isLower = (c >= 'a' && c <= 'z');
      var v = code - (isLower ? 97 : 22);
      if (v >= 0 && v < SUBST_TABLE.length) {
        v = SUBST_TABLE[v];
      }
      out += String.fromCharCode(v <= 25 ? 97 + v : 22 + v);
    }
    return out;
  }

  /** 真正的 RC4 密钥（ASCII，逐字节 charCode）。 */
  var RC4_KEY = deriveKey(OBFUSCATED_KEY); // === 'MZe3GV3txvMOKb1p'

  /** 密钥字符串 → 字节数组（纯 ASCII，等价于 TextEncoder().encode(key)）。 */
  function utf8EncodeAscii(str) {
    var bytes = [];
    for (var i = 0; i < str.length; i++) {
      var code = str.charCodeAt(i);
      if (code < 0x80) {
        bytes.push(code);
      } else if (code < 0x800) {
        bytes.push(0xC0 | (code >> 6), 0x80 | (code & 0x3F));
      } else {
        bytes.push(0xE0 | (code >> 12), 0x80 | ((code >> 6) & 0x3F), 0x80 | (code & 0x3F));
      }
    }
    return bytes;
  }

  var RC4_KEY_BYTES = utf8EncodeAscii(RC4_KEY);

  /* ---------------------------------------------------------------------- *
   * 2. 空白剔除（对应原实现的 input.replace(/[\r\n\s]/g, '')）
   *    这是 ECMAScript 的 \s 集合，比 WHATWG 的 "ASCII whitespace" 多出
   *    U+00A0 / U+1680 / U+2000-200A / U+2028 / U+2029 / U+202F / U+205F /
   *    U+3000 / U+FEFF 等。必须原样复刻，否则含这些字符的输入会走向不同结果。
   * ---------------------------------------------------------------------- */

  var WHITESPACE_RE = /[\u0009\u000A\u000B\u000C\u000D\u0020\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000\uFEFF]/g;

  function stripWhitespace(str) {
    return str.replace(WHITESPACE_RE, '');
  }

  /* ---------------------------------------------------------------------- *
   * 3. forgiving-base64 解码（原实现在有 atob 的宿主里调用 atob）
   *    规则（WHATWG forgiving-base64 decode）：
   *      a. 去掉所有 ASCII 空白（上一步已经去掉全部 \s，这里再兜一次）
   *      b. 若长度是 4 的倍数，且结尾有 1~2 个 '='，则去掉它们
   *      c. 若长度 % 4 === 1 → 失败（抛错）
   *      d. 出现字母表以外的字符 → 失败（抛错）
   *      e. 每 6 bit 拼一个字节，忽略末尾不足 8 bit 的残位（不校验补零位）
   *    失败在原始实现里表现为抛错，最终被外层 catch 吞掉 → decrypt 返回 null。
   * ---------------------------------------------------------------------- */

  var B64_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  var B64_LOOKUP = (function () {
    var t = {};
    for (var i = 0; i < B64_ALPHABET.length; i++) t[B64_ALPHABET.charAt(i)] = i;
    return t;
  }());

  function invalidCharacterError() {
    var e = new Error('Invalid character');
    e.name = 'InvalidCharacterError';
    return e;
  }

  function base64Decode(input) {
    var data = input.replace(/[\u0009\u000A\u000C\u000D\u0020]/g, '');
    if (data.length === 0) return [];

    if (data.length % 4 === 0) {
      if (data.charAt(data.length - 1) === '=') {
        data = data.substring(0, data.length - 1);
        if (data.charAt(data.length - 1) === '=') {
          data = data.substring(0, data.length - 1);
        }
      }
    }
    if (data.length % 4 === 1) throw invalidCharacterError();

    var out = [];
    var buffer = 0;
    var bits = 0;
    for (var i = 0; i < data.length; i++) {
      var ch = data.charAt(i);
      if (!Object.prototype.hasOwnProperty.call(B64_LOOKUP, ch)) throw invalidCharacterError();
      buffer = (buffer << 6) | B64_LOOKUP[ch];
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        out.push((buffer >> bits) & 0xFF);
      }
    }
    return out;
  }

  /* ---------------------------------------------------------------------- *
   * 4. RC4：KSA + PRGA（原实现 _0x1a98bb 先算 256 字节状态表，_0x2aaccc 再做异或）
   * ---------------------------------------------------------------------- */

  function rc4Ksa(keyBytes) {
    var s = [];
    var i, j, t;
    for (i = 0; i < 256; i++) s[i] = i;
    j = 0;
    for (i = 0; i < 256; i++) {
      j = (j + s[i] + keyBytes[i % keyBytes.length]) & 0xFF;
      t = s[i]; s[i] = s[j]; s[j] = t;
    }
    return s;
  }

  function rc4Crypt(dataBytes, keyBytes) {
    var s = rc4Ksa(keyBytes);
    var out = [];
    var i = 0, j = 0, n, t;
    for (n = 0; n < dataBytes.length; n++) {
      i = (i + 1) & 0xFF;
      j = (j + s[i]) & 0xFF;
      t = s[i]; s[i] = s[j]; s[j] = t;
      out[n] = dataBytes[n] ^ s[(s[i] + s[j]) & 0xFF];
    }
    return out;
  }

  /* ---------------------------------------------------------------------- *
   * 5. UTF-8 解码（原实现 TextDecoder('utf-8').decode(bytes)）
   *    必须复刻 WHATWG UTF-8 解码器的"最大子部分"错误处理：非法/截断序列
   *    各产生一个 U+FFFD，并且不吞掉后面那个可能合法的字节。
   * ---------------------------------------------------------------------- */

  var REPLACEMENT = '\uFFFD';

  function isContinuation(b) {
    return b >= 0x80 && b <= 0xBF;
  }

  function utf8Decode(bytes) {
    var out = '';
    var i = 0;
    var n = bytes.length;
    while (i < n) {
      var b0 = bytes[i];

      if (b0 < 0x80) {                                  // 1 字节
        out += String.fromCharCode(b0);
        i += 1;
        continue;
      }

      if (b0 >= 0xC2 && b0 <= 0xDF) {                    // 2 字节
        if (i + 1 < n && isContinuation(bytes[i + 1])) {
          out += String.fromCharCode(((b0 & 0x1F) << 6) | (bytes[i + 1] & 0x3F));
          i += 2;
        } else {
          out += REPLACEMENT;
          i += 1;
        }
        continue;
      }

      if (b0 >= 0xE0 && b0 <= 0xEF) {                    // 3 字节
        var lo3 = 0x80, hi3 = 0xBF;
        if (b0 === 0xE0) lo3 = 0xA0;                     // 拒绝过长编码
        else if (b0 === 0xED) hi3 = 0x9F;                // 拒绝 UTF-16 代理区
        if (i + 1 < n && bytes[i + 1] >= lo3 && bytes[i + 1] <= hi3) {
          if (i + 2 < n && isContinuation(bytes[i + 2])) {
            out += String.fromCharCode(
              ((b0 & 0x0F) << 12) | ((bytes[i + 1] & 0x3F) << 6) | (bytes[i + 2] & 0x3F)
            );
            i += 3;
          } else {
            out += REPLACEMENT;
            i += 2;
          }
        } else {
          out += REPLACEMENT;
          i += 1;
        }
        continue;
      }

      if (b0 >= 0xF0 && b0 <= 0xF4) {                    // 4 字节
        var lo4 = 0x80, hi4 = 0xBF;
        if (b0 === 0xF0) lo4 = 0x90;
        else if (b0 === 0xF4) hi4 = 0x8F;
        if (i + 1 < n && bytes[i + 1] >= lo4 && bytes[i + 1] <= hi4) {
          if (i + 2 < n && isContinuation(bytes[i + 2])) {
            if (i + 3 < n && isContinuation(bytes[i + 3])) {
              var cp = ((b0 & 0x07) << 18) | ((bytes[i + 1] & 0x3F) << 12) |
                       ((bytes[i + 2] & 0x3F) << 6) | (bytes[i + 3] & 0x3F);
              cp -= 0x10000;
              out += String.fromCharCode(0xD800 + (cp >> 10), 0xDC00 + (cp & 0x3FF));
              i += 4;
            } else {
              out += REPLACEMENT;
              i += 3;
            }
          } else {
            out += REPLACEMENT;
            i += 2;
          }
        } else {
          out += REPLACEMENT;
          i += 1;
        }
        continue;
      }

      out += REPLACEMENT;                                // 0x80-0xC1 / 0xF5-0xFF
      i += 1;
    }
    return out;
  }

  /** 没有 TextDecoder 时原实现的降级分支：逐字节 fromCharCode（latin1）。 */
  function latin1Decode(bytes) {
    var out = '';
    for (var i = 0; i < bytes.length; i++) out += String.fromCharCode(bytes[i]);
    return out;
  }

  /* ---------------------------------------------------------------------- *
   * 6. 对外 API
   * ---------------------------------------------------------------------- */

  /**
   * epDecrypt(input[, env]) —— 等价于原 class _0x51df08.decrypt(input)
   * @param {string} input 接口返回的 ep / fileId 密文（base64）
   * @param {object} [env]  仅用于复刻宿主差异（默认真实宿主能力）：
   *        env.atob === false        → 复刻"宿主没有 atob"的原始分支（该方法缺失，必然失败）→ 返回 null
   *        env.textDecoder === false → 复刻"宿主没有 TextDecoder"的降级分支（latin1 拼接）
   * @returns {string|null} 明文；任何一步失败都返回 null（与原实现一致）
   */
  function epDecrypt(input, env) {
    env = env || {};
    try {
      // 原实现：input.replace(...) —— 非字符串直接抛 TypeError，被 catch 吞掉
      if (typeof input !== 'string') {
        if (Object.prototype.toString.call(input) !== '[object String]') return null;
        input = String(input);
      }

      // 原实现：typeof atob === 'function' ? Uint8Array.from(atob(s), ...) : this._fallbackB64Decode(s)
      // 该脚本从未定义 _fallbackB64Decode，所以缺 atob 的宿主里必然失败 → null
      if (env.atob === false) return null;

      var cleaned = stripWhitespace(input);          // 1) 去空白
      var bytes = base64Decode(cleaned);             // 2) base64 解码
      var plain = rc4Crypt(bytes, RC4_KEY_BYTES);    // 3) RC4
      return env.textDecoder === false               // 4) UTF-8 解码
        ? latin1Decode(plain)
        : utf8Decode(plain);
    } catch (e) {
      // 原实现：catch 里 $.log('【喜马拉雅】EP解密失败:' + e) 然后 return null
      return null;
    }
  }

  /**
   * epParse(input[, env]) —— 等价于原 class _0x51df08.parse(input)
   * 解密后按 '-' 拆成 4 段 [buy_key, sign, token, timestamp]，段数不是 4 就抛错。
   * @returns {string[]} 长度恒为 4 的数组
   * @throws {Error} 'EP解密失败'（解密返回 null 或空串）/ 'EP格式无效'（段数 ≠ 4）
   */
  function epParse(input, env) {
    var decrypted = epDecrypt(input, env);
    if (!decrypted) throw new Error('EP解密失败');
    var parts = decrypted.split('-');
    if (parts.length !== 4) throw new Error('EP格式无效');
    return parts;
  }

  var api = {
    epDecrypt: epDecrypt,
    epParse: epParse,
    // 便于自检/报告引用（不参与解密主链路）
    RC4_KEY: RC4_KEY,
    OBFUSCATED_KEY: OBFUSCATED_KEY,
    SUBST_TABLE: SUBST_TABLE,
    deriveKey: deriveKey
  };

  return api;
}());

/* ---------------------------------------------------------------------- *
 * 双环境导出：Node（module.exports）与 iOS/JSC（全局对象挂载）
 * ---------------------------------------------------------------------- */
if (typeof module !== 'undefined' && module.exports) {
  module.exports = XimalayaEp;
}

(function (root) {
  if (root && typeof root === 'object') root.XimalayaEp = XimalayaEp;
}(
  (typeof globalThis !== 'undefined' && globalThis) ||
  (typeof self !== 'undefined' && self) ||
  (typeof window !== 'undefined' && window) ||
  (typeof global !== 'undefined' && global) ||
  null
));
