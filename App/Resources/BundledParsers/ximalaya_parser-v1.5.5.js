/**
 * 喜马拉雅解析（DSNovel 内置解析脚本）
 * =============================================================================
 * 用途：为 DSNovel「书源管理 → 内置解析」提供喜马拉雅受限/付费章节的播放与下载直链解析。
 * 导入：设置 → 书源管理 → 喜马拉雅 → 内置解析 → 导入脚本（.js）
 *
 * 与原始 Surge 版 ximalaya.js 的关系（本脚本只保留「受限章节的播放/下载」这一件事）：
 *
 *   删除的内容
 *     · 全部 MITM 层：rewrite 规则、mitm hostname/IP 表、$request/$response/$done
 *     · Env.js / BoxJS 基础设施与代理端持久化
 *     · 7 个「伪造客户端权限态」handler（home/product/album/playpage/quality/download/playerSkin）
 *       —— 本 App 自己就是客户端，改这些字段没有意义
 *     · 作者水印（把昵称写成电报频道）与三处第三方图片注入
 *     · 远端 eval(Utils.js) 加载 CryptoJS —— 改用宿主 host.aesEcbDecrypt / host.md5
 *     · 广告与上报拦截规则（App 不需要拦代理）
 *     · 混淆层（2224 条字符串数组、278 个 wrapper、控制流平坦化、debugger、每 4 秒爆栈的注入载荷）
 *
 *   保留并优化的内容
 *     · 付费接口链路：track/pay → fileId(AES-ECB) → ep(base64+RC4) → buy_key/sign/token/timestamp
 *       重拼 /download/1.0.0/ 直链（同时用于播放与下载）
 *     · 免费/试听接口兜底：playpage → playPathHq / playPathAacv164 / playUrl64 / playPathAacv224 / playUrl32
 *     · 音质优先级：高音质失败自动逐级回落（原脚本只请求一次）
 *     · 新增 downloadUrl / expiresAt / reason 错误码 / checkStatus() 自检
 * =============================================================================
 * v1.2.0（与 App「统一语义档位表」对齐）变更清单
 * =============================================================================
 *   1. version → 1.2.0；id 保持 ximalaya-vip（保证老用户原地升级，不产生第二个解析器）；
*      显示名于 v1.3 改为中性的「喜马拉雅解析」
 *      （老用户原地升级，不会多出一个脚本）
 *   2. 音质档位对齐：新增语义档位 auto / saver / standard / high / lossless，
 *      同时继续兼容旧码 M4A_24 / M4A_48 / M4A_64 / M4A_128 / FLAC_16 / FLAC_24 / ATMOS_24；
 *      未识别码按「最接近档，并列时向上」映射并记日志（M4A_96 → high，未知字符串 → high）。
 *      逐级回落顺序保持并覆盖全部 5 档：ATMOS_24 → FLAC_24 → FLAC_16 → M4A_128 → M4A_48
 *   3. 免费兜底按档位取流（不再写死取第一个可用字段）；免费直链的 quality 如实标注；
 *      请求 URL 里的 qualityLevel 按档位填（不再写死 1）
 *   4. 请求顺序：先免费/试听接口（1 次请求即可拿到直链），失败再走付费链路；
 *      付费链路（fileId → AES-ECB → ep → buy_key/sign/token → /download/1.0.0/）完整保留
 *   5. Cookie 来源固定在脚本内部：① 本机登录态 → ② host.getPref('cookie') 手工粘贴（可选）
 *      → ③ 远端共享 Cookie 兜底（缓存 1 小时）；都拿不到 → no_cookie
 *   6. 直链缓存秒数 linkTTL 改为脚本内常量（默认 900 秒，上限 1800 秒），返回值仍带 expiresAt
 *   7. meta：新增 qualities；config 只保留 sampleTrackId（删除 quality / cookieSource /
 *      allowRemoteCookie / remoteCookieURL / linkTTL 五项声明）
 *   8. checkStatus()：sampleTrackId 为空时用最近一次成功解析过的 trackId（host.getPref('lastTrackId')）
 *      做一次真实解析探测；探测失败如实返回原因（不报 ok=true）
 *   9. 每次解析成功/失败都写 host.log，链路对用户可见
 *  10. 无 MITM/代理内容、无 eval、不联网拉取其它脚本；保持 ES5 与 IIFE + registerBuiltinParser 结构
 * =============================================================================
 * v1.3.0（Cookie 权限性选择 + 付费优先 + 显式码表 + 日志可读化）变更清单
 * =============================================================================
 *   C1 Cookie 选择：从「存在性」改为「权限性」
 *      · 新增 cookieCandidates(host)：返回有序候选数组 [{cookie, origin}]，顺序为
 *        ① user（host.cookies('https://www.ximalaya.com/') 且必须含 1&_token）
 *        ② pref（host.getPref('cookie') 手工粘贴，可选，空则跳过）
 *        ③ remote（远端共享，惰性拉取；必须先通过 C2 校验，未通过则跳过并写日志）
 *      · 付费链路按候选逐个尝试：当前候选返回「无权限类」→ 记日志换下一个候选；
 *        其它失败（api_failed / 单档位未返回直链）→ 记日志换下一个候选；日志写明是哪一种
 *      · 本机凭据本身有权限时绝不使用共享凭据（本机成功即结束）
 *      · 全部候选都无权限 → 抛 parserError('not_vip', ...)，msg 区分
 *        「本机未开通权益，且共享凭据也不可用」
 *      · Cookie 读取来源与键名保持 v1.2 不变（host.cookies / host.getPref('cookie') / 远端共享）
 *   C2 共享凭据有效性校验
 *      · 真正需要用到 remote 候选时，先用一次轻量请求校验：
 *        PROFILE_API=getCurrentUser（web 桌面 UA + Referer: https://www.ximalaya.com/ + 该 Cookie）
 *      · 判定：HTTP 正常且 ret === 200（ret 缺失时看是否有 data）→ 视为有效；
 *        同时尽量取出会员标志位与到期时间用于日志
 *      · 校验结果缓存 host.writeCache/host.readCache，key = remote_cookie_check.json，TTL 30 分钟
 *        （缓存里带 Cookie 指纹，共享 Cookie 换新会自动重新校验）
 *      · 校验不通过 → 跳过 remote 候选，日志写明「共享凭据校验未通过，已跳过」
 *   C3 付费优先（回到 v1.0 顺序）
 *      · 删除 v1.2 的「免费接口优先」：免费链路只在所有候选的付费链路都失败之后兜底执行一次
 *        （用第一个可用候选）
 *      · 例外：付费接口返回 ret === 130（该曲目免费、付费接口不适用）→ 直接转入免费链路，
 *        不再换候选
 *      · 日志能看出顺序：先付费、后免费
 *   C4 试听识别（已确认不要试听内容）
 *      · 付费响应满足 isAuthorized === false 或 sampleDuration > 0（且 sampleLength > 0）
 *        → 不得返回该地址，抛 parserError('trial_only', '该章节仅提供试听，需要会员或购买')
 *      · 免费响应若含 sampleDuration > 0 → 同样判为试听并抛 trial_only
 *      · 判定与拒绝都写日志（含 sampleDuration / sampleLength / totalLength 等观测值）
 *   C5 显式返回码表（替代中文关键词猜测）
 *      · var RET_CODES = { 0:'ok', 130:'free_track', 726:'no_permission',
 *                          1001:'no_permission', 1002:'no_permission' }；其它非 0 → api_failed
 *        （message 里带上 ret 与 msg）
 *      · no_permission → 触发 C1「换下一个候选」；free_track → 触发 C3「转入免费链路」；
 *        api_failed → 记录后换下一个候选；全部候选都失败 → 抛 parserError('paid_api_failed', ...)
 *      · 对外 reason 码与 v1.2 完全一致（no_cookie / not_vip / paid_api_failed / free_api_failed /
 *        rate_limited / bad_track / expired_link），只新增 trial_only；
 *        error 对象上额外挂中性字段 reasonClass（不改变 reason 取值）
 *   C6 日志可读化：候选清单 → 逐候选付费尝试 → 码表归类 → 换源 → 共享凭据校验 →
 *      付费→免费兜底顺序 → 试听拒绝 → 成功来源与档位，决策链肉眼可追
 *   v1.3.0 规格补充（精确化，冻结）
 *      · no_permission（726 / 1001 / 1002）不得再尝试免费接口：所有候选都无权限后直接抛
 *        parserError('not_vip', ...)（权限受限的内容免费接口也不可能给正片，多一次请求只会
 *        增加拿到试听/低码率片段的风险）→ 免费接口调用次数必须为 0
 *      · trial_only 同样不回落免费链路：判定为试听后立刻抛错
 *      · free_track（ret=130）必须先试过付费（付费优先天然满足，paidTried ≥ 1），
 *        日志能看出「付费 → 130 → 转免费」的顺序，最终返回免费正片地址
 *   其它：checkStatus 增强（额外输出本机/共享凭据状态与会员到期时间）；version → 1.3.0；
 *        id/name/qualities/config/targets、linkTTL 常量、lastTrackId 记录、checkStatus 探测逻辑、
 *        EP 解密、档位表、free_api 字段选择逻辑（FREE_PREFERENCE / FREE_KEY_QUALITY）保持 v1.2
 * =============================================================================
 * v1.4.0（档位表按实测重写 + 实际档位回传 + 超清加强 + 自检最高档）变更清单
 * =============================================================================
 *   S1 接受新档位标识并兼容旧标识（大小写不敏感，未知值仍走「最接近档」兜底并写日志）
 *      · 新标识：auto / std / hd / uhd
 *      · 兼容旧标识：saver / standard / high / lossless / ultra / atmos /
 *        M4A_24 / M4A_32 / M4A_48 / M4A_64 / M4A_96 / M4A_128 / FLAC_16 / FLAC_24 / ATMOS_24
 *      · 映射：std·saver·standard·M4A_24·M4A_32 → 0；hd·high·M4A_48·M4A_64 → 1；
 *        uhd·ultra·lossless·M4A_96·M4A_128·FLAC_16·FLAC_24 → 2；atmos·ATMOS_24 → 12；
 *        auto → 1（App 侧已按网络细化，脚本按「高清」处理并写日志）
 *      · 档位模型改为以服务端档位序号 level 为中心（QUALITY_LEVEL_MAP / LEVEL_INFO），
 *        v1.3 的 SEMANTIC_QUALITY / LEGACY_QUALITY / QUALITY_PAID_ANCHOR / QUALITY_ORDER 退役
 *   S2 档位 → 服务端请求档位：std→0、hd→1、uhd→2（超清按最高可用档处理，见 S3.3）、atmos→12
 *   S3 自动降档 + 回传实际档位（核心）
 *      · 新增 paidRequestOnce（单次请求 + 码表归类）与「实际档位解析」：
 *        downloadQualityLevel 优先；缺失时取 min(highestQualityLevel, 请求档)；两者都缺失按请求档
 *      · capped = 实际档 < 请求档；降档不再视为失败，照常返回直链并写日志
 *      · 超清加强（paidAttempt 内，最多 +1 次请求）：请求档为 2 且响应 highestQualityLevel ≥ 3
 *        → 再按 highestQualityLevel 请求一次，返回更高档结果，日志「检测到更高档 level N，已改用」
 *      · 回落链保持高→低：12 → 2 → 1 → 0（qualityChain 改为按 level 生成）
 *   S4 结果携带体积与时长（付费/免费两条路径一致）：新增 requestedLevel / actualLevel /
 *      actualQuality / tierName / measuredKbps（round(fileSize*8/durationSec/1000)）/ capped /
 *      maxLevel（无则省略）；quality 不再回传 highestQualityLevel 数字，改为回传 actualQuality
 *   S5 日志写明「请求档位 → 实际档位 / 是否降档」，档位名用中文（标准/高清/超清）：
 *      「请求 超清(uhd) → level 2；实际 level 2（M4A_96，约 129k）未降档」
 *      「请求 超清(uhd) → level 2；实际 level 1（M4A_64，约 64k）已降档（该曲目最高 level 1）」
 *      「检测到更高档 level 3，已改用」（logTierOutcomePaid / logTierOutcomeFree）
 *   S6 checkStatus 探测成功后额外输出最高可用档位（highestQualityLevel → 档位名 + 名义码率），
 *      形如「最高可用：超清（level 2，名义 96k）」，并以 maxLevel / maxTierName / maxQuality
 *      / maxLevelNote 字段结构化回传；探测失败仍如实返回 ok:false（保持 v1.3 行为）
 *   保持不变：凭据候选与权限性选择（user → pref → remote，含共享凭据校验与缓存）、付费优先 +
 *      免费兜底、no_permission 不碰免费、trial_only 立刻抛出、试听识别、RET_CODES、EP 解密、
 *      linkTTL 常量、lastTrackId、targets、id（ximalaya-vip）、显示名（喜马拉雅解析）、
 *      ES5 + IIFE + registerBuiltinParser、无 eval、无 MITM
 * =============================================================================
 * v1.5.0（时长单位修正 + 旧档位码双侧对齐 + 热路径记忆化）变更清单
 * =============================================================================
 *   F1 修正 duration 单位（真 bug，v1.2–v1.4 一直存在）
 *      · 服务端 duration 实测为「秒」（例：560 秒的章节返回 560），旧代码按毫秒除以 1000
 *      · 后果一：durationSec 偏小约 1000 倍，measuredKbps 相应放大约 1000 倍
 *      · 后果二（严重）：App 侧「试听片段」弱校验为 got < 期望时长 × 0.6，被该 bug 触发后
 *        会把完整音频判为试听片段并回落官方通道，受限章节因此表现为「解析失败」
 *      · 新增 normalizeDurationSec()：按秒取整；仅当数值 > 86400（单集不可能达到的秒数）
 *        时才按毫秒折算；付费与免费两条链路统一走该函数
 *   F2 旧档位码按「低 / 中 / 高」升序对齐（与 App 的 标准 / 高清 / 超清 三档一一对应）
 *      · saver → 0、standard → 1、high → 2
 *        （v1.4 及以前为 standard → 0 / high → 1，与 App 新档位名错开一档，
 *          是「选超清却只到高清、选高清却掉到标准」的根因）
 *      · 新标识 std / hd / uhd 与 lossless / ultra / M4A_128 / FLAC_* 取值不变（0 / 1 / 2）
 *      · 与 App 侧「改发新码」互为双侧防御：任一侧单独漏改都不会再错位
 *   F3 热路径记忆化（只缓存纯函数的计算结果，语义与 v1.4 完全一致）
 *      · fileId → 直链路径：命中原 fileId 即省一次宿主 AES 解密与路径解析
 *      · ep → [buy_key, sign, token, timestamp]：按 ep 原文记忆（机会性命中）
 *      · trackId → 更高档不可用：避免对同一曲目重复发起无效的「更高档」探测
 *      · str()/num() 增加单层键快路径，省去 split 与数组分配
 *      · 缓存上限固定（超出即整体清空），内存可控；只影响「是否重复计算」，不影响结果
 *   保持不变：凭据候选与权限性选择（user → pref → remote）、付费优先 + 免费兜底、
 *      no_permission 不碰免费、trial_only 立刻抛出、试听识别、RET_CODES、EP 解密算法、
 *      linkTTL 常量、lastTrackId、targets、id（ximalaya-vip）、显示名（喜马拉雅解析）、
 *      ES5 + IIFE + registerBuiltinParser、无 eval、无 MITM
 * =============================================================================
 */

(function () {
  'use strict';

  // ---------------------------------------------------------------------------
  // 1. 常量
  // ---------------------------------------------------------------------------

  /** 付费直链接口（返回 fileId / ep / domain / duration 等） */
  var PAY_API = 'http://mpaywsa.ximalaya.com/mobile/track/pay';
  /** 免费/试听接口（返回 trackInfo 与各档音质直链） */
  var FREE_API = 'http://mobile.ximalaya.com/fmobile-track/fmobile/track/playpage';
  /** Web 端用户信息接口（C2 共享凭据校验 + checkStatus 自检：读取昵称与会员到期） */
  var PROFILE_API = 'https://www.ximalaya.com/revision/main/getCurrentUser';
  /** fileId 的 AES-ECB 解密密钥（与官方客户端一致） */
  var AES_KEY = 'a0QnjTaA9YicRj7H';
  /** 远端共享 Cookie 兜底地址（脚本内固定，App 不再下发） */
  var DEFAULT_REMOTE_COOKIE_URL = 'https://raw.githubusercontent.com/WeiGiegie/666/main/xmly_data.json';
  /** 远端共享 Cookie 缓存键与有效期（1 小时） */
  var REMOTE_COOKIE_CACHE_KEY = 'remote_cookie.json';
  var REMOTE_COOKIE_TTL_MS = 3600000;
  /** 共享凭据有效性校验结果缓存键与有效期（C2：30 分钟） */
  var REMOTE_CHECK_CACHE_KEY = 'remote_cookie_check.json';
  var REMOTE_CHECK_TTL_MS = 1800000;
  /** 官方客户端 UA（付费/免费接口必须） */
  var API_UA = 'ting_v3.0.3_c5(CFNetwork, iOS 16.2, iPhone13,4) ; xmly(lite)/3.0.3/ios_1';
  var ACCEPT_LANGUAGE = 'zh-Hans-US;q=1,en-GB;q=0.9,en-US;q=0.8,zh-Hant-US;q=0.7';

  /** 直链缓存秒数：脚本内常量（App 不再下发 linkTTL），上限 1800 */
  var LINK_TTL_SEC = 900;
  var LINK_TTL_MAX_SEC = 1800;

  /** 最近一次成功解析的 trackId 的偏好键（checkStatus 探测用） */
  var PREF_LAST_TRACK_ID = 'lastTrackId';

  /**
   * C5：付费接口返回码表（显式码表，替代 v1.2 的「中文关键词猜测」）
   *   0    ok            正常返回 fileId/ep
   *   130  free_track    该曲目免费，付费接口不适用 → 直接转入免费链路
   *   726  no_permission 需要会员/未购买该专辑 → 换下一个候选
   *   1001 no_permission
   *   1002 no_permission
   *   其它非 0 → api_failed（message 里带上 ret 与 msg）→ 记录后换下一个候选
   */
  var RET_CODES = { 0: 'ok', 130: 'free_track', 726: 'no_permission', 1001: 'no_permission', 1002: 'no_permission' };

  // ---------------------------------------------------------------------------
  // 1.1 音质档位表（v1.4：以服务端档位序号 level 为中心）
  //
  //  实测：付费接口 trackQualityLevel 是由低到高的档位序号，与官方 App 档位对应：
  //    level 0  标准音质  名义 24k   实测 ≈24.8k
  //    level 1  高清音质  名义 48k   实测 ≈48–65k
  //    level 2  超高音质  名义 96k   实测 ≈96–130k（会员）
  //    level 3 / 12  该曲目不存在，服务端会钳制回 2（返回与 level 2 同一份文件）
  //
  //  响应字段：
  //    highestQualityLevel   本曲目最高档
  //    downloadQualityLevel  实际生效档（被钳制时小于请求档）
  //    totalLength           字节数
  //    duration              秒（实测口径：560 秒的章节返回 560）
  //
  //  v1.4 档位标识（大小写不敏感）→ level
  //    auto → 1（App 侧已按网络细化；脚本收到 auto 时按「高清」处理并写日志）
  //    std  → 0（标准 24k）  hd → 1（高清 48k）  uhd → 2（超清 96k = 最高可用档，见 S3 加强）
  //    兼容旧标识（按「码率高低」语义对齐官方三档）：
  //      saver / standard / M4A_24 / M4A_32                  → 0
  //      high / M4A_48 / M4A_64                              → 1
  //      lossless / ultra / M4A_96 / M4A_128 / FLAC_16 / FLAC_24 → 2
  //      atmos / ATMOS_24                                    → 12
  //    未识别标识仍走「最接近档（并列向上）」兜底并写日志
  // ---------------------------------------------------------------------------

  /** 服务端档位序号 */
  var LEVEL_STD = 0;
  var LEVEL_HD = 1;
  var LEVEL_UHD = 2;
  var LEVEL_ATMOS = 12;

  /**
   * 档位序号 → { tierId, tierName, canonical, nominalKbps }
   *   tierId     App 侧档位标识（meta.qualities / 免费取流族：std / hd / uhd / higher）
   *   tierName   中文档位名（日志与结果展示：标准 / 高清 / 超清 / 更高档）
   *   canonical  对外规范码（quality / actualQuality）
   *   nominalKbps 名义码率，0 表示名义未知（此时优先用实测码率）
   */
  var LEVEL_INFO = {
    '0': { tierId: 'std', tierName: '标准', canonical: 'M4A_24', nominalKbps: 24 },
    '1': { tierId: 'hd', tierName: '高清', canonical: 'M4A_64', nominalKbps: 48 },
    '2': { tierId: 'uhd', tierName: '超清', canonical: 'M4A_96', nominalKbps: 96 },
    '3': { tierId: 'higher', tierName: '更高档', canonical: 'FLAC_24', nominalKbps: 0 },
    '12': { tierId: 'higher', tierName: '更高档', canonical: 'ATMOS_24', nominalKbps: 0 }
  };

  /** 档位序号由高到低（回落链 12 → 2 → 1 → 0；3 仅在显式请求时使用） */
  var LEVEL_ORDER = [12, 3, 2, 1, 0];

  /**
   * 档位标识（小写）→ 服务端请求档位
   *
   * 两套词汇表都按「低 → 高」升序对齐同一把梯子（实测口径）：
   *   level 0 = 标准（名义 24k）   level 1 = 高清（名义 48k）   level 2 = 超清（名义 96k）
   *   level 3 / 12 = 更高档（无损 / 全景声；仅少数内容存在，服务端会按可用上限自动钳制回 2）
   *
   *   · 新标识（App 新版本下发）：std → 0、hd → 1、uhd → 2
   *   · 旧标识（v1.5 起按升序对齐）：saver → 0、standard → 1、high → 2
   *     ⚠️ v1.4 及以前 standard = 0、high = 1，与 App「标准/高清/超清」错开一档
   *   · 旧码（老版本 App 直接下发）：M4A_24 / M4A_32 → 0；M4A_48 / M4A_64 → 1；
   *     M4A_96 / M4A_128 / FLAC_16 / FLAC_24 / lossless / ultra → 2；atmos / ATMOS_24 → 12
   *   · auto → 1：App 侧已按网络细化为具体档位，脚本收到 auto 时按「高清」处理并写日志
   */
  var QUALITY_LEVEL_MAP = {
    // 新标识（App 新版本下发）
    'auto': 1,
    'std': 0,
    'hd': 1,
    'uhd': 2,
    // 兼容旧标识（按低 / 中 / 高升序对齐，v1.5 调整）
    'saver': 0,
    'standard': 1,
    'high': 2,
    'lossless': 2,
    'ultra': 2,
    'atmos': 12,
    // 兼容旧码（老版本 App 直接下发）
    'm4a_24': 0,
    'm4a_32': 0,
    'm4a_48': 1,
    'm4a_64': 1,
    'm4a_96': 2,
    'm4a_128': 2,
    'flac_16': 2,
    'flac_24': 2,
    'atmos_24': 12
  };

  /** 未识别档位做「最接近」映射时用的码率梯形（kbps 升序；距离并列时取更高档） */
  var M4A_LADDER = [
    { kbps: 24, level: 0 },
    { kbps: 48, level: 1 },
    { kbps: 64, level: 1 },
    { kbps: 96, level: 2 },
    { kbps: 128, level: 2 }
  ];

  /** 免费接口各档位族 → 直链字段优先级（按档取流，不写死取第一个可用字段） */
  var FREE_PREFERENCE = {
    // 标准：优先低码率字段，再依次向上取
    'std': ['playUrl32', 'playPathAacv224', 'playUrl64', 'playPathAacv164', 'playPathHq'],
    // 高清：优先 64k（playUrl64 / playPathAacv164），再退更低、再向上
    'hd': ['playUrl64', 'playPathAacv164', 'playPathHq', 'playUrl32', 'playPathAacv224'],
    // 超清：免费接口一般没有 96k，取它能提供的最高（playPathHq 优先），再退 64k / 更低
    'uhd': ['playPathHq', 'playPathAacv164', 'playUrl64', 'playPathAacv224', 'playUrl32'],
    // 更高档（3 / 12）：免费接口都没有无损/全景声，同样取最高可用
    'higher': ['playPathHq', 'playPathAacv164', 'playUrl64', 'playPathAacv224', 'playUrl32']
  };

  /** 免费字段的真实音质标注（曾把 playPathAacv164 / playUrl64 虚标成 M4A_128，已修正） */
  var FREE_KEY_QUALITY = {
    'playPathHq': 'HQ',
    'playPathAacv164': 'M4A_64',
    'playUrl64': 'M4A_64',
    'playUrl32': 'M4A_32',
    'playPathAacv224': 'M4A_24'
  };

  /** 免费字段对应的档位序号（用于回传 actualLevel / tierName / capped） */
  var FREE_KEY_LEVEL = {
    'playPathHq': 2,
    'playPathAacv164': 1,
    'playUrl64': 1,
    'playUrl32': 0,
    'playPathAacv224': 0
  };

  /** 免费字段的人类可读说明（日志用） */
  var FREE_KEY_LABEL = {
    'playPathHq': 'HQ 最高可用',
    'playPathAacv164': 'AAC v1 64k',
    'playUrl64': '标准 64k',
    'playUrl32': '省流 32k',
    'playPathAacv224': 'AAC v2 24k'
  };

  // ---------------------------------------------------------------------------
  // 2. ep 解密（等价于原混淆脚本 class _0x51df08.decrypt，纯 JS 实现）
  //
  //    链路：去空白 → forgiving-base64 解码 → RC4（密钥由固定串经 36 项替换表还原）
  //          → UTF-8 解码；任何一步失败返回 null
  //    密钥还原：'MZ4uGVu3dvMOKb1k' --替换表--> 'MZe3GV3txvMOKb1p'
  // ---------------------------------------------------------------------------

  var OBFUSCATED_KEY = 'MZ4uGVu3dvMOKb1k';
  var SUBST_TABLE = [
    33, 1, 24, 23, 2, 30, 10, 3, 7, 14,
    15, 28, 32, 16, 5, 31, 13, 9, 22, 0,
    29, 21, 17, 25, 8, 26, 35, 27, 6, 19,
    4, 20, 18, 34, 12, 11
  ];

  function deriveRc4Key(obfuscated) {
    var out = '';
    for (var i = 0; i < obfuscated.length; i++) {
      var c = obfuscated.charAt(i);
      var v = obfuscated.charCodeAt(i) - ((c >= 'a' && c <= 'z') ? 97 : 22);
      if (v >= 0 && v < SUBST_TABLE.length) v = SUBST_TABLE[v];
      out += String.fromCharCode(v <= 25 ? 97 + v : 22 + v);
    }
    return out;
  }

  var RC4_KEY_BYTES = (function () {
    var key = deriveRc4Key(OBFUSCATED_KEY);
    var bytes = [];
    for (var i = 0; i < key.length; i++) bytes.push(key.charCodeAt(i) & 0xFF);
    return bytes;
  }());

  var B64_ALPHABET = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  var B64_LOOKUP = (function () {
    var t = {};
    for (var i = 0; i < B64_ALPHABET.length; i++) t[B64_ALPHABET.charAt(i)] = i;
    return t;
  }());

  function base64ToBytes(input) {
    var data = input.replace(/[\u0009\u000A\u000C\u000D\u0020]/g, '');
    if (data.length === 0) return [];
    if (data.length % 4 === 0) {
      if (data.charAt(data.length - 1) === '=') {
        data = data.substring(0, data.length - 1);
        if (data.charAt(data.length - 1) === '=') data = data.substring(0, data.length - 1);
      }
    }
    if (data.length % 4 === 1) throw new Error('Invalid character');
    var out = [];
    var buffer = 0, bits = 0;
    for (var i = 0; i < data.length; i++) {
      var ch = data.charAt(i);
      if (!Object.prototype.hasOwnProperty.call(B64_LOOKUP, ch)) throw new Error('Invalid character');
      buffer = (buffer << 6) | B64_LOOKUP[ch];
      bits += 6;
      if (bits >= 8) {
        bits -= 8;
        out.push((buffer >> bits) & 0xFF);
      }
    }
    return out;
  }

  function rc4(dataBytes, keyBytes) {
    var s = [], i, j, t;
    for (i = 0; i < 256; i++) s[i] = i;
    for (j = 0, i = 0; i < 256; i++) {
      j = (j + s[i] + keyBytes[i % keyBytes.length]) & 0xFF;
      t = s[i]; s[i] = s[j]; s[j] = t;
    }
    var out = [];
    i = 0; j = 0;
    for (var n = 0; n < dataBytes.length; n++) {
      i = (i + 1) & 0xFF;
      j = (j + s[i]) & 0xFF;
      t = s[i]; s[i] = s[j]; s[j] = t;
      out[n] = dataBytes[n] ^ s[(s[i] + s[j]) & 0xFF];
    }
    return out;
  }

  function utf8Decode(bytes) {
    var out = '', i = 0, n = bytes.length;
    while (i < n) {
      var b0 = bytes[i];
      if (b0 < 0x80) { out += String.fromCharCode(b0); i += 1; continue; }
      if (b0 >= 0xC2 && b0 <= 0xDF) {
        if (i + 1 < n && bytes[i + 1] >= 0x80 && bytes[i + 1] <= 0xBF) {
          out += String.fromCharCode(((b0 & 0x1F) << 6) | (bytes[i + 1] & 0x3F)); i += 2;
        } else { out += '\uFFFD'; i += 1; }
        continue;
      }
      if (b0 >= 0xE0 && b0 <= 0xEF) {
        var lo = 0x80, hi = 0xBF;
        if (b0 === 0xE0) lo = 0xA0; else if (b0 === 0xED) hi = 0x9F;
        if (i + 1 < n && bytes[i + 1] >= lo && bytes[i + 1] <= hi) {
          if (i + 2 < n && bytes[i + 2] >= 0x80 && bytes[i + 2] <= 0xBF) {
            out += String.fromCharCode(((b0 & 0x0F) << 12) | ((bytes[i + 1] & 0x3F) << 6) | (bytes[i + 2] & 0x3F));
            i += 3;
          } else { out += '\uFFFD'; i += 2; }
        } else { out += '\uFFFD'; i += 1; }
        continue;
      }
      if (b0 >= 0xF0 && b0 <= 0xF4) {
        var lo4 = 0x80, hi4 = 0xBF;
        if (b0 === 0xF0) lo4 = 0x90; else if (b0 === 0xF4) hi4 = 0x8F;
        if (i + 1 < n && bytes[i + 1] >= lo4 && bytes[i + 1] <= hi4) {
          if (i + 2 < n && bytes[i + 2] >= 0x80 && bytes[i + 2] <= 0xBF) {
            if (i + 3 < n && bytes[i + 3] >= 0x80 && bytes[i + 3] <= 0xBF) {
              var cp = ((b0 & 0x07) << 18) | ((bytes[i + 1] & 0x3F) << 12) |
                       ((bytes[i + 2] & 0x3F) << 6) | (bytes[i + 3] & 0x3F);
              cp -= 0x10000;
              out += String.fromCharCode(0xD800 + (cp >> 10), 0xDC00 + (cp & 0x3FF));
              i += 4;
            } else { out += '\uFFFD'; i += 3; }
          } else { out += '\uFFFD'; i += 2; }
        } else { out += '\uFFFD'; i += 1; }
        continue;
      }
      out += '\uFFFD';
      i += 1;
    }
    return out;
  }

  /** ep 解密：失败返回 null */
  function epDecrypt(input) {
    try {
      if (typeof input !== 'string' || !input) return null;
      var cleaned = input.replace(/[\s\u00A0\u1680\u2000-\u200A\u2028\u2029\u202F\u205F\u3000\uFEFF]/g, '');
      return utf8Decode(rc4(base64ToBytes(cleaned), RC4_KEY_BYTES));
    } catch (e) {
      return null;
    }
  }

  /** ep → [buy_key, sign, token, timestamp] */
  function epParse(input) {
    var decrypted = epDecrypt(input);
    if (!decrypted) throw parserError('paid_api_failed', 'ep 解密失败');
    var parts = decrypted.split('-');
    if (parts.length !== 4) throw parserError('paid_api_failed', 'ep 格式无效');
    return parts;
  }

  // ---------------------------------------------------------------------------
  // 3. 工具
  // ---------------------------------------------------------------------------

  /**
   * 构造带语义 reason 码的错误。
   * reason 必须是 v1.2 已对外暴露的取值之一（no_cookie / not_vip / paid_api_failed /
   * free_api_failed / rate_limited / bad_track / expired_link）+ v1.3 新增的 trial_only；
   * reasonClass 是中性的附加字段，不改变 reason 取值（C5）。
   */
  function parserError(reason, message, reasonClass) {
    var err = new Error(message || reason);
    err.reason = reason;
    if (reasonClass) err.reasonClass = reasonClass;
    return err;
  }

  function msgOf(e) {
    return (e && e.message) ? String(e.message) : String(e);
  }

  function str(obj, path) {
    if (obj === null || obj === undefined) return '';
    if (!path) return String(obj);
    var s = String(path);
    if (s.indexOf('.') < 0) {          // F3 快路径：多数调用是单层键，省去 split 与数组分配
      var single = obj[s];
      return (single === null || single === undefined) ? '' : String(single);
    }
    var parts = s.split('.');
    var cur = obj;
    for (var i = 0; i < parts.length; i++) {
      if (cur === null || cur === undefined) return '';
      cur = cur[parts[i]];
    }
    return (cur === null || cur === undefined) ? '' : String(cur);
  }

  function num(obj, path, def) {
    var v = parseInt(str(obj, path), 10);
    return isNaN(v) ? (def === undefined ? 0 : def) : v;
  }

  function hasKey(obj, key) {
    return !!(obj && typeof obj === 'object' && Object.prototype.hasOwnProperty.call(obj, key)
      && obj[key] !== null && obj[key] !== undefined);
  }

  function parseJson(text) {
    text = String(text === undefined || text === null ? '' : text);
    if (text.charCodeAt(0) === 0xFEFF) text = text.slice(1);
    text = text.trim();
    if (text.indexOf(")]}'") === 0) text = text.replace(/^\)\]\}'[,\s]*/, '').trim();
    try {
      return JSON.parse(text);
    } catch (e) {}
    var m = /^[a-zA-Z_$][\w$.]*\s*\(([\s\S]*)\)\s*;?\s*(?:\/\*[\s\S]*?\*\/\s*|\/\/[^\n]*\s*)*$/.exec(text);
    if (m) return JSON.parse(m[1].trim());
    throw new SyntaxError('Invalid JSON payload');
  }

  /** C5：ret 数值 → 语义归类（未知非 0 一律 api_failed） */
  function retClass(ret) {
    if (Object.prototype.hasOwnProperty.call(RET_CODES, String(ret))) return RET_CODES[String(ret)];
    return ret === 0 ? 'ok' : 'api_failed';
  }

  function apiHeaders(cookie) {
    var h = {
      'User-Agent': API_UA,
      'Accept-Language': ACCEPT_LANGUAGE
    };
    if (cookie) h['Cookie'] = cookie;
    return h;
  }

  function nowSec() {
    return Math.floor(Date.now() / 1000);
  }

  function looksLikeURLPath(value) {
    return !!value && /^[A-Za-z0-9._~%\-\/?=&:+,@]+$/.test(value);
  }

  /** 章节地址 → trackId（兼容 xm:123 / ...trackId=123 / 裸数字） */
  function trackIdFromEpisode(episodeURL) {
    var s = String(episodeURL || '');
    var m = /xm:(\d+)/.exec(s)
      || /trackId=(\d+)/i.exec(s)
      || /\/(?:sound|track)\/(\d+)/i.exec(s)
      || /\/album\/\d+\/(\d+)/i.exec(s);
    if (m) return m[1];
    var all = s.match(/\d{6,}/g);
    return (all && all.length) ? all[all.length - 1] : '';
  }

  /** 播放地址出现 403/失效的判定，宿主会在失败后重新调用本脚本 */
  function isExpiredHint(text) {
    return /expired|失效|过期|403|forbidden/i.test(String(text || ''));
  }

  // ---------------------------------------------------------------------------
  // 3.1 音质档位解析（S1：新标识 + 旧标识兼容 + 未识别码「最接近，并列向上」）
  // ---------------------------------------------------------------------------

  function hasOwn(obj, key) {
    return Object.prototype.hasOwnProperty.call(obj, key);
  }

  /**
   * 从未识别码里取「码率/位深」数字：
   *   'M4A_96' → 96（不能取到前缀里的 4）、'xm96v2' → 96、'96k' → 96、'M4A_1' → 1
   * 规则：取从右往左第一个 ≥2 位的数字段，没有则取最后一个数字段
   */
  function lastNumberToken(key) {
    var runs = String(key).match(/\d+/g) || [];
    for (var i = runs.length - 1; i >= 0; i--) {
      if (runs[i].length >= 2) return runs[i];
    }
    return runs.length ? runs[runs.length - 1] : '';
  }

  /**
   * 未识别标识 → 档位序号（最接近，并列向上）
   *   atmos…        → 12
   *   flac…         → 2（无损族在服务端最高只到第 2 档可用，3 会被钳制回 2）
   *   带码率数字    → 取最接近的梯形档（并列时取更高档）
   *   不带数字      → 1（高清）
   */
  function nearestLevelForKey(key) {
    if (/atmos/.test(key)) return LEVEL_ATMOS;
    if (/flac/.test(key)) return LEVEL_UHD;
    var token = lastNumberToken(key);
    if (!token) return LEVEL_HD;
    var kbps = parseInt(token, 10);
    var best = M4A_LADDER[0];
    var bestDist = Math.abs(kbps - best.kbps);
    for (var i = 1; i < M4A_LADDER.length; i++) {
      var d = Math.abs(kbps - M4A_LADDER[i].kbps);
      // 距离更小，或距离并列但码率更高（并列时向上）
      if (d < bestDist || (d === bestDist && M4A_LADDER[i].kbps > best.kbps)) {
        best = M4A_LADDER[i];
        bestDist = d;
      }
    }
    return best.level;
  }

  /** 档位序号 → 展示/记账信息（表外序号给保守信息，避免 undefined） */
  function levelInfo(level) {
    if (hasOwn(LEVEL_INFO, String(level))) return LEVEL_INFO[String(level)];
    if (level >= 3) return { tierId: 'higher', tierName: '更高档', canonical: 'M4A_96', nominalKbps: 0 };
    return { tierId: 'hd', tierName: '高清', canonical: 'M4A_64', nominalKbps: 0 };
  }

  /**
   * 档位标识 → 解析结果（S1 / S2）
   * @returns {{raw:string, level:number, tierId:string, tierName:string, canonical:string,
   *            family:string, recognized:boolean}}
   *   level      服务端请求档位（0 / 1 / 2 / 12 或表外序号）
   *   tierName   中文档位名（标准 / 高清 / 超清 / 更高档）
   *   canonical  规范码（请求档位对应的对外码）
   *   family     免费兜底取流族（std / hd / uhd / higher）
   */
  function resolveQuality(code) {
    var raw = String(code === undefined || code === null ? '' : code).replace(/^\s+|\s+$/g, '');
    if (!raw) raw = 'auto';
    var key = raw.toLowerCase();
    var recognized = true;
    var level;

    if (hasOwn(QUALITY_LEVEL_MAP, key)) {
      level = QUALITY_LEVEL_MAP[key];
    } else {
      recognized = false;
      level = nearestLevelForKey(key);
    }

    var info = levelInfo(level);
    return {
      raw: raw,
      level: level,
      tierId: info.tierId,
      tierName: info.tierName,
      canonical: info.canonical,
      family: info.tierId,
      recognized: recognized
    };
  }

  /** 解析档位并记录「未识别档位 / auto 按高清」日志 */
  function resolveQualityLogged(host, code) {
    var q = resolveQuality(code);
    if (!q.recognized) {
      host.log('未识别档位 ' + q.raw + '，按 ' + q.tierName + ' 处理（' + q.canonical + ' / level ' + q.level + '）');
    } else if (q.raw.toLowerCase() === 'auto') {
      host.log('档位 auto → 按「高清」（level ' + q.level + '）处理（App 侧已按网络细化）');
    }
    return q;
  }

  /** 选定档位及其以下的付费回落顺序（高→低：12 → 2 → 1 → 0） */
  function qualityChain(level) {
    var chain = [];
    for (var i = 0; i < LEVEL_ORDER.length; i++) {
      var lv = LEVEL_ORDER[i];
      if (lv > level) continue;
      if (level === LEVEL_ATMOS && lv === 3) continue;   // 全景声回落链不经过 3
      chain.push(lv);
    }
    if (chain.indexOf(LEVEL_STD) < 0) chain.push(LEVEL_STD);
    return chain;
  }

  // ---------------------------------------------------------------------------
  // 3.2 实际档位解析与结果字段（S3 / S4 / S5）
  // ---------------------------------------------------------------------------

  /** 响应里的档位序号（字段缺失或非数字 → null） */
  function numLevel(obj, key) {
    if (!hasKey(obj, key)) return null;
    var raw = obj[key];
    if (raw === null || raw === undefined || typeof raw === 'boolean') return null;
    var n = parseInt(String(raw), 10);
    return isNaN(n) ? null : n;
  }

  /**
   * 服务端 duration 归一化为「秒」（F1）
   *   实测口径：付费接口返回秒（560 秒的章节返回 560）；免费接口 trackInfo.duration 同为秒
   *   防御：仅当数值超过 24 小时（单集不可能达到）时才按毫秒折算，避免个别来源口径差异导致失真
   */
  function normalizeDurationSec(v) {
    if (!(v > 0)) return 0;
    if (v > 86400) v = v / 1000;
    return Math.round(v);
  }

  // ---------------------------------------------------------------------------
  // 3.3 跨 JSContext 持久化缓存（v1.5.2）：基于 host.readCache / writeCache
  //     · link_v1_slot_0..15.json  16 分片直链缓存，每槽最多 4 条按 t LRU 淘汰，按 expiresAt - 60s 有效
  //     · HIGHER_FAIL_CACHE_KEY    trackId → 更高档不可用标记（TTL 24h，上限 32 条）
  // ---------------------------------------------------------------------------
  var LINK_CACHE_SLOT_LIMIT = 4;
  var LINK_CACHE_SAFETY_SEC = 60;
  var HIGHER_FAIL_CACHE_KEY = 'higher_fail_v1.json';
  var HIGHER_FAIL_LIMIT = 32;
  var HIGHER_FAIL_TTL_MS = 86400000;

  function readJsonCache(host, key) {
    try {
      var raw = host.readCache(key);
      if (!raw) return {};
      var obj = JSON.parse(raw);
      return (obj && typeof obj === 'object' && !Array.isArray(obj)) ? obj : {};
    } catch (e) {
      return {};
    }
  }

  function writeJsonCache(host, key, obj) {
    try {
      host.writeCache(key, JSON.stringify(obj));
    } catch (e) { /* 缓存写入失败不影响主链路 */ }
  }

  function hashSlot16(text) {
    var h = 5381;
    var s = String(text || '');
    for (var i = 0; i < s.length; i++) {
      h = ((h << 5) + h + s.charCodeAt(i)) & 0x7FFFFFFF;
    }
    return h % 16;
  }

  function cachedRemoteCookieFp(host) {
    try {
      var raw = host.readCache(REMOTE_COOKIE_CACHE_KEY);
      if (!raw) return 'none';
      var obj = JSON.parse(raw);
      if (obj && obj.cookie && (Date.now() - num(obj, 't', 0)) < REMOTE_COOKIE_TTL_MS) {
        return cookieFingerprint(host, String(obj.cookie)).slice(-8);
      }
    } catch (e) {}
    return 'none';
  }

  function credentialCacheTag(host, candidates, hitCredential) {
    var parts = [];
    if (Array.isArray(candidates)) {
      for (var i = 0; i < candidates.length; i++) {
        var c = candidates[i];
        if (c && c.origin !== 'remote' && c.cookie) {
          parts.push(c.origin + ':' + cookieFingerprint(host, c.cookie).slice(-8));
        }
      }
    }
    var remoteFp = (hitCredential && hitCredential.origin === 'remote' && hitCredential.fingerprint)
      ? hitCredential.fingerprint
      : cachedRemoteCookieFp(host);
    parts.push('remote:' + remoteFp);
    return parts.join('|');
  }

  function linkCacheKeyFor(trackId, level) {
    return 'link_v1_slot_' + hashSlot16(String(trackId) + ':' + String(level)) + '.json';
  }

  function readSlotEntries(slotObj) {
    if (!slotObj || typeof slotObj !== 'object') return [];
    if (Array.isArray(slotObj.items)) return slotObj.items;
    if (slotObj.trackId && slotObj.result) return [slotObj];
    return [];
  }

  function readLinkCache(host, trackId, level, credTag) {
    var slotKey = linkCacheKeyFor(trackId, level);
    var list = readSlotEntries(readJsonCache(host, slotKey));
    var tid = String(trackId);
    var tag = String(credTag || 'remote');
    var minExp = nowSec() + LINK_CACHE_SAFETY_SEC;
    for (var i = 0; i < list.length; i++) {
      var entry = list[i];
      if (!entry || entry.trackId !== tid || entry.level !== level || entry.credTag !== tag || !entry.result || !entry.result.url) {
        continue;
      }
      if (num(entry.result, 'expiresAt', 0) <= minExp) return null;
      entry.t = Date.now();
      writeJsonCache(host, slotKey, { items: list });
      return entry.result;
    }
    return null;
  }

  function writeLinkCache(host, trackId, level, credTag, result) {
    if (!result || !result.url || !(num(result, 'expiresAt', 0) > nowSec() + LINK_CACHE_SAFETY_SEC)) return;
    var slotKey = linkCacheKeyFor(trackId, level);
    var list = readSlotEntries(readJsonCache(host, slotKey));
    var tid = String(trackId);
    var tag = String(credTag || 'remote');
    var minExp = nowSec() + LINK_CACHE_SAFETY_SEC;
    var kept = [];
    for (var i = 0; i < list.length; i++) {
      var item = list[i];
      if (!item || !item.result || !item.result.url) continue;
      if (num(item.result, 'expiresAt', 0) <= minExp) continue;
      if (item.trackId === tid && item.level === level && item.credTag === tag) continue;
      kept.push(item);
    }
    kept.push({
      trackId: tid,
      level: level,
      credTag: tag,
      t: Date.now(),
      result: result
    });
    if (kept.length > LINK_CACHE_SLOT_LIMIT) {
      kept.sort(function (a, b) { return num(a, 't', 0) - num(b, 't', 0); });
      while (kept.length > LINK_CACHE_SLOT_LIMIT) kept.shift();
    }
    writeJsonCache(host, slotKey, { items: kept });
  }

  function isHigherFailCached(host, trackId) {
    var map = readJsonCache(host, HIGHER_FAIL_CACHE_KEY);
    var k = 'k' + String(trackId);
    if (!hasOwn(map, k)) return false;
    return (Date.now() - num(map, k, 0)) < HIGHER_FAIL_TTL_MS;
  }

  function markHigherFailCached(host, trackId) {
    var map = readJsonCache(host, HIGHER_FAIL_CACHE_KEY);
    var k = 'k' + String(trackId);
    var now = Date.now();
    var keys = [];
    for (var key in map) {
      if (!hasOwn(map, key)) continue;
      if ((now - num(map, key, 0)) >= HIGHER_FAIL_TTL_MS) delete map[key];
      else keys.push(key);
    }
    if (keys.length >= HIGHER_FAIL_LIMIT && !hasOwn(map, k)) {
      keys.sort(function (a, b) { return num(map, a, 0) - num(map, b, 0); });
      while (keys.length >= HIGHER_FAIL_LIMIT) delete map[keys.shift()];
    }
    map[k] = now;
    writeJsonCache(host, HIGHER_FAIL_CACHE_KEY, map);
  }

  /** 实测码率整数 kbps（fileSize 字节 / durationSec 秒 都已知时给出，否则 0） */
  function measuredKbpsOf(fileSize, durationSec) {
    if (!(fileSize > 0) || !(durationSec > 0)) return 0;
    return Math.round(fileSize * 8 / durationSec / 1000);
  }

  /** S5：码率说明（优先实测码率，其次名义码率） */
  function kbpsText(measured, level) {
    if (measured > 0) return '约 ' + measured + 'k';
    var nominal = levelInfo(level).nominalKbps;
    return nominal > 0 ? ('名义 ' + nominal + 'k') : '码率未知';
  }

  /** S5：付费链路「请求档位 → 实际档位 / 是否降档」日志 */
  function logTierOutcomePaid(host, requested, actualLevel, measured, maxLevel) {
    var line = '请求 ' + requested.tierName + '(' + requested.raw + ') → level ' + requested.level
      + '；实际 level ' + actualLevel + '（' + levelInfo(actualLevel).canonical + '，' + kbpsText(measured, actualLevel) + '）';
    if (actualLevel < requested.level) {
      line += '已降档（' + ((maxLevel === null || maxLevel === undefined)
        ? '服务端已降档返回'
        : '该曲目最高 level ' + maxLevel) + '）';
    } else {
      line += '未降档';
    }
    host.log(line);
  }

  /** S5：免费兜底链路「请求档位 → 实际档位 / 是否降档」日志（规范码用免费字段的真实标注） */
  function logTierOutcomeFree(host, requested, actualLevel, measured, key, label) {
    var code = label || levelInfo(actualLevel).canonical;
    var line = '请求 ' + requested.tierName + '(' + requested.raw + ') → level ' + requested.level
      + '；实际 level ' + actualLevel + '（' + code + '，' + kbpsText(measured, actualLevel)
      + '，免费接口 ' + key + '）';
    line += (actualLevel < requested.level) ? '已降档（免费接口无对应档位）' : '未降档';
    host.log(line);
  }

  /** S6：最高可用档位（来自响应 highestQualityLevel）→ 档位名 + 名义码率 */
  function maxLevelSummary(maxLevel) {
    if (maxLevel === null || maxLevel === undefined) return null;
    var info = levelInfo(maxLevel);
    var nominal = info.nominalKbps > 0 ? ('名义 ' + info.nominalKbps + 'k') : '名义码率未知';
    return {
      level: maxLevel,
      tierName: info.tierName,
      canonical: info.canonical,
      text: '最高可用：' + info.tierName + '（level ' + maxLevel + '，' + nominal + '）'
    };
  }

  // ---------------------------------------------------------------------------
  // 4. 注册解析器
  // ---------------------------------------------------------------------------

  registerBuiltinParser({
    id: 'ximalaya-vip',
    name: '喜马拉雅解析',
    version: '1.5.5',
    author: 'shun · DSNovel 内置解析适配版',
    description: '解析喜马拉雅受限/付费章节的播放与下载直链：先按 Cookie 候选（本机登录态 → 手工粘贴 → 远端共享）逐个走付费链路（音质按档位 auto/std/hd/uhd 取流，并按服务端档位序号逐级回落 12→2→1→0），全部失败后用第一个可用候选做一次免费接口兜底；共享凭据先经有效性校验（缓存 30 分钟），仅试听内容一律拒绝（trial_only）。结果回传实际生效档位（actualLevel/actualQuality/tierName）与体积时长（fileSize/durationSec/measuredKbps），并标注是否被降档（capped）。',

    // host 优先 + sourceID 兜底（内置 ShunAudiobookPro 包的喜马拉雅源 id 作为兜底）
    targets: {
      hosts: ['ximalaya.com', 'xmcdn.com'],
      sourceIDs: ['6e2b9c4d8a1f4d37b5c0e73a9f1d2b64']
    },
    networkHosts: ['raw.githubusercontent.com'],
    capabilities: { playback: true, download: true, needsCookie: true },

    // 音质能力声明（App 侧读取；读不到时 App 会退化为按 sourceID 判定）
    qualities: ['auto', 'std', 'hd', 'uhd'],

    // config 只保留自检样本章节 id（quality / cookieSource / allowRemoteCookie /
    // remoteCookieURL / linkTTL 已由 App 侧系统托管，不再声明、不再显示）
    config: [
      { key: 'sampleTrackId', title: '自检用章节 ID（可空）', defaultValue: '', kind: 'text' }
    ],

    // -------------------------------------------------------------------------
    // 4.1 自检：本机/共享凭据状态 +（可选）真解析一次
    //     v1.3 增强：额外输出本机凭据与共享凭据的状态、会员到期时间
    // -------------------------------------------------------------------------
    checkStatus: function () {
      var host = this.host;
      var started = Date.now();

      var candidates = cookieCandidates(host);
      var state = { remoteState: 'unused' };
      var i;

      var nickname = '', vipExpireAt = '';
      var localCredential = { present: false, origin: '', valid: false, nickname: '', vipExpireAt: '' };
      var sharedCredential = { available: false, valid: false, vipExpireAt: '', note: '未校验' };

      // ① 本机凭据：按 user → pref 顺序逐一校验（前一个失效时继续校验后续本地候选，与 resolveAudio 降级策略对齐）
      for (i = 0; i < candidates.length; ) {
        var localCand = candidates[i];
        if (localCand.origin === 'remote') { i++; continue; }
        localCredential.present = true;
        localCredential.origin = localCand.origin;
        var profile = null;
        var localErr = '';
        try {
          profile = host.getJson(PROFILE_API, {
            desktop: true,
            headers: { 'Referer': 'https://www.ximalaya.com/', 'Cookie': localCand.cookie }
          });
        } catch (e) {
          if (e && e.cancelled) throw e;
          localErr = '账号信息接口请求失败：' + msgOf(e);
        }
        if (!localErr && num(profile, 'ret', -1) === 200 && profile && profile.data) {
          nickname = str(profile, 'data.nickname') || str(profile, 'data.nickName');
          var rawExpire = str(profile, 'data.vipInfo.expireTime')
            || str(profile, 'data.vipInfo.expiredTime')
            || str(profile, 'data.vipInfo.endTime')
            || str(profile, 'data.vipExpireTime');
          vipExpireAt = formatExpire(rawExpire);
          localCredential.valid = true;
          localCredential.nickname = nickname;
          localCredential.vipExpireAt = vipExpireAt;
          host.log('自检：本机凭据有效（来源=' + localCand.origin + (vipExpireAt ? '，会员到期 ' + vipExpireAt : '') + '）');
          break;
        } else {
          localCredential.valid = false;
          localCredential.note = localErr || ('账号信息接口返回异常：ret=' + num(profile, 'ret', -1) + ' ' + str(profile, 'msg'));
          host.log('自检：本机凭据不可用（来源=' + localCand.origin + '，' + localCredential.note + '），继续检测后续凭据');
          candidates.splice(i, 1);
        }
      }

      // ② 共享凭据状态（C2 校验；校验结果有 30 分钟缓存，通常不再额外请求）
      var remoteIndex = -1;
      for (i = 0; i < candidates.length; i++) {
        if (candidates[i].origin === 'remote') remoteIndex = i;
      }
      if (remoteIndex >= 0) {
        var loaded = loadCandidate(host, candidates[remoteIndex], state);
        if (loaded) {
          sharedCredential.available = true;
          sharedCredential.valid = true;
          sharedCredential.vipExpireAt = (loaded.check && loaded.check.vipExpireAt) ? loaded.check.vipExpireAt : '';
          sharedCredential.note = '有效（非本人账号，仅显示到期时间'
            + (sharedCredential.vipExpireAt ? ' ' + sharedCredential.vipExpireAt : '') + '）';
          candidates[remoteIndex] = loaded;      // 探测时复用，不再重复拉取/校验
        } else {
          sharedCredential.note = (state.remoteState === 'invalid') ? '校验未通过' : '不可用';
          candidates.splice(remoteIndex, 1);
        }
      }

      // ③ 两条凭据都不可用时如实报错
      if (!localCredential.valid && !sharedCredential.valid) {
        return {
          ok: false,
          message: '未取到可用 Cookie（本机未登录，共享凭据' + sharedCredential.note
            + '），可在书源管理里登录喜马拉雅会员账号',
          latencyMs: Date.now() - started,
          nickname: '',
          vipExpireAt: '',
          localCredential: localCredential,
          sharedCredential: sharedCredential
        };
      }

      // ④ 解析探测目标：优先 sampleTrackId，为空时用最近一次成功解析过的 trackId
      var sample = String(host.getPref('sampleTrackId', '') || '').replace(/\D/g, '');
      var sampleSource = 'sampleTrackId';
      if (!sample) {
        sample = String(host.getPref(PREF_LAST_TRACK_ID, '') || '').replace(/\D/g, '');
        sampleSource = PREF_LAST_TRACK_ID;
      }

      var probeNote = '';
      var maxInfo = null;
      if (sample) {
        try {
          var probe = resolveByChain(host, sample, resolveQualityLogged(host, 'auto'), candidates, false);
          // S6：额外输出被探测曲目的最高可用档位（来自响应 highestQualityLevel）
          maxInfo = maxLevelSummary(probe.maxLevel);
          var maxText = maxInfo ? maxInfo.text : '最高可用：未知（响应未返回 highestQualityLevel）';
          probeNote = ' · 试解析成功（探测章节 ' + sampleSource + '=' + sample + '，音质 ' + probe.quality + '）'
            + ' · ' + maxText;
          host.log('自检：' + maxText);
        } catch (e) {
          if (e && e.cancelled) throw e;
          var reason = (e && e.reason) ? e.reason : 'failed';
          var detail = msgOf(e);
          host.log('自检解析探测失败（' + sampleSource + '=' + sample + '）：' + reason + ' ' + detail);
          return {
            ok: false,
            message: '探测章节解析失败：' + reason + (detail ? '（' + detail + '）' : '')
              + ' · 探测来源 ' + sampleSource + '=' + sample,
            latencyMs: Date.now() - started,
            nickname: nickname,
            vipExpireAt: vipExpireAt,
            localCredential: localCredential,
            sharedCredential: sharedCredential
          };
        }
      } else {
        probeNote = ' · 未配置样本章节且无历史记录，未做解析探测';
      }

      var out = {
        ok: true,
        message: '本机凭据：' + (localCredential.valid ? '有效' : (localCredential.present ? '已失效' : '未取到'))
          + (vipExpireAt ? '（会员到期 ' + vipExpireAt + '）' : '')
          + ' · 共享凭据：' + sharedCredential.note + probeNote,
        latencyMs: Date.now() - started,
        nickname: nickname,
        vipExpireAt: vipExpireAt,
        localCredential: localCredential,
        sharedCredential: sharedCredential
      };
      // S6：最高可用档位结构化回传（未探测到 / 响应未给 highestQualityLevel 时省略）
      if (maxInfo) {
        out.maxLevel = maxInfo.level;
        out.maxTierName = maxInfo.tierName;
        out.maxQuality = maxInfo.canonical;
        out.maxLevelNote = maxInfo.text;
      } else if (sample) {
        out.maxLevelNote = '最高可用：未知（响应未返回 highestQualityLevel）';
      }
      return out;
    },

    // -------------------------------------------------------------------------
    // 4.2 解析：宿主在「书源接口拿不到地址（受限/付费章节）」时调用
    //     request = { sourceID, episodeURL, trackId, forDownload, quality }
    //     quality 可为档位标识（auto/std/hd/uhd，或兼容旧标识 saver/standard/high/lossless/
    //     ultra/atmos 与旧码 M4A_24…/FLAC_16…/ATMOS_24），大小写不敏感
    //     v1.3：先按 Cookie 候选逐个跑付费链路，全部失败才免费兜底（C1/C3）
    //     v1.4：付费链路按服务端档位序号回落（12→2→1→0），结果回传实际生效档位（S3/S4）
    // -------------------------------------------------------------------------
    resolveAudio: function (request) {
      var host = this.host;
      var trackId = String((request && request.trackId) ? request.trackId : '').replace(/\D/g, '');
      if (!trackId) trackId = trackIdFromEpisode(request && (request.episodeURL || request.url));
      if (!trackId) throw parserError('bad_track', '无法从章节地址识别 trackId', 'bad_track');

      var qualityCode = (request && request.quality) ? request.quality : host.getPref('quality', 'auto');
      var quality = resolveQualityLogged(host, qualityCode);
      var forDownload = !!(request && request.forDownload);

      // C1：Cookie 候选（user → pref → remote 惰性），C6：候选清单写日志
      var candidates = cookieCandidates(host);
      if (!candidates.length) {
        throw parserError('no_cookie', '未取到可用 Cookie，可在书源管理里登录喜马拉雅会员账号', 'no_cookie');
      }

      host.log('开始解析 trackId=' + trackId
        + ' 档位=' + quality.raw + '→level ' + quality.level + '（' + quality.tierName + ' · ' + quality.canonical + '）'
        + ' 凭据候选=' + candidates.length + ' 个'
        + (forDownload ? ' 下载' : ' 播放'));

      var bypassCache = !!(request && request.bypassCache);
      var isFreeChapter = (request && request.isVIP === false);
      var credTag = credentialCacheTag(host, candidates);
      if (!bypassCache) {
        var cachedLink = readLinkCache(host, trackId, quality.level, credTag);
        if (cachedLink) {
          host.log('命中跨调用直链缓存 trackId=' + trackId + ' level=' + quality.level + '（剩余 ' + (num(cachedLink, 'expiresAt', 0) - nowSec()) + 's）');
          var cloned = {};
          for (var ck in cachedLink) { if (hasOwn(cachedLink, ck)) cloned[ck] = cachedLink[ck]; }
          cloned.note = forDownload ? (cloned.isPaid ? 'paid-download-cached' : 'free-download-cached') : (cloned.isPaid ? 'paid-play-cached' : 'free-play-cached');
          markLastTrackId(host, trackId);
          return cloned;
        }
      } else {
        host.log('收到 bypassCache=true，跳过直链缓存重新解析 trackId=' + trackId);
      }

      var result = resolveByChain(host, trackId, quality, candidates, forDownload, isFreeChapter);
      var writeCredTag = credentialCacheTag(host, candidates, result && result.hitCredential);
      writeLinkCache(host, trackId, quality.level, writeCredTag, result);
      markLastTrackId(host, trackId);
      return result;
    }
  });

  // ---------------------------------------------------------------------------
  // 5. Cookie 候选（C1：按「权限性」选择；C2：共享凭据先校验）
  // ---------------------------------------------------------------------------

  /** 记录最近一次成功解析的 trackId（checkStatus 探测用） */
  function markLastTrackId(host, trackId) {
    try {
      host.setPref(PREF_LAST_TRACK_ID, String(trackId));
    } catch (e) {
      host.log('记录 lastTrackId 失败：' + msgOf(e));
    }
  }

  /**
   * C1：Cookie 候选（有序数组）
   *   ① user   —— host.cookies('https://www.ximalaya.com/')，必须含登录令牌 1&_token
   *   ② pref   —— host.getPref('cookie')，手工粘贴（可选中间来源，空则跳过）
   *   ③ remote —— 远端共享（惰性：真正需要用到时才拉取 + 经 C2 校验；不通过则跳过并记日志）
   * 本机凭据（user/pref）成功时，remote 候选永远不会触发任何请求。
   */
  function cookieCandidates(host) {
    var candidates = [];

    // ① 本机登录态
    try {
      var local = host.cookies('https://www.ximalaya.com/') || '';
      if (/(^|;\s*)1&_token=[^;]+/.test(local)) {
        host.log('Cookie 来源=user（本机登录态）');
        candidates.push({ cookie: local, origin: 'user' });
      }
    } catch (e) {
      host.log('读取本机 Cookie 失败：' + msgOf(e));
    }

    // ② 手工粘贴（可选）
    var manual = String(host.getPref('cookie', '') || '').replace(/[\r\n]/g, '').trim();
    if (manual) {
      host.log('Cookie 来源=pref（手工粘贴）');
      candidates.push({ cookie: manual, origin: 'pref' });
    }

    // ③ 远端共享（惰性候选）
    candidates.push({ origin: 'remote', lazy: true });

    var names = [];
    for (var i = 0; i < candidates.length; i++) names.push(candidates[i].origin);
    host.log('Cookie 候选：' + names.join(' / ') + '（共 ' + candidates.length + ' 个）');
    return candidates;
  }

  /**
   * 取出候选真正可用的凭据对象；返回 null 表示该候选不可用（原因已写日志）
   *   · user / pref —— 候选里已带好 Cookie，直接返回
   *   · remote      —— 惰性：拉取共享 Cookie（缓存 1 小时）→ C2 校验（缓存 30 分钟）
   */
  function loadCandidate(host, cand, state) {
    if (!cand) return null;
    if (!cand.lazy) return cand;

    var shared = readRemoteCookie(host);
    if (!shared) {
      host.log('共享凭据不可用：远端共享 Cookie 获取失败，已跳过');
      if (state) state.remoteState = 'unavailable';
      return null;
    }
    host.log('Cookie 来源=remote' + (shared.cached ? '（缓存）' : '（远端共享）'));

    var check = checkRemoteCookie(host, shared.cookie);
    if (!check.ok) {
      if (check.transient) {
        host.log('共享凭据校验瞬态失败（已退避 45s，保留远端缓存）：' + check.detail);
        if (state) state.remoteState = 'unavailable';
        return null;
      }
      host.log('共享凭据校验未通过，已跳过（' + check.detail + '）');
      clearRemoteCookieCache(host);          // 仅明确业务拒绝时清空共享 Cookie 缓存（AUD-43）
      if (state) state.remoteState = 'invalid';
      return null;
    }
    host.log('共享凭据校验：有效' + (check.vipExpireAt ? '（会员到期 ' + check.vipExpireAt + '）' : '')
      + (check.vipFlag ? '（会员标志=' + check.vipFlag + '）' : ''));
    if (check.fromCache) host.log('共享凭据校验结果来自缓存（30 分钟内不再校验）');
    if (state) state.remoteState = 'available';
    return { cookie: shared.cookie, origin: 'remote', cached: shared.cached, check: check };
  }

  /** 远端共享 Cookie（缓存 1 小时） */
  function readRemoteCookie(host) {
    var cached = null;
    try {
      cached = host.readCache(REMOTE_COOKIE_CACHE_KEY);
    } catch (e) {
      cached = null;
    }
    if (cached) {
      try {
        var cachedObj = JSON.parse(cached);
        if (cachedObj && cachedObj.cookie && (Date.now() - num(cachedObj, 't', 0)) < REMOTE_COOKIE_TTL_MS) {
          return { cookie: String(cachedObj.cookie), cached: true };
        }
      } catch (e) { /* 缓存损坏 → 重新拉取 */ }
    }

    try {
      var body = host.getString(DEFAULT_REMOTE_COOKIE_URL, {
        headers: { 'User-Agent': host.userAgent(false) }
      });
      var json = parseJson(body);
      var remoteCookie = String(json.cookie || '').replace(/[\r\n]/g, '').trim();
      if (remoteCookie) {
        host.writeCache(REMOTE_COOKIE_CACHE_KEY, JSON.stringify({ cookie: remoteCookie, t: Date.now() }));
        return { cookie: remoteCookie, cached: false };
      }
      host.log('远端共享 Cookie 返回内容为空');
    } catch (e) {
      if (e && e.cancelled) throw e;
      host.log('远端共享 Cookie 获取失败：' + msgOf(e));
    }
    return null;
  }

  /** 清空失效的共享 Cookie 缓存（M-08） */
  function clearRemoteCookieCache(host) {
    try {
      host.writeCache(REMOTE_COOKIE_CACHE_KEY, '');
    } catch (e) { /* 缓存清理失败不影响主链路 */ }
  }

  /** Cookie 指纹（校验缓存按凭据隔离，共享 Cookie 换新会自动重新校验） */
  function cookieFingerprint(host, cookie) {
    var text = String(cookie || '');
    try {
      if (typeof host.md5 === 'function') return 'md5:' + host.md5(text);
    } catch (e) { /* 回落到手写哈希 */ }
    var h = 5381;
    for (var i = 0; i < text.length; i++) h = ((h << 5) + h + text.charCodeAt(i)) & 0x7FFFFFFF;
    return 'h:' + h.toString(36) + ':' + text.length;
  }

  /**
   * C2：共享凭据有效性校验
   *   请求 PROFILE_API（web 桌面 UA + Referer: https://www.ximalaya.com/ + 该 Cookie）
   *   判定：ret === 200（ret 缺失时看是否有 data）→ 有效；顺带取会员标志位与到期时间
   *   结果缓存 remote_cookie_check.json，TTL 30 分钟（带 Cookie 指纹）
   */
  var REMOTE_CHECK_TRANSIENT_TTL_MS = 45 * 1000;

  function checkRemoteCookie(host, cookie) {
    var fp = cookieFingerprint(host, cookie);
    var cached = null;
    try {
      var raw = host.readCache(REMOTE_CHECK_CACHE_KEY);
      if (raw) cached = JSON.parse(raw);
    } catch (e) { cached = null; }
    if (cached && cached.fp === fp) {
      var ttlMs = cached.transient ? REMOTE_CHECK_TRANSIENT_TTL_MS : REMOTE_CHECK_TTL_MS;
      if ((Date.now() - num(cached, 't', 0)) < ttlMs) {
        return {
          ok: cached.ok === true,
          transient: cached.transient === true,
          fromCache: true,
          vipExpireAt: String(cached.vipExpireAt || ''),
          vipFlag: String(cached.vipFlag || ''),
          detail: String(cached.detail || '缓存判定')
        };
      }
    }

    var result = { ok: false, transient: false, fromCache: false, vipExpireAt: '', vipFlag: '', detail: '' };
    try {
      var profile = host.getJson(PROFILE_API, {
        desktop: true,
        headers: { 'Referer': 'https://www.ximalaya.com/', 'Cookie': cookie }
      });
      var hasRet = hasKey(profile, 'ret');
      var ret = hasRet ? num(profile, 'ret', -1) : -1;
      var ok = hasRet ? (ret === 200) : !!(profile && profile.data);
      if (ok) {
        result.ok = true;
        var rawExpire = str(profile, 'data.vipInfo.expireTime')
          || str(profile, 'data.vipInfo.expiredTime')
          || str(profile, 'data.vipInfo.endTime')
          || str(profile, 'data.vipExpireTime');
        result.vipExpireAt = formatExpire(rawExpire);
        result.vipFlag = str(profile, 'data.vipInfo.isVip')
          || str(profile, 'data.isVip')
          || str(profile, 'data.vipType');
        result.detail = hasRet ? ('校验通过 ret=' + ret) : '校验通过（无 ret，按 data 判定）';
      } else {
        result.detail = hasRet
          ? ('ret=' + ret + (str(profile, 'msg') ? ' msg=' + str(profile, 'msg') : ''))
          : '返回体缺少 ret 与 data';
      }
    } catch (e) {
      if (e && e.cancelled) throw e;
      var status = (e && typeof e.status === 'number') ? e.status : 0;
      // 429 / 5xx / 网络异常属于瞬态故障，仅做 45s 短退避且不写入 30 分钟负缓存
      result.transient = (status === 429 || status >= 500 || status === 0 || !(status >= 400 && status < 500));
      result.detail = '请求失败：' + msgOf(e);
    }

    try {
      host.writeCache(REMOTE_CHECK_CACHE_KEY, JSON.stringify({
        fp: fp,
        t: Date.now(),
        ok: result.ok,
        transient: result.transient,
        vipExpireAt: result.vipExpireAt,
        vipFlag: result.vipFlag,
        detail: result.detail
      }));
    } catch (e) { /* 缓存写入失败不影响本次判定 */ }
    return result;
  }

  // ---------------------------------------------------------------------------
  // 6. 解析主链路（v1.3）
  //    ① 付费优先：按 Cookie 候选逐个尝试，同一候选内仍按档位逐级回落
  //    ② 所有候选的付费链路都失败 → 免费接口兜底一次（C3）
  // ---------------------------------------------------------------------------

  function resolveByChain(host, trackId, quality, candidates, forDownload, isFreeChapter) {
    var ttl = Math.min(LINK_TTL_SEC > 0 ? LINK_TTL_SEC : 900, LINK_TTL_MAX_SEC);
    var expiresAt = nowSec() + ttl;
    var chain = qualityChain(quality.level);

    var state = { remoteState: 'unused' };
    var firstUsable = null;
    var paidTried = 0;          // 真正进入付费链路的候选数
    var localTried = 0;         // 其中本机凭据（user/pref）的数量
    var allNoPermission = true; // 是否每个尝试过的候选都是「无权限类」
    var anyApiFailed = false;
    var apiFailedInfo = null;
    var lastNoPermission = null;
    var freeTrackSeen = false;

    for (var c = 0; c < candidates.length; c++) {
      var planned = candidates[c];
      // C6：换源日志先出，随后才是该来源的校验/尝试（决策链顺序：失败归类 → 换源 → 校验 → 尝试）
      if (c > 0) host.log('换个凭据来源重试：' + planned.origin);
      var cand = loadCandidate(host, planned, state);
      if (!cand) {
        if (c > 0) host.log('凭据来源 ' + planned.origin + ' 不可用，继续下一个候选');
        continue;
      }
      if (!firstUsable) firstUsable = cand;

      host.log('尝试付费链路（凭据来源=' + cand.origin + '）');
      paidTried++;
      if (cand.origin !== 'remote') localTried++;

      var outcome = null;
      for (var i = 0; i < chain.length; i++) {
        outcome = paidAttempt(host, trackId, chain[i], cand, forDownload, expiresAt, quality, true);
        if (outcome.kind === 'ok') {
          if (i > 0) host.log('档位 level ' + chain[0] + '（' + levelInfo(chain[0]).canonical + '）不可用，已回落到 level '
            + chain[i] + '（' + levelInfo(chain[i]).canonical + '）');
          host.log('解析成功（来源=' + cand.origin + '，档位=' + quality.tierName + '，level ' + outcome.level + '）');
          outcome.result.hitCredential = {
            origin: cand.origin,
            fingerprint: cand.cookie ? cookieFingerprint(host, cand.cookie).slice(-8) : ''
          };
          return outcome.result;
        }
        if (outcome.kind === 'rate_limited') {
          host.log('付费接口触发限流（HTTP 429），立刻止损');
          throw parserError('rate_limited', '请求过于频繁，请稍后重试', 'rate_limited');
        }
        if (outcome.kind === 'no_permission') break;   // 无权限：换音质没用，换下一个候选
        if (outcome.kind === 'free_track') break;      // 曲目免费：直接转免费链路
        if (outcome.kind === 'network_error') break;   // 传输/网络故障：降档重试无意义，立刻止损
        // api_failed / empty：继续试下一个档位（逐级回落保持不变）
      }

      var kind = outcome ? outcome.kind : 'empty';
      if (kind === 'free_track') {
        freeTrackSeen = true;
        allNoPermission = false;
        host.log('付费接口 ret=130 → 该曲目免费，付费接口不适用 → 转入免费链路（不再换候选）');
        break;
      }
      if (kind !== 'no_permission') allNoPermission = false;
      if (kind === 'api_failed' || kind === 'network_error') { anyApiFailed = true; apiFailedInfo = outcome; }
      if (kind === 'no_permission') lastNoPermission = outcome;
      if (cand.origin === 'remote') state.remoteState = kind;
      if (kind === 'network_error') {
        host.log('付费接口传输/网络异常（' + ((outcome && outcome.detail) || '') + '），终止多候选与降档放大重试');
        break;
      }

      var detail = (outcome && outcome.detail) ? ('：' + outcome.detail) : '';
      var more = (c < candidates.length - 1) ? '，换下一个候选' : '';
      host.log('凭据来源 ' + cand.origin + ' 的付费链路失败（' + kind + detail + '）' + more);
    }

    // ② 免费兜底之前的硬性归因（v1.3.0 规格补充：这两类不再碰免费接口）
    //    · 没有任何候选真正进入付费链路 → no_cookie（凭据都没有，免费接口同样没意义）
    if (paidTried === 0) {
      if (isFreeChapter) {
        host.log('免费章节且无可用 Cookie，跳过付费链路直接尝试免费接口');
      } else {
        throw parserError('no_cookie',
          '未取到可用 Cookie'
            + (state.remoteState === 'invalid' ? '（共享凭据校验未通过，已跳过）' : '（共享凭据不可用）')
            + '，可在书源管理里登录喜马拉雅会员账号',
          'no_cookie');
      }
    }
    //    · 所有候选都无权限（726 / 1001 / 1002）→ 直接判 not_vip，不再尝试免费接口
    //      （权限受限的内容免费接口也不会给正片，多一次请求只会增加拿到试听/低码率片段的风险）
    if (paidTried > 0 && allNoPermission && !freeTrackSeen) {
      host.log('所有候选都无权限（' + ((lastNoPermission && lastNoPermission.detail) || '付费接口无权限')
        + '），不再尝试免费接口，直接判为「无权限」');
      throw parserError('not_vip', notVipMessage(state, lastNoPermission, localTried), 'no_permission');
    }

    // ③ C3：免费链路只在付费链路失败之后兜底执行一次（用第一个可用候选）
    if (freeTrackSeen) {
      host.log('顺序：付费接口(ret=130，已请求 ' + paidTried + ' 次) → 转入免费接口兜底');
    } else {
      host.log('付费链路全部失败，转入免费接口兜底');
    }
    var freeMsg = '';
    if (firstUsable || isFreeChapter) {
      try {
        var freeCookie = firstUsable ? firstUsable.cookie : '';
        var freeOrigin = firstUsable ? firstUsable.origin : 'anonymous';
        var free = resolveFree(host, trackId, quality, freeCookie, forDownload, expiresAt);
        if (free) {
          if (free.quality !== quality.canonical) {
            host.log('免费直链实际音质 ' + free.quality + '（所选档位 ' + quality.canonical
              + '；免费接口档位与付费接口不同，quality/actualQuality 已如实标注）');
          }
          host.log('解析成功（来源=' + freeOrigin + '，档位=' + quality.tierName + '，免费接口兜底）');
          free.hitCredential = {
            origin: freeOrigin,
            fingerprint: freeCookie ? cookieFingerprint(host, freeCookie).slice(-8) : ''
          };
          return free;
        }
      } catch (e) {
        if (e && e.cancelled) throw e;
        if (e && e.reason === 'trial_only') throw e;   // C4：试听内容立刻抛出，不回落任何链路
        if (e && e.reason === 'rate_limited') throw e; // AUD-45：免费接口 429 限流立刻透传
        freeMsg = msgOf(e);
        host.log('免费接口异常：' + freeMsg);
      }
    } else {
      host.log('没有可用凭据，跳过免费接口兜底');
    }

    // ④ 兜底也失败 → 归因（对外 reason 码与 v1.2 一致，新增的 trial_only 只在试听分支抛出）
    if (anyApiFailed) {
      throw parserError('paid_api_failed',
        (apiFailedInfo && apiFailedInfo.message) ? apiFailedInfo.message : '付费接口全部失败（api_failed）',
        'api_failed');
    }
    throw parserError('free_api_failed', freeMsg || '付费与免费接口都未返回可用直链', 'api_failed');
  }

  /** not_vip 文案：区分「本机未开通权益」与「共享凭据也不可用」 */
  function notVipMessage(state, last, localTried) {
    var detail = (last && last.detail) ? last.detail : '付费接口无权限';
    if (!localTried) {
      return '共享凭据无权限（' + detail + '）：该章节需要会员或购买';
    }
    if (!state || state.remoteState === 'unused') {
      return '本机未开通权益（' + detail + '）：该章节需要会员或购买';
    }
    var remoteNote;
    if (state.remoteState === 'invalid') remoteNote = '共享凭据也不可用（共享凭据校验未通过）';
    else if (state.remoteState === 'unavailable') remoteNote = '共享凭据也不可用（远端共享 Cookie 获取失败）';
    else remoteNote = '共享凭据也不可用（共享账号同样无权限）';
    return '本机未开通权益，且' + remoteNote + '：' + detail + '，该章节需要会员或购买';
  }

  // ---------------------------------------------------------------------------
  // 7. 付费接口：fileId(AES) + ep(base64/RC4) → /download/1.0.0/ 直链
  //    v1.3：返回结构化结果（C5 码表归类），只有「仅试听内容」时抛 trial_only（C4）
  //    v1.4：单次请求抽成 paidRequestOnce；成功响应解析实际生效档位（S3），
  //          请求档为超清且该曲目确有更高档时追加一次请求（S3.3，最多 +1 次）
  // ---------------------------------------------------------------------------

  /**
   * 单次付费接口请求（HTTP + 码表归类），不做档位处理
   * @returns {{ok:boolean, json:object, ret:number, cls:string, apiMsg:string, error:string}}
   */
  function paidRequestOnce(host, trackId, level, cand) {
    var url = PAY_API + '/' + trackId + '/ts-' + Date.now() + '?device=iPhone&trackQualityLevel=' + level;
    try {
      var json = parseJson(host.getString(url, { headers: apiHeaders(cand.cookie) }));
      var ret = num(json, 'ret', -1);
      return { ok: true, json: json, ret: ret, cls: retClass(ret), apiMsg: str(json, 'msg'), error: '' };
    } catch (e) {
      if (e && e.cancelled) throw e;
      var status = (e && typeof e.status === 'number') ? e.status : 0;
      var cls;
      if (status === 429) {
        cls = 'rate_limited';
      } else {
        var isTransportErr = !(status >= 400 && status < 500);
        cls = isTransportErr ? 'network_error' : 'api_failed';
      }
      return {
        ok: false, json: null, ret: -1, cls: cls, apiMsg: '',
        error: '付费接口请求失败：' + msgOf(e)
      };
    }
  }

  /**
   * 单次付费接口尝试（含 S3.3 超清加强）
   * @param  level        本次请求的服务端档位序号
   * @param  requested    用户请求档位（resolveQuality 结果；用于回传 requestedLevel / capped）
   * @param  allowEnhance 是否允许「检测到更高档」追加一次请求
   * @returns {{kind:'ok'|'no_permission'|'free_track'|'api_failed'|'empty', ...}}
   */
  function paidAttempt(host, trackId, level, cand, forDownload, expiresAt, requested, allowEnhance) {
    var info = levelInfo(level);
    host.log('付费接口请求：档位 level ' + level + '（' + info.tierName + ' · ' + info.canonical + '）');

    var r1 = paidRequestOnce(host, trackId, level, cand);
    var suffix = '（level ' + level + '）' + (r1.apiMsg ? '：' + r1.apiMsg : '');

    if (!r1.ok) {
      host.log(r1.error + '（level ' + level + '）');
      return { kind: r1.cls || 'api_failed', ret: -1, message: r1.error, detail: r1.error };
    }

    if (r1.cls === 'no_permission') {
      host.log('付费接口 ret=' + r1.ret + ' → 无权限' + suffix);
      return {
        kind: 'no_permission',
        ret: r1.ret,
        message: r1.apiMsg || ('付费接口 ret=' + r1.ret + ' 无权限'),
        detail: 'ret=' + r1.ret + ' 无权限' + (r1.apiMsg ? '（' + r1.apiMsg + '）' : '')
      };
    }

    if (r1.cls === 'free_track') {
      host.log('付费接口 ret=130 → 该曲目免费，付费接口不适用' + suffix);
      return { kind: 'free_track', ret: 130, message: r1.apiMsg || 'ret=130 该曲目免费', detail: 'ret=130 该曲目免费' };
    }

    if (r1.cls !== 'ok') {
      // 其它非 0 → api_failed（message 里带上 ret 与 msg）
      var apiFailedMsg = '付费接口 ret=' + r1.ret + ' msg=' + (r1.apiMsg || '（无）');
      host.log('付费接口 ret=' + r1.ret + ' → api_failed' + suffix);
      return { kind: 'api_failed', ret: r1.ret, message: apiFailedMsg, detail: apiFailedMsg };
    }

    rejectTrial(host, r1.json, 'paid');   // C4：仅试听内容不得返回
    var built = null;
    try {
      built = buildPaidResult(host, r1.json, cand, level, forDownload, expiresAt, requested);
    } catch (e) {
      if (e && e.cancelled) throw e;
      if (e && e.reason === 'trial_only') throw e;
      var buildMsg = '付费直链拼接失败：' + msgOf(e);
      host.log(buildMsg + suffix);
      return { kind: 'api_failed', ret: r1.ret, message: buildMsg, detail: buildMsg };
    }
    if (!built) {
      host.log('付费接口 ret=0 但未返回可用 fileId/ep' + suffix);
      return { kind: 'empty', ret: r1.ret, message: '付费接口 ret=0 但未返回可用 fileId/ep', detail: 'ret=0 未返回 fileId/ep' };
    }

    // S3.3 超清加强：请求档为超清（2）且该曲目确有更高档（highestQualityLevel ≥ 3）
    //        → 再按 highestQualityLevel 请求一次，返回更高档的结果；最多增加 1 次请求
    if (allowEnhance && requested && requested.level === LEVEL_UHD && level === LEVEL_UHD
      && built.maxLevel !== null && built.maxLevel >= 3
      && !isHigherFailCached(host, trackId)) {          // 跨调用记忆：该曲目更高档曾取不到 → 跳过重复探测
      var higher = built.maxLevel;
      host.log('检测到更高档 level ' + higher + '，已改用');
      var r2 = paidRequestOnce(host, trackId, higher, cand);
      var second = null;
      if (r2.ok && r2.cls === 'ok') {
        rejectTrial(host, r2.json, 'paid');
        try {
          second = buildPaidResult(host, r2.json, cand, higher, forDownload, expiresAt, requested);
        } catch (e2) {
          if (e2 && e2.cancelled) throw e2;
          if (e2 && e2.reason === 'trial_only') throw e2;
          second = null;
        }
      }
      if (second) {
        built = second;
      } else {
        if (r2.cls !== 'rate_limited' && r2.cls !== 'network_error') {
          markHigherFailCached(host, trackId);             // AUD-44：仅非瞬态失败时跨调用记住「更高档不可用」
        }
        host.log('更高档 level ' + higher + ' 未返回可用直链，保留 level ' + level + ' 的结果');
      }
    }

    return {
      kind: 'ok',
      result: built.result,
      level: built.actualLevel,
      requestedLevel: built.requestedLevel,
      capped: built.capped,
      maxLevel: built.maxLevel
    };
  }

  /**
   * 付费直链拼装（fileId → AES → ep → buy_key/sign/token/timestamp → /download/1.0.0/）
   * v1.4：解析实际生效档位并回传 S4 字段（requestedLevel / actualLevel / actualQuality /
   *       tierName / measuredKbps / capped / maxLevel），quality 改为实际档位规范码
   * @returns {{result:object, actualLevel:number, requestedLevel:number,
   *            capped:boolean, maxLevel:(number|null)}|null}
   */
  function buildPaidResult(host, json, cand, level, forDownload, expiresAt, requested) {
    var fileId = str(json, 'fileId');
    var ep = str(json, 'ep');
    if (!fileId && !ep) return null;

    var path = fileId ? decryptPath(host.aesEcbDecrypt(fileId, AES_KEY)) : '';
    if (!path) return null;

    var parts = epParse(ep);
    var buyKey = parts[0], sign = parts[1], token = parts[2], timestamp = parts[3];
    var domain = str(json, 'domain') || 'http://audio.xmcdn.com';
    // F1：服务端 duration 实测为「秒」，旧代码按毫秒 ÷1000 会失真约 1000 倍
    var duration = num(json, 'duration', 0);
    var durationSec = normalizeDurationSec(duration);
    var fileSize = num(json, 'totalLength', 0);

    var directURL = domain + '/download/1.0.0/' + path +
      '?buy_key=' + buyKey +
      '&sign=' + sign +
      '&timestamp=' + timestamp +
      '&token=' + token +
      '&duration=' + duration;

    // S3：实际生效档位 —— downloadQualityLevel 优先；缺失时用 highestQualityLevel 与请求档取小者；
    //     两者都缺失时按请求档（此时不判定降档）
    var maxLevel = numLevel(json, 'highestQualityLevel');
    var actualLevel = numLevel(json, 'downloadQualityLevel');
    if (actualLevel === null) {
      actualLevel = (maxLevel === null) ? level : Math.min(maxLevel, level);
    }
    var requestedLevel = requested ? requested.level : level;
    var capped = actualLevel < requestedLevel;
    var actualInfo = levelInfo(actualLevel);
    var measured = measuredKbpsOf(fileSize, durationSec);

    var hitInfo = levelInfo(level);               // F3：日志与回落标注复用同一次查表
    host.log('付费接口命中 level ' + level + '（' + hitInfo.canonical + '）→ ' + path);
    logTierOutcomePaid(host, requested || {
      raw: hitInfo.canonical, level: level, tierName: hitInfo.tierName
    }, actualLevel, measured, maxLevel);

    var result = {
      url: directURL,
      downloadUrl: directURL,
      headers: {
        'User-Agent': API_UA,
        'Cookie': cand.cookie
      },
      kind: 'onDemand',
      isPaid: true,
      // S4：quality 不再回传 highestQualityLevel 数字，改为实际档位规范码
      quality: actualInfo.canonical,
      requestedLevel: requestedLevel,
      actualLevel: actualLevel,
      actualQuality: actualInfo.canonical,
      tierName: actualInfo.tierName,
      measuredKbps: measured,
      capped: capped,
      expiresAt: expiresAt,
      fileSize: fileSize,
      durationSec: durationSec,
      title: str(json, 'title'),
      albumId: str(json, 'albumId'),
      note: forDownload ? 'paid-download' : 'paid-play'
    };
    if (maxLevel !== null) result.maxLevel = maxLevel;   // S4：没有则省略

    return {
      result: result,
      actualLevel: actualLevel,
      requestedLevel: requestedLevel,
      capped: capped,
      maxLevel: maxLevel
    };
  }

  /** AES 解密结果 → 直链路径（可能是纯字符串，也可能是 { path | data }） */
  function decryptPath(decrypted) {
    if (!decrypted) return '';
    var text = String(decrypted).replace(/\u0000+$/g, '');
    if (text.charAt(0) === '{') {
      try {
        var obj = JSON.parse(text);
        return String(obj.path || obj.data || '');
      } catch (e) { /* 落到下面按纯字符串处理 */ }
    }
    if (!looksLikeURLPath(text)) return '';
    return text;
  }

  // ---------------------------------------------------------------------------
  // 7.1 C4：试听识别（用户已确认不要试听内容）
  //   付费：isAuthorized === false 或 sampleDuration > 0（且 sampleLength > 0）
  //   免费：isAuthorized === false 或 sampleDuration > 0
  // ---------------------------------------------------------------------------

  /** 观测试听特征值（scope: 'paid' | 'free'） */
  function trialObservation(json, scope) {
    var sd = num(json, 'sampleDuration', 0);
    var sl = num(json, 'sampleLength', 0);
    var tl = num(json, 'totalLength', 0);
    var rawAuth = json ? json.isAuthorized : undefined;
    var authKnown = (rawAuth !== undefined && rawAuth !== null);
    var authFalse = authKnown && (rawAuth === false || String(rawAuth) === 'false');
    var slReported = hasKey(json, 'sampleLength');
    var trial;
    if (scope === 'paid') {
      // sampleLength 缺失时（字段都不给）按「有 sampleDuration 即试听」从严判定，绝不返回试听地址
      trial = authFalse || (sd > 0 && (sl > 0 || !slReported));
    } else {
      trial = authFalse || sd > 0;
    }
    return {
      trial: trial,
      isAuthorized: authKnown ? String(rawAuth) : '缺失',
      sampleDuration: sd,
      sampleLength: sl,
      totalLength: tl,
      summary: 'isAuthorized=' + (authKnown ? String(rawAuth) : '缺失') + ', sampleDuration=' + sd
    };
  }

  /** 命中试听 → 写日志并抛 trial_only（C4：绝不返回试听地址） */
  function rejectTrial(host, json, scope) {
    var obs = trialObservation(json, scope);
    if (!obs.trial) return;
    var who = (scope === 'paid') ? '付费接口' : '免费接口';
    host.log(who + '返回仅试听内容（' + obs.summary + '），已拒绝'
      + '（观测：sampleDuration=' + obs.sampleDuration
      + ', sampleLength=' + obs.sampleLength
      + ', totalLength=' + obs.totalLength + '）');
    throw parserError('trial_only', '该章节仅提供试听，需要会员或购买', 'trial_only');
  }

  // ---------------------------------------------------------------------------
  // 8. 免费接口：trackInfo 各档音质直链（按档取流逻辑保持，v1.4 只补 S4 字段与 S5 日志）
  //    原脚本的 URL 形如 .../ts-<epoch>&qualityLevel=N（qualityLevel 其实落在路径段里），
  //    本脚本先按原样请求，失败后改用标准 query 形式再试一次。
  // ---------------------------------------------------------------------------

  function resolveFree(host, trackId, quality, cookie, forDownload, expiresAt) {
    var prefKeys = FREE_PREFERENCE[quality.family] || FREE_PREFERENCE.hd;
    var ts = Date.now();
    var variants = [
      FREE_API + '/' + trackId + '/ts-' + ts + '?qualityLevel=' + quality.level,
      FREE_API + '/' + trackId + '/ts-' + ts + '&qualityLevel=' + quality.level
    ];
    var lastMsg = '';
    for (var i = 0; i < variants.length; i++) {
      var json = null;
      try {
        json = parseJson(host.getString(variants[i], { headers: apiHeaders(cookie) }));
      } catch (e) {
        if (e && e.cancelled) throw e;
        if (e && e.status === 429) {
          host.log('免费接口触发限流（HTTP 429），立刻止损');
          throw parserError('rate_limited', '请求过于频繁，请稍后重试', 'rate_limited');
        }
        // 传输 / 解析失败：换另一种 URL 形式再试一次
        lastMsg = msgOf(e);
        continue;
      }
      if (num(json, 'ret', -1) !== 0) {
        // 业务拒绝（付费章节、无试听等）：换 URL 形式也没用，直接结束免费链路（省一次请求）
        lastMsg = str(json, 'msg') || ('免费接口 ret=' + num(json, 'ret', -1));
        host.log('免费接口拒绝：' + lastMsg + '（qualityLevel=' + quality.level + '）');
        break;
      }

      var trackInfo = json.trackInfo;
      if (!trackInfo) {
        lastMsg = '免费接口未返回 trackInfo';
        continue;
      }

      // C4：免费响应里的试听片段同样拒绝（trackInfo 与顶层字段都看一眼）
      rejectTrial(host, trackInfo, 'free');
      rejectTrial(host, json, 'free');

      var picked = '';
      for (var k = 0; k < prefKeys.length; k++) {
        if (trackInfo[prefKeys[k]]) { picked = prefKeys[k]; break; }
      }
      if (!picked) {
        lastMsg = '免费接口无可用音质字段（按 ' + quality.family + ' 档优先：' + prefKeys.join('/') + '）';
        continue;
      }

      var playURL = String(trackInfo[picked]);
      if (playURL.indexOf('//') === 0) {
        playURL = 'https:' + playURL;                 // 协议相对地址
      } else if (playURL.charAt(0) === '/') {
        playURL = 'https://m.ximalaya.com' + playURL; // 站内相对地址
      } else {
        playURL = playURL.replace(/^http:/, 'https:');
      }

      var label = FREE_KEY_QUALITY[picked] || 'M4A_64';
      var freeFileSize = num(trackInfo, 'downloadSize', 0);
      var freeDurationSec = normalizeDurationSec(num(trackInfo, 'duration', 0));   // F1：同为「秒」口径
      var freeMeasured = measuredKbpsOf(freeFileSize, freeDurationSec);
      var freeLevel = (FREE_KEY_LEVEL[picked] === undefined) ? quality.level : FREE_KEY_LEVEL[picked];
      var freeInfo = levelInfo(freeLevel);

      host.log('免费接口命中 ' + picked + '（' + (FREE_KEY_LABEL[picked] || '未知字段') + '）→ quality=' + label
        + ' qualityLevel=' + quality.level);
      logTierOutcomeFree(host, quality, freeLevel, freeMeasured, picked, label);

      return {
        url: playURL,
        downloadUrl: playURL,
        headers: {
          'User-Agent': API_UA,
          'Cookie': cookie,
          'Referer': 'https://www.ximalaya.com/'
        },
        kind: 'onDemand',
        isPaid: false,
        // S4：免费链路同样回传实际档位与体积时长
        quality: label,
        actualQuality: label,
        qualityKey: picked,
        requestedLevel: quality.level,
        actualLevel: freeLevel,
        tierName: freeInfo.tierName,
        measuredKbps: freeMeasured,
        capped: freeLevel < quality.level,
        expiresAt: expiresAt,
        fileSize: freeFileSize,
        durationSec: freeDurationSec,
        title: str(trackInfo, 'title'),
        albumId: str(trackInfo, 'albumId'),
        note: forDownload ? 'free-download' : 'free-play'
      };
    }
    if (lastMsg) host.log('免费接口未取到直链：' + lastMsg);
    return null;
  }

  // ---------------------------------------------------------------------------
  // 9. 杂项
  // ---------------------------------------------------------------------------

  function formatExpire(raw) {
    if (!raw) return '';
    var trimmed = String(raw).trim();
    if (!/^\d+$/.test(trimmed)) return raw;
    var n = parseInt(trimmed, 10);
    if (isNaN(n) || n <= 0) return raw;
    var ms = n < 1e12 ? n * 1000 : n;
    var d = new Date(ms);
    if (isNaN(d.getTime())) return raw;
    function pad(v) { return (v < 10 ? '0' : '') + v; }
    var today = new Date();
    if (d.getTime() > today.getTime()) {
      return d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate());
    }
    return '已过期(' + d.getFullYear() + '-' + pad(d.getMonth() + 1) + '-' + pad(d.getDate()) + ')';
  }

  // isExpiredHint 保留给宿主回传的错误文案判断（当前未在链路里强制使用）
  void isExpiredHint;
}());
