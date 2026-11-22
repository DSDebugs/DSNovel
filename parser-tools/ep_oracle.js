'use strict';
/**
 * ep_oracle.js
 * ---------------------------------------------------------------------------
 * 作用：用 vm.createContext 造一个 Surge/Loon 风格的桩环境（$request / $response /
 * $done / $persistentStore / $prefs / $httpClient / $task / $notify / $notification /
 * $environment / $ / console / setTimeout / setInterval / window / atob / btoa /
 * TextEncoder / TextDecoder），把通过 XM_ORIGINAL 传入的原始混淆脚本整份
 * runInContext 执行（try/catch 包住，允许中途抛错），再从同一个 context 的全局词法
 * 环境里取出顶层 class `_0x51df08`。
 *
 * 暴露：
 *   hasOriginalOracle(options)                    检查是否配置了可用的原始混淆脚本路径
 *   loadOracle({ atob:true|false, textCodec:true|false }) -> oracle 句柄
 *   oracle.decrypt(input) / oracle.parse(input)   直接调用原实现（this 绑定到类）
 *   oracle.statics                                静态成员名列表
 *   oracle.loadError / oracle.record              加载期错误与桩环境调用记录
 *
 * 只做静态逆向与本地验证：桩环境里没有任何真实网络调用。
 */

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const util = require('util');

const DEFAULT_ORIGINAL = path.join(__dirname, 'ximalaya_ep.js');
const CLASS_BINDING = '_0x51df08';

function resolveOriginalPath(options) {
  options = options || {};
  const candidate = options.original || process.env.XM_ORIGINAL || '';
  return candidate ? path.resolve(candidate) : '';
}

function hasOriginalOracle(options) {
  const srcPath = resolveOriginalPath(options);
  if (!srcPath) return false;
  if (path.resolve(srcPath) === path.resolve(DEFAULT_ORIGINAL)) return false;
  return fs.existsSync(srcPath);
}

/* ------------------------------------------------------------------ *
 * 桩环境
 * ------------------------------------------------------------------ */

function createSandbox(options) {
  options = options || {};
  const record = {
    logs: [],          // console.* / $.log 输出
    done: [],          // $done 收到的响应对象
    http: [],          // $httpClient / $task 调用（不会真的发请求）
    notify: [],        // $notify / $notification
    store: {},         // $persistentStore / $prefs 内存实现
    atobCalls: [],     // atob 收到的字符串（用于确认原实现走的是哪条 base64 分支）
    errors: []
  };

  function pushLog(args) {
    record.logs.push(Array.prototype.map.call(args, function (a) {
      return typeof a === 'string' ? a : util.inspect(a, { depth: 2, breakLength: 200 });
    }).join(' '));
  }

  const store = {
    read: function (key) { return Object.prototype.hasOwnProperty.call(record.store, key) ? record.store[key] : null; },
    write: function (value, key) { record.store[String(key)] = value; return true; },
    valueForKey: function (key) { return store.read(key); },
    setValueForKey: function (value, key) { return store.write(value, key); }
  };

  const sandbox = {
    console: {
      log: function () { pushLog(arguments); },
      info: function () { pushLog(arguments); },
      warn: function () { pushLog(arguments); },
      error: function () { pushLog(arguments); },
      debug: function () { pushLog(arguments); }
    },

    /* 一个"被 rewrite 命中"的假请求/响应，让顶层主流程能走进真实分支 */
    $request: {
      url: 'https://mobile.ximalaya.com/mobile-playpage/track/v4/baseInfo/ts-1700000000?albumId=1&trackId=2',
      method: 'GET',
      headers: { 'User-Agent': 'ting_9.4.50' },
      body: ''
    },
    $response: {
      status: 200,
      headers: { 'Content-Type': 'application/json;charset=utf-8' },
      body: '{"ret":200,"data":{}}'
    },
    $done: function (v) { record.done.push(v); },
    $persistentStore: store,
    $prefs: store,
    $httpClient: {
      get: function (opts, cb) { record.http.push({ m: 'get', o: opts }); if (typeof cb === 'function') { /* 不回调：禁止网络 */ } },
      post: function (opts, cb) { record.http.push({ m: 'post', o: opts }); },
      put: function (opts, cb) { record.http.push({ m: 'put', o: opts }); },
      delete: function (opts, cb) { record.http.push({ m: 'delete', o: opts }); }
    },
    $task: {
      fetch: function (p) { record.http.push({ m: 'fetch' }); return p; }
    },
    $notify: function (t, s, b) { record.notify.push([t, s, b]); },
    $notification: { post: function (t, s, b) { record.notify.push([t, s, b]); return true; } },
    $environment: { 'surge-version': '5.9.0', 'device-model': 'iPhone', language: 'zh-Hans' },
    $argument: '{}',
    $script: { name: 'ximalaya', startTime: Date.now(), type: 'response' },

    /* 脚本内部 catch 分支会用 $.log(...)，必须存在 */
    $: {
      log: function () { pushLog(arguments); },
      done: function () { },
      debug: function () { pushLog(arguments); }
    },

    setTimeout: function () { return 0; },
    setInterval: function () { return 0; },
    clearTimeout: function () { },
    clearInterval: function () { },
    queueMicrotask: function () { },
    window: {},
    globalThisName: 'oracle'
  };

  /* atob / btoa：默认注入（Surge / Loon / JSC 的真实环境有 atob）。
   * 用宿主 Node 规范实现的 atob —— 与 WHATWG 一致：非法字符/长度会抛错。 */
  if (options.atob !== false) {
    const hostAtob = globalThis.atob;
    const hostBtoa = globalThis.btoa;
    sandbox.atob = function (s) { record.atobCalls.push(s); return hostAtob(s); };
    sandbox.btoa = function (s) { return hostBtoa(s); };
  }

  /* TextEncoder / TextDecoder：JSC(Safari 10.1+) 有；可选关掉以复现脚本自带的降级分支 */
  if (options.textCodec !== false) {
    sandbox.TextEncoder = util.TextEncoder;
    sandbox.TextDecoder = util.TextDecoder;
  }

  return { sandbox: sandbox, record: record };
}

/* ------------------------------------------------------------------ *
 * 加载
 * ------------------------------------------------------------------ */

function loadOracle(options) {
  options = options || {};
  const srcPath = resolveOriginalPath(options);
  if (!srcPath || !fs.existsSync(srcPath)) {
    throw new Error('未设置有效的 XM_ORIGINAL 路径；仓库独立测试请直接运行 node parser-tools/ep_fuzz.js');
  }
  const source = fs.readFileSync(srcPath, 'utf8');
  const built = createSandbox(options);
  const ctx = vm.createContext(built.sandbox, { name: 'xmly-oracle' });

  let loadError = null;
  try {
    vm.runInContext(source, ctx, { filename: srcPath, timeout: options.timeout || 60000 });
  } catch (e) {
    // 顶层主流程在桩环境里中断是预期内的：只要类声明语句本身已执行即可
    loadError = e;
    built.record.errors.push(String((e && e.message) || e));
  }

  // ---- 从 context 的全局词法环境取类 ----
  let kind = vm.runInContext('typeof ' + CLASS_BINDING, ctx);
  if (kind !== 'function') {
    throw new Error('无法从 vm context 取到 class ' + CLASS_BINDING + '（typeof=' + kind + '），loadError=' + loadError);
  }
  const cls = vm.runInContext(CLASS_BINDING, ctx);

  const statics = vm.runInContext(
    'Object.getOwnPropertyNames(' + CLASS_BINDING + ').filter(function(n){return typeof ' + CLASS_BINDING + '[n] === "function";})',
    ctx
  );

  const pick = function (want) {
    if (statics.indexOf(want) >= 0) return want;
    const re = new RegExp(want, 'i');
    for (let i = 0; i < statics.length; i++) if (re.test(statics[i])) return statics[i];
    return null;
  };
  const decryptName = pick('decrypt');
  const parseName = pick('parse');

  const oracle = {
    cls: cls,
    ctx: ctx,
    statics: statics,
    decryptName: decryptName,
    parseName: parseName,
    loadError: loadError,
    record: built.record,
    sourcePath: srcPath,
    /** 原实现 decrypt（this 绑定到类，等价于源码里的静态调用） */
    decrypt: function (input) { return cls[decryptName](input); },
    /** 原实现 parse */
    parse: function (input) { return cls[parseName](input); },
    /** 统一的安全包装：不抛错，返回 {ok:true,value} / {ok:false,error} */
    safeDecrypt: function (input) {
      try { return { ok: true, value: cls[decryptName](input) }; }
      catch (e) { return { ok: false, error: e, message: String((e && e.message) || e), name: (e && e.name) || 'Error' }; }
    },
    safeParse: function (input) {
      try { return { ok: true, value: cls[parseName](input) }; }
      catch (e) { return { ok: false, error: e, message: String((e && e.message) || e), name: (e && e.name) || 'Error' }; }
    },
    /** 取桩环境里捕获的日志（每次调用后清空便于定位） */
    drainLogs: function () { const l = built.record.logs.slice(); built.record.logs.length = 0; return l; },
    /** 读 context 里任意顶层词法绑定（let/const/class 都行），用于核对常量 */
    lexical: function (name) {
      try { return { ok: true, value: vm.runInContext(name, ctx) }; }
      catch (e) { return { ok: false, message: String((e && e.message) || e) }; }
    }
  };
  return oracle;
}

module.exports = { loadOracle, hasOriginalOracle, createSandbox, CLASS_BINDING, DEFAULT_ORIGINAL };

/* ------------------------------------------------------------------ *
 * 直接运行时的自检输出
 * ------------------------------------------------------------------ */

if (require.main === module) {
  if (!hasOriginalOracle({})) {
    console.log('[ep_oracle] 未设置 XM_ORIGINAL，跳过原始混淆脚本加载。请使用 node parser-tools/ep_fuzz.js 执行独立往返模糊测试。');
    process.exit(0);
  }
  const o = loadOracle({});
  console.log('source      :', o.sourcePath);
  console.log('statics     :', o.statics.join(', '));
  console.log('decryptName :', o.decryptName, '| parseName:', o.parseName);
  console.log('loadError   :', o.loadError ? String(o.loadError.message || o.loadError) : '(none)');
  console.log('record.errs :', o.record.errors.length);
  console.log('$done calls :', o.record.done.length, '| http calls:', o.record.http.length);
  console.log('logs(first) :', o.record.logs.slice(0, 5));
  console.log('atob calls  :', o.record.atobCalls.length);

  // 手工构造一个自洽的密文：RC4(key).encrypt("buy-xxx-sign-yyy") 再 base64
  const key = 'MZe3GV3txvMOKb1p';
  const rc4 = function (data, k) {
    const S = new Uint8Array(256);
    for (let i = 0; i < 256; i++) S[i] = i;
    for (let i = 0, j = 0; i < 256; i++) { j = (j + S[i] + k.charCodeAt(i % k.length)) & 255; const t = S[i]; S[i] = S[j]; S[j] = t; }
    const out = new Uint8Array(data.length);
    for (let i = 0, j = 0, n = 0; n < data.length; n++) { i = (i + 1) & 255; j = (j + S[i]) & 255; const t = S[i]; S[i] = S[j]; S[j] = t; out[n] = data[n] ^ S[(S[i] + S[j]) & 255]; }
    return out;
  };
  const plain = 'buy_key_demo-sign_demo-token_demo-1700000000';
  const ct = rc4(Buffer.from(plain, 'utf8'), key);
  const b64 = Buffer.from(ct).toString('base64');
  console.log('probe cipher :', b64);
  const r = o.safeDecrypt(b64);
  console.log('probe decrypt:', JSON.stringify(r.value), r.ok ? '' : r.message);
  const p = o.safeParse(b64);
  console.log('probe parse  :', p.ok ? JSON.stringify(p.value) : ('ERR ' + p.message));
  console.log('probe logs   :', o.drainLogs());
  o.safeDecrypt('%%%not base64%%%').value;
  console.log('invalid logs :', o.drainLogs());
}
