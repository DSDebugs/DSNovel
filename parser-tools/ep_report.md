# 喜马拉雅 `ep` 解密逻辑复原报告（净版实现 + 模糊等价性验证）

分析对象：`<local-original-ximalaya.js>`（362,829 字节 / 文本 362,533 字符 / 36 行，
SHA256 `C310FF37E35C739FA7AF3BCC25DC8FCA5A9E6DBC1C3F5951039D1C0D13A57D83`，`node --check` 通过）
参考产物：`ximalaya.deob.js`（字符串已内联的 deob 版）、`_xmly_decode.js`、`_orig_strings.json`、`_resolved_strings.txt`
—— 参考产物只用于**定位**，所有结论都由"原始文件 + vm 桩环境里跑出来的真实实现"复现，
并逐条与手写净版做比对。整个过程中**没有联网**，也没有改动原始参考文件。

---

## 0. 结论速览

| 项 | 结果 |
|---|---|
| 算法链路 | `去空白(\s) → forgiving-base64 → RC4(KSA+PRGA) → UTF-8 解码`，全程 `try/catch`，失败即 `null` |
| RC4 密钥 | **`MZe3GV3txvMOKb1p`**（16 字节 ASCII，字节值 `77,90,101,51,71,86,51,116,120,118,77,79,75,98,49,112`） |
| 密钥来源 | 固定串 `MZ4uGVu3dvMOKb1k` 经 **36 项**替换表 `_0x22fc81['g']` 逐字符还原 |
| 替换表作用范围 | **只作用于密钥**，密文负载不走替换表（这点和任务描述里的"base64 → 替换表 → RC4"不同，见 §2.2、§5） |
| `parse` 规则 | 解密结果按 `-` 拆分；`!解密结果` → 抛 `EP解密失败`；段数 ≠ 4 → 抛 `EP格式无效` |
| 模糊测试 | **3400/3400 通过**（`epDecrypt` 与 `epParse` 各 3400），且三个宿主环境（有/无 `atob`、有/无 `TextDecoder`）全部 100% |
| 补充自检 | **31/31 通过**（挂载 `XM_ORIGINAL` 原始脚本时）；**独立模式 27/27 通过**（仓库 CI/本地未提供 `XM_ORIGINAL` 时自动跳过 4 项 oracle 对比项，执行全部 27 项 ES5/裸宿主/golden 向量/密钥还原校验） |
| 未确认项 | 该算法是否为喜马拉雅官方算法、真实 `ep` 报文样本 —— 未联网，无法确认（§5） |

---

## 1. 交付物与运行环境

| 文件 | 说明 |
|---|---|
| [parser-tools/ximalaya_ep.js](ximalaya_ep.js) | 净版实现（ES5，无 CryptoJS / eval / 宿主依赖），导出 `epDecrypt` / `epParse` |
| [parser-tools/ep_oracle.js](ep_oracle.js) | 桩环境加载器：`vm.createContext` 造 Surge 风格沙箱，整份执行原始脚本，取出顶层 `class _0x51df08` 作 oracle |
| [parser-tools/ep_fuzz.js](ep_fuzz.js) | 3400 条随机输入的逐条比对脚本（自带独立 RC4 造密文、三环境比对、分类统计） |
| [parser-tools/ep_selfcheck.js](ep_selfcheck.js) | 补充自检：ES5 语法（acorn）、裸宿主运行、golden 向量、常量核对 |
| [parser-tools/ep_report.md](ep_report.md) | 本复原报告（内嵌 §4.2 模糊测试与 §4.3 自检完整输出，可直接运行 `node parser-tools/ep_fuzz.js` / `node parser-tools/ep_selfcheck.js` 复现） |

运行环境：Node.js **v24.21.0**，路径 `node`（在仓库根目录直接调用系统 `node`）。

```powershell
node parser-tools/ep_fuzz.js 3400        # 模糊比对（约 165 s，瓶颈在原始实现的单次调用开销 ≈3.5 ms）
node parser-tools/ep_selfcheck.js        # 补充自检
node parser-tools/ep_oracle.js           # oracle 自检（打印静态成员名与一次探针解密）
```

---

## 2. 复原出的算法步骤

### 2.0 总览

原始实现（deob 第 461–479 行，`class _0x51df08` 的 `decrypt`）主链路只有 5 行：

```js
const _0xbbf194 = _0x3e785c(_0x93e00d(_0xbac8e0));      // 密钥串 -> 还原 -> 字节
const _0x191bed = _0x1a98bb(_0xbbf194);                 // RC4 KSA -> 256 字节状态表
const _0x1f04a9 = _0x55fd91(_0x1899a0);                 // 输入 -> 去空白 -> base64 解码
const _0x2b2213 = _0x2aaccc(_0x1f04a9, _0x191bed);      // RC4 PRGA 异或
return _0x44f086(_0x2b2213);                            // UTF-8 解码
```

对应净版：[parser-tools/ximalaya_ep.js](ximalaya_ep.js) 里 `epDecrypt()` 的 6 行主流程（去空白 → base64 → RC4 → UTF-8），
每一步都有中文注释标明"对应原实现的哪个函数"。

链路（密文侧）：**去空白（ECMAScript `\s` 全集）→ forgiving-base64 → RC4 → UTF-8**；
密钥侧：**替换表还原 → UTF-8/ASCII 编码 → RC4 KSA**。
**替换表不参与密文负载**——这是本次复原里最容易踩错的一点。

### 2.1 密钥还原（替换表）

原始线索（deob 第 224、303、307–368 行）：

```js
const _0xbac8e0 = _0x1505f3.A,              // = "MZ4uGVu3dvMOKb1k"
      _0x10ca30 = _0x1505f3.g,              // = 36 项替代表
      _0x3e785c = x => TextEncoder ? new TextEncoder().encode(x)
                                    : Uint8Array.from(x.split("").map(c => c.charCodeAt(0) & 255));
const _0x3cbb0a = c => c.charCodeAt(0) - ((c >= 'a' && c <= 'z') ? 97 : 22);   // 常量经还原：97 / 22
// _0x93e00d(s)：对每个字符
//   v = _0x3cbb0a(c);
//   若 0 <= v < 36 则 v = 表[v];
//   输出 String.fromCharCode(v <= 25 ? 97 + v : 22 + v)            // 常量经还原：97 / 22 / 阈值 25 / 上限 36
```

逐字符 trace（用净版 `deriveKey()` 打印，见 §4.3）：

| 输入字符 | code | v = code-offset | 查表 | 输出 |
|---|---|---|---|---|
| `M` | 77 | 55 | 不查表（v ≥ 36） | `M` |
| `Z` | 90 | 68 | 不查表 | `Z` |
| `4` | 52 | 30 | `g[30]=4` | `e` |
| `u` | 117 | 20 | `g[20]=29` | `3` |
| `G` | 71 | 49 | 不查表 | `G` |
| `V` | 86 | 64 | 不查表 | `V` |
| `u` | 117 | 20 | `g[20]=29` | `3` |
| `3` | 51 | 29 | `g[29]=19` | `t` |
| `d` | 100 | 3 | `g[3]=23` | `x` |
| `v` | 118 | 21 | `g[21]=21` | `v` |
| `M` | 77 | 55 | 不查表 | `M` |
| `O` | 79 | 57 | 不查表 | `O` |
| `K` | 75 | 53 | 不查表 | `K` |
| `b` | 98 | 1 | `g[1]=1` | `b` |
| `1` | 49 | 27 | `g[27]=27` | `1` |
| `k` | 107 | 10 | `g[10]=15` | `p` |

**`MZ4uGVu3dvMOKb1k` → `MZe3GV3txvMOKb1p`**。

替代表（原文 `_0x22fc81['g']`，**36 项**，十六进制和式写法，已验证是 `0..35` 的一个置换）：

```js
var SUBST_TABLE = [
  33, 1, 24, 23,  2, 30, 10,  3,  7, 14,
  15,28, 32, 16,  5, 31, 13,  9, 22,  0,
  29,21, 17, 25,  8, 26, 35, 27,  6, 19,
   4,20, 18, 34, 12, 11
];
```

> 注意：任务背景里写"35 个整数组成的替换表"，实测长度是 **36**（`0x22fc81.g.length === 36`，运行时从原始脚本读出来的，
> 见 §4.2 的 `[核对] 原始 _0x22fc81.g 长度 = 36`）。索引区间条件也正是 `0 <= v < 36`。

### 2.2 密钥编码

`_0x3e785c` 在 `TextEncoder` 可用时 = `TextEncoder().encode(key)`，否则 `charCodeAt & 255` 兜底。
密钥 `MZe3GV3txvMOKb1p` 全为 ASCII，两条分支结果一致，因此净版直接用 `charCode` 取字节（不依赖 `TextEncoder`）。

### 2.3 去空白

```js
input.replace(/[\r\n\s]/g, '')      // ECMAScript \s 全集，比 WHATWG 的 ASCII whitespace 更宽
```

ECMAScript `\s` = `\t \n \v \f \r 空格 U+00A0 U+1680 U+2000–200A U+2028 U+2029 U+202F U+205F U+3000 U+FEFF`。
净版用等价的显式字符类 `WHITESPACE_RE`。**这一步必须在 base64 之前**，否则 `atob` 会因空白直接报错
——实测 H 类用例（把 `\u3000`/`\u000b`/`\u00A0` 插进密文中）两端都能正常解出明文（见 §4.2 样例 5）。

### 2.4 base64 变体处理

原始实现（deob 231–252 行）：

```js
s = s.replace(/[\r\n\s]/g, '');
typeof atob === 'function'
  ? Uint8Array.from(atob(s), c => c.charCodeAt(0) & 255)   // & 常量还原为 255
  : this._fallbackB64Decode(s);                             // ← 该静态方法在本脚本里根本不存在
```

结论与净版的对应处理：

| 输入形态 | 原始行为 | 净版行为 |
|---|---|---|
| 标准 base64，带 `=`/`==` 填充 | 正常解出 | 一致 |
| 标准 base64，**无填充** | 正常解出（长度 %4 ∈ {2,3} 合法） | 一致 |
| 填充夹在中间或只写填充（`AB=`、`a===`、`====` 等） | **失败**（字母表校验不过 / 长度 %4 == 1） | 一致（抛 `InvalidCharacterError` 语义，外层吞掉返 `null`） |
| **URL-safe**（含 `-` 或 `_`） | **失败** → `epDecrypt` 返回 `null`，`epParse` 抛 `EP解密失败` | 一致 |
| 混入 `\s` 全集任意空白 | 先被剥掉，正常解出 | 一致 |
| 混入其它非法字符（`%`、`#`、`@`…） | 失败 | 一致 |
| 长度 %4 == 1 | 失败 | 一致 |
| 空串 / 纯空白 | 去空白后 → 空字节数组 → RC4 空输入 → `''` | 一致（**`epDecrypt('') === ''`，不是 `null`**；`epParse('')` 因 `!''` 为真抛 `EP解密失败`） |
| 非字符串（`null`/数字/对象/`Symbol`/`BigInt`） | `.replace` 抛 TypeError → 被吞 → `null` | 一致（`epDecrypt` 直接返回 `null`） |

填充/字母表规则按 WHATWG *forgiving-base64 decode* 实现：先去 ASCII 空白 → 长度为 4 的倍数时才允许去掉末尾 1~2 个 `=` →
长度 %4 == 1 失败 → 非字母表字符失败 → 每 6 bit 拼字节、丢弃末尾不足 8 bit 的残位。

> 关于 `atob`：宿主缺 `atob` 时原实现会走 `this._fallbackB64Decode(...)`，而该方法在整份脚本里**从未定义**
> （全文件只有 deob 251 / 1054 两处引用，没有定义），所以那个分支必然抛错 → `decrypt` 恒返回 `null`。
> 这是原脚本自身的一个坑：**这份脚本只有在提供 `atob` 的宿主（Surge/Loon/JSC 网页环境）里才能解密**。
> 净版用 `env.atob === false` 显式复刻了这个行为（见 §4 环境 B）。

### 2.5 RC4

```js
// KSA（原实现 _0x1a98bb，deob 369–424 行）
S = [0..255]; j = 0;
for (i = 0; i < 256; i++) { j = (j + S[i] + key[i % key.length]) & 255; swap(S[i], S[j]); }

// PRGA + 异或（原实现 _0x2aaccc，deob 425–456 行）
i = j = 0;
for (n = 0; n < data.length; n++) {
  i = (i + 1) & 255;
  j = (j + S[i]) & 255;
  swap(S[i], S[j]);
  out[n] = data[n] ^ S[(S[i] + S[j]) & 255];
}
```

所有掩码/MOD 常量经还原均为 `255`、`256`，即标准 RC4（无 drop、无变体）。密钥即 §2.1 的 16 字节。
每次调用都重新做一遍 KSA（原实现把 KSA 放在 `decrypt` 内部，不复用状态）。

### 2.6 UTF-8 解码

原实现 `_0x44f086`：`typeof TextDecoder !== 'undefined' ? new TextDecoder('utf-8').decode(bytes)
: Array.from(bytes).map(b => String.fromCharCode(b)).join('')`。

- 有 `TextDecoder` 时：非 fatal 模式，非法/截断序列输出 **U+FFFD**，并按 WHATWG 的"最大子部分"规则只吞掉真正非法的字节。
  净版 `utf8Decode()` 手写了这套规则（1/2/3/4 字节分支，`0xE0` 下界 `0xA0`、`0xED` 上界 `0x9F`、`0xF0` 下界 `0x90`、`0xF4` 上界 `0x8F`，
  4 字节码点拆成 UTF-16 代理对），**不依赖任何宿主 API**。
- 没有 `TextDecoder` 时：降级为逐字节 `fromCharCode`（latin1）。净版用 `env.textDecoder === false` 复刻。

RC4 输出是准随机字节流，所以"随机字节密文"这一类用例实际上把 UTF-8 解码器的边界（截断、代理区、过长编码、`0xC0/0xC1`、`0xF5~0xFF`）
全都压了一遍——这正是 F/A/N 三类用例的作用。

### 2.7 错误处理与 parse

```js
// decrypt 末尾（deob 461–479）
try { ...主链路... } catch (e) { return $.log('【喜马拉雅】EP解密失败:' + e), null; }

// parse（deob 481–510）
const dec = this.decrypt(input);
if (!dec) throw new Error('EP解密失败');
const parts = dec.split('-');
if (parts.length !== 4) throw new Error('EP格式无效');   // 常量还原为 4
return parts;
```

所以：`epDecrypt` 永远不抛错，失败一律 `null`（空串是例外：返回 `''`）；`epParse` 只抛上面两种消息，净版逐字沿用同样文案。

### 2.8 调用方语义（4 段顺序）

唯一调用点（deob 2316 行，付费直链拼装）：

```js
const [buy_key, sign, token, timestamp] = _0x51df08.decrypt?(...)(track.ep);
url = domain + "download/1.0.0/" + id + "?buy_key=" + buy_key + "&sign=" + sign
            + "&timestamp=" + timestamp + "&token=" + token + "&duration=" + track.duration;
```

即明文格式为 `buy_key-sign-token-timestamp`，与任务描述一致。

---

## 3. 原文对应位置与线索

原文件是"一个巨型单行 + 少量换行"的混淆体（36 行、362,533 字符），因此用**字符偏移**定位：

| 原文偏移 | 内容 | 对应 deob 行 |
|---|---|---|
| 4,687 | `const _0x4e05=[` 2224 条字符串数组 | 39 起 |
| 106,193 | 数组轮转自校验 `(_0x4e05,-0x3b*-0x36a7+…)` | 40–61 |
| 106,240 | `const _0x22fc81={}`；紧接 `_0x22fc81['\x41'] = 3 次解码调用 + 'k'`（拼出 `MZ4uGVu3dvMOKb1k`） | 62–65 |
| 106,448 | `_0x22fc81['\x67']=[36 个整数]`（十六进制和式） | 65 |
| **111,298** | **`class _0x51df08{`**，紧随 `static[…]`（成员名也是解码出来的 `decrypt` / `parse`） | **84–511** |
| 111,298+ | `decrypt`（含密钥/表绑定、base64、替代表、KSA、PRGA） | 85–480 |
| — | `parse` | 481–510 |
| 327,993 | `function _0x2f4b`（字符串数组解码器 base64+RC4，**位于类之后**，靠函数声明提升可用） | 2653–2736 |

类内关键片段（deob 行号）：

- 224：`_0xbac8e0 = _0x22fc81.A`、`_0x10ca30 = _0x22fc81.g`、`_0x3e785c`（TextEncoder）
- 231：`_0x44f086`（TextDecoder）、`_0x55fd91`（去空白 + base64）
- 251：`atob` 分支与不存在的 `this._fallbackB64Decode`
- 303：`_0x3cbb0a`（字符 → 索引，偏移 97 / 22）
- 307：`_0x1a5e59`（输出字符，阈值 25，加 97 / 22）
- 346–366：`_0x93e00d` 的替代表循环
- 369–424：`_0x1a98bb`（RC4 KSA）
- 425–456：`_0x2aaccc`（RC4 PRGA + 异或）
- 461–479：主链路 `try/catch`
- 481–510：`parse`

方法论提示：deob 里大量常量是 `0x…+0x…*0x…` 形式的和式（反混淆器没有折叠），
必须逐条求值才能读出真实语义（例如 `-0x26c7+-0xa07+0x312f` 其实是 `97`，不是看上去的 `161`）。
这些常量在净版里都已折叠并加了注释。

---

## 4. 等价性验证

### 4.1 方法：桩环境 + oracle

[parser-tools/ep_oracle.js](ep_oracle.js) 用 `vm.createContext` 造了 Surge 风格沙箱：
`$request`/`$response`/`$done`/`$persistentStore`/`$prefs`/`$httpClient`/`$task`/`$notify`/`$notification`/`$environment`/`$argument`/`$`/`console`/`setTimeout`/`setInterval`/`window`，
并按需要注入 `atob`/`btoa`（宿主 Node 的规范实现，与 WHATWG 一致）与 `TextEncoder`/`TextDecoder`。
`runInContext(整份源码)` 用 try/catch 包住（顶层主流程在桩里中断属预期），
之后 `runInContext('_0x51df08')` 即可取到那个 **顶层 `class` 声明**——它落在该 context 的 global lexical environment 里，
不是 `globalThis` 的属性，所以只能从同一个 context 的后续脚本按名字访问（这正是任务里提到的取用方式；实测 `typeof _0x51df08 === 'function'`）。
成员名不靠猜测：`Object.getOwnPropertyNames(_0x51df08).filter(函数)` 实测得到 `['decrypt','parse']`，
并且成员名本身就是解码器算出来的，用运行时枚举最稳。

- 桩环境里 `$httpClient`/`$task` 只记录不回调 → **零真实网络请求**（实测 1 次调用、0 次出网）。
- 每次调用完用 `oracle.drainLogs()` 还能看到原始实现自己的日志（例如非法 base64 时 `【喜马拉雅】EP解密失败:InvalidCharacterError: Invalid character`）。

三个环境分别比对，与原始实现里存在的三条分支一一对应：

| 环境 | 桩配置 | 意义 |
|---|---|---|
| A | `atob` + `TextEncoder/TextDecoder` | 真实 iOS/JSC / Surge 环境（主环境） |
| B | 无 `atob` | 复刻 `this._fallbackB64Decode` 未定义 → 恒 `null` |
| C | 无 `TextDecoder` | 复刻 latin1 降级分支 |

判等规则：都成功时**字符串逐字符相等**（`epParse` 逐元素相等）；都抛错时**错误消息相同**（净版刻意沿用原文案）；
一边成功一边抛错、或值不同 → 记为不一致。

### 4.2 模糊测试实际输出（`node ep_fuzz.js 3400`，原样粘贴）

```
==============================================================
 喜马拉雅 ep 解密：净版实现 vs 原始混淆实现 模糊等价性比对
==============================================================
[oracle] 原始脚本     : <local-original-ximalaya.js>
[oracle] 顶层类       : _0x51df08  静态成员 = decrypt, parse
[oracle] 方法取值     : decrypt -> decrypt | parse -> parse
[oracle] 加载期异常   : (无)
[oracle] 桩环境网络调用: $httpClient/$task = 1 次（全部被桩拦截，零真实请求）
[净版] 还原出的 RC4 密钥: "MZe3GV3txvMOKb1p" (由 "MZ4uGVu3dvMOKb1k" + 36 项替换表推出)
[核对] 原始 _0x22fc81.A = "MZ4uGVu3dvMOKb1k" == 净版 OBFUSCATED_KEY ✅
[核对] 原始 _0x22fc81.g 长度 = 36 与净版 SUBST_TABLE 逐项一致 ✅
[核对] deriveKey(原始密钥串) = "MZe3GV3txvMOKb1p" | 净版 RC4_KEY = "MZe3GV3txvMOKb1p" ✅

[用例] 生成 3400 条，分布：
         A_随机字节密文(合法base64)                 460
         B_ASCII明文密文(合法base64)              280
         C_中文明文密文(合法base64)                 280
         D_emoji/代理对明文密文                    180
         E_四段格式明文密文                         260
         F_合法base64无padding                 180
         G_URL-safe base64(含-_)             200
         H_混入空白字符                           200
         I_含非法字符                            220
         J_长度%4==1                          180
         K_纯padding/畸形padding               120
         L_空串/近空串                           60
         M_短随机串                             240
         N_超长串(5KB~50KB)                    60
         O_随机unicode垃圾                      240
         P_纯随机字节当字符串                        200
         Q_非字符串类型                           40

[闭环] 独立 RC4 加密再交给 **原始 oracle** 解密（10 条）：
         OK   plain="中文测试-0-🎵" cipher=hbQKX/on/jCykBLKb5F/ld36MQ==… oracle="中文测试-0-🎵"
         OK   plain="buy1-sign1-tok1-1700001" cipher=A3neiEHTceJXSZArLcpjSHNDtDYa5fM=… oracle="buy1-sign1-tok1-1700001"
         OK   plain="buy2-sign2-tok2-1700002" cipher=A3nei0HTceJXSpArLcpgSHNDtDYa5fA=… oracle="buy2-sign2-tok2-1700002"
         OK   plain="中文测试-3-🎵" cipher=hbQKX/on/jCykBLKb5J/ld36MQ==… oracle="中文测试-3-🎵"
         OK   plain="buy4-sign4-tok4-1700004" cipher=A3nejUHTceJXTJArLcpmSHNDtDYa5fY=… oracle="buy4-sign4-tok4-1700004"
         OK   plain="buy5-sign5-tok5-1700005" cipher=A3nejEHTceJXTZArLcpnSHNDtDYa5fc=… oracle="buy5-sign5-tok5-1700005"
         OK   plain="中文测试-6-🎵" cipher=hbQKX/on/jCykBLKb5d/ld36MQ==… oracle="中文测试-6-🎵"
         OK   plain="buy7-sign7-tok7-1700007" cipher=A3nejkHTceJXT5ArLcplSHNDtDYa5fU=… oracle="buy7-sign7-tok7-1700007"
         OK   plain="buy8-sign8-tok8-1700008" cipher=A3negUHTceJXQJArLcpqSHNDtDYa5fo=… oracle="buy8-sign8-tok8-1700008"
         OK   plain="中文测试-9-🎵" cipher=hbQKX/on/jCykBLKb5h/ld36MQ==… oracle="中文测试-9-🎵"
[闭环] 结果: 10/10

[样例] 代表性输入与两端输出：
   OK   合法完整密文(→4段)
        input  = "A3neiEHTceJXSZArLco3C3NZtTEa5fLMbl22ug=="
        decrypt: oracle="buy1-sign1-token1-1700000000"  mine="buy1-sign1-token1-1700000000"
        parse  : oracle=["buy1","sign1","token1","1700000000"]  mine=["buy1","sign1","token1","1700000000"]
   OK   中文明文密文
        input  = "hIkqUdgZ/DiQnjXrb0XqyKTiAyvDSnEU6sWrbcUx5fxZ"
        decrypt: oracle="免费佩戴-中文-音质-等级"  mine="免费佩戴-中文-音质-等级"
        parse  : oracle=["免费佩戴","中文","音质","等级"]  mine=["免费佩戴","中文","音质","等级"]
   OK   URL-safe 变体(含 -/_)
        input  = "BGTA3gnHf-1RG9s3JsU6AiYV7GdIoLvNcx7v7QaJLzKRXWySvvM2UquLbsIHCyLO"
        decrypt: oracle=null  mine=null
        parse  : oracle=THROW:EP解密失败  mine=THROW:EP解密失败
   OK   无 padding
        input  = "A3neiEHTceJXSZArLco3C3NZtTEa5fLMbl22ug"
        decrypt: oracle="buy1-sign1-token1-1700000000"  mine="buy1-sign1-token1-1700000000"
        parse  : oracle=["buy1","sign1","token1","1700000000"]  mine=["buy1","sign1","token1","1700000000"]
   OK   混入空白与换行
        input  = "A3neiEHTc　eJXSZArLco　3C3NZtTEa5fL\u000bMbl22ug=="
        decrypt: oracle="buy1-sign1-token1-1700000000"  mine="buy1-sign1-token1-1700000000"
        parse  : oracle=["buy1","sign1","token1","1700000000"]  mine=["buy1","sign1","token1","1700000000"]
   OK   非法字符
        input  = "%%%%A3neiEHTceJXSZArLco3C3NZtTEa5fLMbl22ug=="
        decrypt: oracle=null  mine=null
        parse  : oracle=THROW:EP解密失败  mine=THROW:EP解密失败
   OK   长度 %4==1
        input  = "ABCDE"
        decrypt: oracle=null  mine=null
        parse  : oracle=THROW:EP解密失败  mine=THROW:EP解密失败
   OK   空串
        input  = ""
        decrypt: oracle=""  mine=""
        parse  : oracle=THROW:EP解密失败  mine=THROW:EP解密失败
   OK   段数=3
        input  = "ACHFlA8="
        decrypt: oracle="a-b-c"  mine="a-b-c"
        parse  : oracle=THROW:EP格式无效  mine=THROW:EP格式无效

--------------------------------------------------------------
环境 A：有 atob + 有 TextEncoder/TextDecoder（真实 iOS/JSC 环境）
  epDecrypt 通过: 3400/3400  ✅ 100%
  epParse   通过: 3400/3400  ✅ 100%
--------------------------------------------------------------
环境 B：无 atob（原实现走未定义的 _fallbackB64Decode）
  epDecrypt 通过: 3400/3400  ✅ 100%
  epParse   通过: 3400/3400  ✅ 100%
--------------------------------------------------------------
环境 C：无 TextDecoder（原实现降级 latin1）
  epDecrypt 通过: 3400/3400  ✅ 100%
  epParse   通过: 3400/3400  ✅ 100%
--------------------------------------------------------------
[分类明细 · 环境 A]
   A_随机字节密文(合法base64)                460/460 ✅
   B_ASCII明文密文(合法base64)             280/280 ✅
   C_中文明文密文(合法base64)                280/280 ✅
   D_emoji/代理对明文密文                   180/180 ✅
   E_四段格式明文密文                        260/260 ✅
   F_合法base64无padding                180/180 ✅
   G_URL-safe base64(含-_)            200/200 ✅
   H_混入空白字符                          200/200 ✅
   I_含非法字符                           220/220 ✅
   J_长度%4==1                         180/180 ✅
   K_纯padding/畸形padding              120/120 ✅
   L_空串/近空串                          60/60 ✅
   M_短随机串                            240/240 ✅
   N_超长串(5KB~50KB)                   60/60 ✅
   O_随机unicode垃圾                     240/240 ✅
   P_纯随机字节当字符串                       200/200 ✅
   Q_非字符串类型                          40/40 ✅
--------------------------------------------------------------
结论：
  A 环境 epDecrypt 3400/3400、epParse 3400/3400
  B 环境 epDecrypt 3400/3400、epParse 3400/3400
  C 环境 epDecrypt 3400/3400、epParse 3400/3400
  全部通过：净版实现与原始实现逐条等价。
  用例生成 589 ms，比对 163635 ms，总计 164225 ms
==============================================================
```

（由 `node parser-tools/ep_fuzz.js 3400` 实时复现。比对耗时 164 s 几乎全是**原始实现自身**的开销：
每次调用都要新建那个含约 60 个属性的字典对象；实测 `oracle safeDecrypt x300 = 1071 ms`，
而净版 `epDecrypt x300 = 12 ms`，即单次调用相差约 90 倍。）

### 4.3 补充自检实际输出（`node ep_selfcheck.js`）

```
==============================================================
 ximalaya_ep.js 自检
==============================================================
[1] ES5 语法检查
  ✅ acorn ecmaVersion:5 解析通过  (acorn @ node_modules/acorn)
  ✅ 无「箭头函数」语法
  ✅ 无「const」语法
  ✅ 无「let」语法
  ✅ 无「模板字符串」语法
  ✅ 无「class」语法
  ✅ 无「展开/剩余」语法
  ✅ 无「for-of」语法
  ✅ 无「async」语法
  ✅ 无「await」语法
  ✅ 无「可选链」语法
  ✅ 无「空值合并」语法
[2] 裸宿主 context（无 atob / TextEncoder / TextDecoder / module）
  ✅ 宿主确实没有 atob
  ✅ 宿主确实没有 TextEncoder
  ✅ 宿主确实没有 TextDecoder
  ✅ 宿主确实没有 module
  ✅ 宿主确实没有 Buffer
  ✅ 在裸宿主中加载成功并挂到 globalThis.XimalayaEp
[3] golden 向量（原始实现 vs 净版 vs 裸宿主净版）
  ✅ oracle 解密 "A3neiEHTceJXSZArLco3C3NZ…" -> "buy1-sign1-token1-1700000000"
  ✅ 净版(Node) 解密结果相同  "buy1-sign1-token1-1700000000"
  ✅ 净版(裸宿主) 解密结果相同  "buy1-sign1-token1-1700000000"
  ✅ oracle 解密 "hIkqUdgZ/DiQnjXrb0XqyKTi…" -> "免费佩戴-中文-音质-等级"
  ✅ 净版(Node) 解密结果相同  "免费佩戴-中文-音质-等级"
  ✅ 净版(裸宿主) 解密结果相同  "免费佩戴-中文-音质-等级"
  ✅ oracle 解密 "hbQKX/on/jCykBLKb5F/ld36…" -> "中文测试-0-🎵"
  ✅ 净版(Node) 解密结果相同  "中文测试-0-🎵"
  ✅ 净版(裸宿主) 解密结果相同  "中文测试-0-🎵"
  ✅ epParse 结果一致  oracle=["buy1","sign1","token1","1700000000"] mine=["buy1","sign1","token1","1700000000"]
[4] 密钥还原
  ✅ deriveKey("MZ4uGVu3dvMOKb1k") === "MZe3GV3txvMOKb1p"  "MZe3GV3txvMOKb1p"
  ✅ 替换表长度 = 36 且为 0..35 的置换
  ✅ 净版常量与原始脚本运行时 _0x22fc81 完全一致
==============================================================
 自检结果: 31 通过 / 0 失败
==============================================================
```

其中"裸宿主"是把 `ximalaya_ep.js` 丢进一个只有 `console` 的 `vm` context（`atob`/`TextEncoder`/`TextDecoder`/`module`/`Buffer` 全部缺失，
实测逐个断言为 `undefined`）后依然能正确解密三条 golden 向量 —— 这就是"面向 iOS JSC、不依赖宿主"的直接证据。

### 4.4 覆盖度小结

- 输入形状：标准/无填充/URL-safe/空白混入/非法字符/%4==1/纯填充/空串/超长（最长 50KB+ 密文）/随机 unicode/非字符串。
- 明文形状：纯 ASCII、中文、emoji（代理对）、1~6 段 `-` 分隔串（覆盖"段数 ≠ 4"分支）。
- 输出形状：字符串、空串、`null`，以及两种抛错（`EP解密失败` / `EP格式无效`）——两端的**值**与**错误消息**都逐条相等。
- 随机性来源：固定种子 `mulberry32(0x5EED1234)`，所以上面的输出可完整复现。

### 4.5 下游集成侧交叉验证（同目录其他产物，非本任务交付物）

`parser-tools/ep_selfcheck.js` 与集成测试套件（同工作区里针对 iOS 解析脚本的离线自测，直接 `require('./ximalaya_ep.js')`）
在本次工作期间跑过一遍，结果是 **9/9 通过**，其中第 2 项正是对净版的独立交叉核对：

```
PASS  2. ep 加解密往返（100 组随机明文）  → 100 组全部一致（并与独立实现交叉核对 100 次）
结果：9/9 通过
```

这说明净版不仅能跟原始混淆实现逐条等价，也能被下游解析脚本直接当作 `epDecrypt`/`epParse` 使用。

---

## 5. 未能确认的部分 / 假设与风险

1. **是否为喜马拉雅官方算法：未确认。** 本任务只做静态逆向与本地等价验证，没有联网调用喜马拉雅接口，
   也没有真实 `ep` 报文样本。因此"该 RC4+固定密钥是服务端同款算法"这一点，只能由"脚本作者是按这个算法写的、且脚本在真实环境能拼出直链"间接支持，未获服务端验证。
   同理，`buy_key/sign/token/timestamp` 的**语义**取自调用方（§2.8 的 URL 拼装），而非服务端文档。
2. **与任务描述的差异（已按实测修正，请以本报告为准）：**
   - 替代表是 **36 项**不是 35 项（运行时 `_0x22fc81.g.length === 36`）。
   - 替代表只用于**还原 RC4 密钥**，不作用于密文；密文链路是 `base64 → RC4 → UTF-8`，没有"替代表"这一环。
   - 实际参与 RC4 的密钥是还原后的 **`MZe3GV3txvMOKb1p`**，`MZ4uGVu3dvMOKb1k` 只是混淆字面量。
3. **宿主语义假设：** 桩环境里 `atob` 用的是宿主 Node 的规范实现（WHATWG forgiving-base64），`TextDecoder` 用 `util.TextDecoder`。
   两者都按 WHATWG 规范实现，与 iOS JSC 的 `atob`/`TextDecoder` 应当一致，但**没有在真机 JSC 上跑过**；
   若 JSC 在"畸形 padding"这类边角输入上与规范有偏差，理论上可能出现分歧（3400 条用例里没有出现任何分歧，包括 K 类 120 条畸形 padding）。
   实测到的最接近真实 JSC 的路径是 §4.3 的"裸宿主"（只有 ECMAScript 内建对象），净版在那里走的是自己的纯 JS 分支，与 oracle 结果一致。
4. **`_fallbackB64Decode` 缺失是原脚本的缺陷**：缺 `atob` 的宿主里原实现恒失败（环境 B 已验证净版复刻了这个行为）。
   换言之，如果目标 iOS 宿主实际上**没有** `atob`，那么原脚本本身就解不出 `ep`；净版默认走自己的纯 JS base64，
   行为等同于"有 `atob` 的宿主"（即真正能用的那条路）。这一点在迁移时需要明确：**净版比原实现在无 `atob` 宿主上更强**，
   这是唯一一处"故意不保持一致"的地方（用 `env.atob === false` 仍可切回原行为）。
5. **`decrypt` 之外的方法没有验证**：运行时枚举显示 `_0x51df08` 的函数静态成员只有 `decrypt` / `parse` 两个，其余都是别的类（AES-ECB、Cookie 缓存等），不在本任务范围。
6. **没有真机验证**：净版只在 Node 与 `vm` 裸 context 里跑过。iOS JSC 侧的落地验证（例如 Scriptable/Surge 里实跑一次）
   需要真机环境，本任务未覆盖；`epParse` 抛错消息是中文常量，若目标环境的日志/编码有差异，只影响日志可读性，不影响返回值。

---

## 6. 复现命令汇总

```powershell
$node = 'node'
cd 'parser-tools'

node parser-tools/ep_oracle.js                  # 打印静态成员名 + 探针：自造密文 → 原始实现解出明文
node parser-tools/ep_fuzz.js 3400               # 3400/3400 × 三环境（约 165 s）
node parser-tools/ep_selfcheck.js               # 31/31（ES5 解析 / 裸宿主 / golden 向量 / 常量核对）
```

原始参考脚本（通过 `XM_ORIGINAL` 指定）全程只读打开，未做任何修改。
