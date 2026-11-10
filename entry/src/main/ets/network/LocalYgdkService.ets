import { util } from '@kit.ArkTS';
import { Logger } from '../common/Logger';
import { ApiError } from './ApiError';
import { resolveLocation, UpstreamClient, UpstreamResponse } from './UpstreamClient';
import {
  YgdkClockinInput,
  YgdkClockinResult,
  YgdkItem,
  YgdkOverview,
  YgdkRecord,
  YgdkRecordsData,
  YgdkSummary
} from '../model/ApiTypes';

/**
 * 阳光打卡（ygdk）本地上游取数。
 *
 * ## 会话：又是一套独立体系
 *
 * 先用已有 SSO 会话走一条 oauth 跳转链拿到 `code`，再用 code 换 ygdk 自己的
 * `uid` + `token`（内存态，进程重启即失效）：
 * ```
 *  GET  app.buaa.edu.cn/uc/api/oauth/index?redirect=…&appid=…   → 逐跳（≤10）
 *       ↑ code 可能出现在**每一跳的实际地址**或 Location 的查询串里，
 *         也可能藏在 `#/home?code=…` 这种 **hash 里的查询串**（要单独拆）
 *  GET  ygdk.buaa.edu.cn/api/Front/Clockin/User/campusAppLogin?code=<code>
 *       → { code:1, result:{ uid, token } }（token 是 URL 编码的，要解码）
 * ```
 *
 * ## 业务接口
 *
 * 一律 `POST ${API_BASE}<path>`、`application/x-www-form-urlencoded`，
 * 表单里**每个请求都要带 `uid` + `token`**。
 *
 * ## 信封
 *
 * `{ code, msg, result }`：`code === 1` 取 `result`；`code === -98` 是**会话失效**
 * （不是 401）—— 清掉 token 重登一次即可；其余按 `msg` 报错。
 */

/* ------------------------------ 上游地址 ------------------------------ */

const YGDK_FRONT_BASE: string = 'https://ygdk.buaa.edu.cn';
const API_BASE: string = YGDK_FRONT_BASE + '/api';
const APP_ID: string = '200230221144501510';
const YGDK_HOME: string = YGDK_FRONT_BASE + '/#/home';
const OAUTH_URL: string = 'https://app.buaa.edu.cn/uc/api/oauth/index?redirect=' +
  encodeURIComponent(YGDK_HOME) + '&appid=' + APP_ID + '&state=STATE&qrcode=1';

const PATH_CLASSIFY: string = '/Front/Clockin/Classify/getList';
const PATH_ITEM: string = '/Front/Clockin/Item/getList';
const PATH_COUNT: string = '/Front/Clockin/Clockin/getCount';
const PATH_TERM: string = '/Front/Clockin/Term/get';
const PATH_RECORDS: string = '/Front/Clockin/Clockin/getList';
const PATH_EXCHANGE: string = '/api/Front/Clockin/User/campusAppLogin';
/** 图片上传（multipart，字段 uid / token / file）。 */
const PATH_UPLOAD: string = '/Front/Upload/File/post';
/** 提交打卡（表单）。 */
const PATH_CLOCKIN: string = '/Front/Clockin/Clockin/clockin';

/**
 * 自动填写用的默认照片：**1×1 全透明 PNG**。
 *
 * 原版 UBAA 就是塞这张图 —— 上游没有图片字段会直接拒绝打卡，而用户真去拍一张又太麻烦，
 * 所以「自动填写」时用这张占位图。值是标准的 1×1 透明 PNG，不用改。
 */
const TRANSPARENT_PNG_BASE64: string =
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+lmCcAAAAASUVORK5CYII=';
/** 自动填写用的默认地点（与原版一致）。 */
const DEFAULT_PLACE: string = '操场';

/** oauth 跳转链最大跳数（原实现为 10）。 */
const MAX_OAUTH_HOPS: number = 10;
/** 解析出的上下文缓存时长（原实现为 60s）。 */
const CONTEXT_TTL_MILLIS: number = 60_000;

/* ------------------------------ 响应结构 ------------------------------ */

interface YgdkEnvelope {
  code?: number;
  msg?: string;
  result?: Object;
}

interface YgdkAuthData {
  uid: number;
  token: string;
}

interface YgdkClassifyRaw {
  classifyId: number;
  name: string;
  termNum?: number;
  monthNum?: number;
  weekNum?: number;
}

interface YgdkCountRaw {
  termCount?: number;
  termCountShow?: number;
  termGoodCount?: number;
  termGoodCountShow?: number;
  weekCount?: number;
  weekNum?: number;
  monthCount?: number;
  monthNum?: number;
  dayCount?: number;
  termNum?: number;
}

interface YgdkContext {
  classify: YgdkClassifyRaw;
  classifyId: number;
  classifyName: string;
  items: YgdkItem[];
  defaultItemId: number;
  defaultItemName: string;
  summary: YgdkSummary;
  expiresAt: number;
}

/* ------------------------------ 工具 ------------------------------ */

function pad2(value: number): string {
  return value < 10 ? '0' + value.toString() : value.toString();
}

/** 取 URL 的查询串（`?` 之后、`#` 之前）；hash 里的查询串单独处理。 */
function urlQuery(raw: string): string {
  const queryIndex: number = raw.indexOf('?');
  if (queryIndex < 0) {
    return '';
  }
  let rest: string = raw.substring(queryIndex + 1);
  const hashIndex: number = rest.indexOf('#');
  if (hashIndex >= 0) {
    rest = rest.substring(0, hashIndex);
  }
  return rest;
}

/** 取 hash 片段里的查询串（`#/home?code=xxx` 这种）。 */
function hashQuery(raw: string): string {
  const hashIndex: number = raw.indexOf('#');
  if (hashIndex < 0) {
    return '';
  }
  const fragment: string = raw.substring(hashIndex + 1);
  const queryIndex: number = fragment.indexOf('?');
  return queryIndex < 0 ? '' : fragment.substring(queryIndex + 1);
}

/** 从查询串里取一个参数。 */
function queryParam(query: string, name: string): string {
  const parts: string[] = query.split('&');
  for (let i = 0; i < parts.length; i++) {
    const eq: number = parts[i].indexOf('=');
    if (eq <= 0) {
      continue;
    }
    if (parts[i].substring(0, eq) === name) {
      const raw: string = parts[i].substring(eq + 1);
      try {
        return decodeURIComponent(raw);
      } catch (error) {
        return raw;
      }
    }
  }
  return '';
}

/** 从地址里捞 oauth code（普通查询串 + hash 里的查询串都要看）。 */
function extractCode(raw: string): string {
  const direct: string = queryParam(urlQuery(raw), 'code');
  if (direct.length > 0) {
    return direct;
  }
  return queryParam(hashQuery(raw), 'code');
}

/** epoch 秒 → `yyyy-MM-dd HH:mm`（设备在 Asia/Shanghai，直接用本地时间即可）。 */
function timestampText(seconds: number | undefined): string {
  if (seconds === undefined || seconds === null || seconds <= 0) {
    return '';
  }
  const date = new Date(seconds * 1000);
  return date.getFullYear() + '-' + pad2(date.getMonth() + 1) + '-' + pad2(date.getDate()) +
    ' ' + pad2(date.getHours()) + ':' + pad2(date.getMinutes());
}

function textOf(value: string | undefined): string {
  return value === undefined || value === null ? '' : value.trim();
}

/** 表单编码（`application/x-www-form-urlencoded`）。 */
function formEncode(params: Map<string, string>): string {
  const parts: string[] = [];
  const keys: string[] = Array.from(params.keys());
  for (let i = 0; i < keys.length; i++) {
    const key: string = keys[i];
    const value: string | undefined = params.get(key);
    parts.push(encodeURIComponent(key) + '=' + encodeURIComponent(value === undefined ? '' : value));
  }
  return parts.join('&');
}

/** `HH:mm`。 */
function hhmm(date: Date): string {
  return pad2(date.getHours()) + ':' + pad2(date.getMinutes());
}

/** `yyyy-MM-dd HH:mm`。 */
function dateTimeText(date: Date): string {
  return date.getFullYear() + '-' + pad2(date.getMonth() + 1) + '-' + pad2(date.getDate()) +
    ' ' + hhmm(date);
}

/** 解析 `yyyy-MM-dd HH:mm`（分钟后的部分忽略）。 */
function parseDateTime(text: string): Date {
  const normalized: string = text.trim().replace('T', ' ');
  const parts: string[] = normalized.split(' ');
  if (parts.length !== 2) {
    throw new ApiError(400, 'invalid_request', '时间格式错误，请使用 yyyy-MM-dd HH:mm');
  }
  const dateParts: string[] = parts[0].split('-');
  const timeParts: string[] = parts[1].split(':');
  if (dateParts.length !== 3 || timeParts.length < 2) {
    throw new ApiError(400, 'invalid_request', '时间格式错误，请使用 yyyy-MM-dd HH:mm');
  }
  const year: number = parseInt(dateParts[0], 10);
  const month: number = parseInt(dateParts[1], 10);
  const day: number = parseInt(dateParts[2], 10);
  const hour: number = parseInt(timeParts[0], 10);
  const minute: number = parseInt(timeParts[1], 10);
  if (isNaN(year) || isNaN(month) || isNaN(day) || isNaN(hour) || isNaN(minute)) {
    throw new ApiError(400, 'invalid_request', '时间格式错误，请使用 yyyy-MM-dd HH:mm');
  }
  return new Date(year, month - 1, day, hour, minute, 0, 0);
}

/** 拼接若干段字节。 */
function joinBytes(parts: Uint8Array[]): ArrayBuffer {
  let total: number = 0;
  for (let i = 0; i < parts.length; i++) {
    total += parts[i].length;
  }
  const merged = new Uint8Array(total);
  let offset: number = 0;
  for (let i = 0; i < parts.length; i++) {
    merged.set(parts[i], offset);
    offset += parts[i].length;
  }
  return merged.buffer;
}

/**
 * 手工拼一个 multipart/form-data 请求体。
 *
 * 格式就这么点东西：每个字段一段「`--boundary` + 头 + 空行 + 值 + CRLF」，
 * 文件段多两行 `filename` 与 `Content-Type`，最后一次 `--boundary--` 收尾。
 * 拼成 `ArrayBuffer` 交给 `UpstreamClient.postRaw`（见那边关于「为什么不用 RCP 的
 * MultipartForm」的说明）。
 */
function buildMultipart(
  boundary: string,
  textFields: Map<string, string>,
  fileField: string,
  fileName: string,
  mimeType: string,
  fileBytes: Uint8Array
): ArrayBuffer {
  const encoder = new util.TextEncoder();
  const crlf: string = '\r\n';
  const parts: Uint8Array[] = [];
  const keys: string[] = Array.from(textFields.keys());
  for (let i = 0; i < keys.length; i++) {
    const value: string | undefined = textFields.get(keys[i]);
    parts.push(encoder.encodeInto('--' + boundary + crlf +
      'Content-Disposition: form-data; name="' + keys[i] + '"' + crlf + crlf +
      (value === undefined ? '' : value) + crlf));
  }
  parts.push(encoder.encodeInto('--' + boundary + crlf +
    'Content-Disposition: form-data; name="' + fileField + '"; filename="' + fileName + '"' + crlf +
    'Content-Type: ' + mimeType + crlf + crlf));
  parts.push(fileBytes);
  parts.push(encoder.encodeInto(crlf + '--' + boundary + '--' + crlf));
  return joinBytes(parts);
}

/** 自动填写生成的时间段。 */
interface ClockinRange {
  startEpoch: number;
  endEpoch: number;
  /** `yyyy-MM-dd HH:mm`。 */
  startText: string;
  /** 上游要的 `form_time_fmt`：`<开始 yyyy-MM-dd HH:mm>-<结束 HH:mm>`。 */
  formText: string;
}

/* ------------------------------ 服务 ------------------------------ */

export class LocalYgdkService {
  private static auth: YgdkAuthData | null = null;
  private static context: YgdkContext | null = null;

  /** 概览：分类 / 运动项目 / 学期统计（学期、周、月、日次数与目标）+ 自动填写默认值。 */
  static async fetchOverview(): Promise<YgdkOverview> {
    const context: YgdkContext = await LocalYgdkService.resolveContext(false);
    return {
      classifyId: context.classifyId,
      classifyName: context.classifyName,
      items: context.items,
      summary: context.summary,
      defaultItemId: context.defaultItemId,
      defaultItemName: context.defaultItemName,
      defaultTimeText: LocalYgdkService.autoRangeText()
    };
  }

  /**
   * 「自动填写」会用的时间段文案（`yyyy-MM-dd HH:mm-HH:mm`），只用于界面提示。
   *
   * 与真正提交时用的是**同一个** `defaultRange()`，所以界面上看到的就是会提交上去的。
   */
  static autoRangeText(): string {
    return LocalYgdkService.defaultRange().formText;
  }

  /** 打卡记录（按上游顺序返回）。 */
  static async fetchRecords(page: number, size: number): Promise<YgdkRecordsData> {
    const context: YgdkContext = await LocalYgdkService.resolveContext(false);
    const params = new Map<string, string>();
    params.set('page', page.toString());
    params.set('limit', size.toString());
    params.set('classify_id', context.classifyId.toString());
    params.set('user_id', await LocalYgdkService.uid());

    const result = await LocalYgdkService.postForm(PATH_RECORDS, params);
    const list: YgdkRecord[] = [];
    const rawList = LocalYgdkService.arrayOf(result, 'list');
    for (let i = 0; i < rawList.length; i++) {
      const record = LocalYgdkService.toRecord(rawList[i]);
      if (record !== null) {
        list.push(record);
      }
    }
    Logger.info('阳光打卡记录第 ' + page + ' 页：' + list.length + ' 条');
    return { records: list, total: LocalYgdkService.intOf(result, 'total') };
  }

  /* ---------------------------- 提交打卡 ---------------------------- */

  /**
   * 提交打卡。**入参可以全空** —— 留空的字段走「自动填写」。
   *
   * ## 自动填写规则（照抄原版 UBAA，一条都不能省）
   *
   * | 字段 | 留空时 |
   * | --- | --- |
   * | 运动项目 | 名字含「跑」的；没有就取 `sort` 最小的 |
   * | 时间段 | 当前时间往前 1 小时（小时数 clamp 到 8~21）；**早于 9 点用前一天 20:00~21:00** |
   * | 地点 | 「操场」 |
   * | 照片 | 1×1 全透明 PNG —— **上游没有图片会直接拒绝打卡**，所以必须塞一张 |
   * | 分享到广场 | 不分享 |
   *
   * 流程：上传图片拿 `file_name` → 表单提交 `clockin`。表单里的 `uid`/`token` 由
   * `postForm` 自动补；`start_time`/`end_time` 是**东八区的 epoch 秒**
   * （设备时区就是 Asia/Shanghai，用本地时间换算即可）；`form_time_fmt` 是
   * `<开始 yyyy-MM-dd HH:mm>-<结束 HH:mm>` 这种带区间的文案，上游会原样展示。
   */
  static async submitClockin(input: YgdkClockinInput): Promise<YgdkClockinResult> {
    const context: YgdkContext = await LocalYgdkService.resolveContext(false);
    const item: YgdkItem = LocalYgdkService.pickItem(context.items, input.itemId);
    const range: ClockinRange = LocalYgdkService.resolveTimeRange(input.startTime, input.endTime);
    const auth: YgdkAuthData = await LocalYgdkService.ensureLogin();
    const fileName: string = await LocalYgdkService.uploadDefaultPhoto(auth);
    const placeText: string = input.place === undefined ? '' : input.place.trim();
    const place: string = placeText.length > 0 ? placeText : DEFAULT_PLACE;

    const params = new Map<string, string>();
    params.set('start_time', range.startEpoch.toString());
    params.set('end_time', range.endEpoch.toString());
    params.set('place_type', '1');
    params.set('place', place);
    params.set('isopen', input.share === true ? '1' : '0');
    params.set('form_time_fmt', range.formText);
    params.set('images', '["' + fileName + '"]');
    params.set('classify_id', context.classifyId.toString());
    params.set('item_id', item.itemId.toString());
    params.set('item_name', item.name);

    const result: Object = await LocalYgdkService.postForm(PATH_CLOCKIN, params);
    const termName: string = context.summary.termName === undefined ? '' : context.summary.termName;
    // 打卡后统计会变，把上下文缓存丢掉，下次进页面重新拉
    LocalYgdkService.context = null;
    Logger.info('阳光打卡提交成功：' + item.name + ' / ' + place + ' / ' + range.formText);
    return {
      recordId: LocalYgdkService.intOf(result, 'record_id'),
      summary: LocalYgdkService.mapSummary(context.classify, {
        termCount: LocalYgdkService.intOf(result, 'term_count'),
        termCountShow: LocalYgdkService.intOf(result, 'term_count_show'),
        termGoodCount: LocalYgdkService.intOf(result, 'term_good_count'),
        termGoodCountShow: LocalYgdkService.intOf(result, 'term_good_count_show'),
        weekCount: LocalYgdkService.intOf(result, 'week_count'),
        weekNum: LocalYgdkService.intOf(result, 'week_num'),
        monthCount: LocalYgdkService.intOf(result, 'month_count'),
        monthNum: LocalYgdkService.intOf(result, 'month_num'),
        dayCount: LocalYgdkService.intOf(result, 'day_count'),
        termNum: LocalYgdkService.intOf(result, 'term_num')
      }, termName)
    };
  }

  /** 挑运动项目：显式给了 id 就校验存在性，否则走自动。 */
  private static pickItem(items: YgdkItem[], itemId: number | undefined): YgdkItem {
    if (itemId !== undefined && itemId > 0) {
      for (let i = 0; i < items.length; i++) {
        if (items[i].itemId === itemId) {
          return items[i];
        }
      }
      throw new ApiError(400, 'invalid_request', '所选运动项目不存在');
    }
    return LocalYgdkService.pickDefaultItem(items);
  }

  /** 默认运动项目：名字含「跑」优先，其次 `sort` 最小（与原版一致）。 */
  private static pickDefaultItem(items: YgdkItem[]): YgdkItem {
    if (items.length === 0) {
      throw new ApiError(502, 'ygdk_error', '未获取到阳光打卡项目列表');
    }
    for (let i = 0; i < items.length; i++) {
      if (items[i].name.indexOf('跑') >= 0) {
        return items[i];
      }
    }
    let best: YgdkItem = items[0];
    for (let i = 1; i < items.length; i++) {
      const current: number = items[i].sort === undefined ?
        Number.MAX_SAFE_INTEGER : (items[i].sort as number);
      const bestSort: number = best.sort === undefined ?
        Number.MAX_SAFE_INTEGER : (best.sort as number);
      if (current < bestSort) {
        best = items[i];
      }
    }
    return best;
  }

  /** 时间段：全空 → 自动；只给一个 → 报错；给了就校验「同一天 + 结束晚于开始」。 */
  private static resolveTimeRange(startText: string | undefined,
    endText: string | undefined): ClockinRange {
    const startRaw: string = startText === undefined ? '' : startText.trim();
    const endRaw: string = endText === undefined ? '' : endText.trim();
    if ((startRaw.length === 0) !== (endRaw.length === 0)) {
      throw new ApiError(400, 'invalid_request', '开始时间和结束时间需要同时填写');
    }
    if (startRaw.length === 0) {
      return LocalYgdkService.defaultRange();
    }
    const start: Date = parseDateTime(startRaw);
    const end: Date = parseDateTime(endRaw);
    const sameDay: boolean = start.getFullYear() === end.getFullYear() &&
      start.getMonth() === end.getMonth() && start.getDate() === end.getDate();
    if (!sameDay) {
      throw new ApiError(400, 'invalid_request', '当前仅支持同一天内的一小时打卡');
    }
    if (end.getTime() <= start.getTime()) {
      throw new ApiError(400, 'invalid_request', '结束时间必须晚于开始时间');
    }
    return {
      startEpoch: Math.floor(start.getTime() / 1000),
      endEpoch: Math.floor(end.getTime() / 1000),
      startText: dateTimeText(start),
      formText: dateTimeText(start) + '-' + hhmm(end)
    };
  }

  /**
   * 自动生成的时间段：**当前整点往前 1 小时**，正好 1 小时。
   *
   * - 小时数先 clamp 到 8~21（上游认的是「早上 8 点到晚上 9 点」的活动时间）；
   * - **早于 9 点打卡时用前一天 20:00~21:00** —— 否则「现在 - 1 小时」会落到昨天，
   *   两个时间跨天，上游会直接拒。
   */
  private static defaultRange(): ClockinRange {
    const now = new Date();
    const usePreviousDay: boolean = now.getHours() < 9;
    const startHour: number = usePreviousDay ? 20 : Math.min(21, Math.max(8, now.getHours() - 1));
    const dayShift: number = usePreviousDay ? -1 : 0;
    const start = new Date(now.getFullYear(), now.getMonth(), now.getDate() + dayShift,
      startHour, 0, 0, 0);
    const end = new Date(start.getTime() + 3600 * 1000);
    return {
      startEpoch: Math.floor(start.getTime() / 1000),
      endEpoch: Math.floor(end.getTime() / 1000),
      startText: dateTimeText(start),
      formText: dateTimeText(start) + '-' + hhmm(end)
    };
  }

  /** 上传自动填写用的那张 1×1 透明 PNG，返回上游给的文件名。 */
  private static async uploadDefaultPhoto(auth: YgdkAuthData): Promise<string> {
    const bytes: Uint8Array = new util.Base64Helper().decodeSync(TRANSPARENT_PNG_BASE64);
    const boundary: string = '----UBAABoundary' + Date.now().toString();
    const fields = new Map<string, string>();
    fields.set('uid', auth.uid.toString());
    fields.set('token', auth.token);
    const body: ArrayBuffer = buildMultipart(boundary, fields, 'file', 'ygdk_auto.png',
      'image/png', bytes);
    const response: UpstreamResponse = await UpstreamClient.postRaw(
      // ⚠️ 必须用 `API_BASE`（含 `/api` 前缀），别写成 `YGDK_FRONT_BASE + PATH_*` ——
      // 那样会打到 `https://ygdk.buaa.edu.cn/Front/Upload/File/post`，上游直接 404
      // （其余接口都走 `API_BASE + path`，就这一处最容易漏）。
      API_BASE + PATH_UPLOAD,
      body,
      'multipart/form-data; boundary=' + boundary,
      false,
      { 'x-requested-with': 'XMLHttpRequest' });
    const payload: Object = LocalYgdkService.unwrap(response, '阳光打卡图片上传失败');
    const name: string = LocalYgdkService.stringOf(payload, 'file_name');
    if (name.length === 0) {
      throw new ApiError(502, 'ygdk_error', '阳光打卡图片上传失败：上游未返回文件名');
    }
    return name;
  }

  /* ---------------------------- 上下文 ---------------------------- */

  /**
   * 解析并缓存「分类 + 项目 + 统计」这一组上下文。
   *
   * 概览与记录列表都要它，分开拉会重复 4 次请求，所以进程内缓存 60 秒
   * （原实现同样是 60 秒 TTL）。
   */
  private static async resolveContext(force: boolean): Promise<YgdkContext> {
    const cached = LocalYgdkService.context;
    if (!force && cached !== null && cached.expiresAt > Date.now()) {
      return cached;
    }

    const classify: YgdkClassifyRaw = await LocalYgdkService.resolveClassify();
    const items: YgdkItem[] = await LocalYgdkService.fetchItems(classify.classifyId);
    const defaultItem: YgdkItem = LocalYgdkService.pickDefaultItem(items);
    const defaultItemId: number = defaultItem.itemId;
    const defaultItemName: string = defaultItem.name;

    // 统计与学期取不到也不影响主流程（原实现同样 runCatching 兜底）
    let count: YgdkCountRaw = {};
    try {
      count = await LocalYgdkService.fetchCount(classify.classifyId);
    } catch (error) {
      Logger.warn('阳光打卡统计获取失败：' + (error as Error).message);
    }
    let termName: string = '';
    try {
      termName = await LocalYgdkService.fetchTermName();
    } catch (error) {
      Logger.warn('阳光打卡学期获取失败：' + (error as Error).message);
    }

    const context: YgdkContext = {
      classify: classify,
      classifyId: classify.classifyId,
      classifyName: classify.name,
      items: items,
      defaultItemId: defaultItemId,
      defaultItemName: defaultItemName,
      summary: LocalYgdkService.mapSummary(classify, count, termName),
      expiresAt: Date.now() + CONTEXT_TTL_MILLIS
    };
    LocalYgdkService.context = context;
    return context;
  }

  /** 取「体育」分类（原实现：优先名字含「体育」，其次 classify_id=1，最后取第一个）。 */
  private static async resolveClassify(): Promise<YgdkClassifyRaw> {
    const result = await LocalYgdkService.postForm(PATH_CLASSIFY, new Map<string, string>());
    const list = LocalYgdkService.arrayOf(result, 'list');
    const parsed: YgdkClassifyRaw[] = [];
    for (let i = 0; i < list.length; i++) {
      const item = LocalYgdkService.toClassify(list[i]);
      if (item !== null) {
        parsed.push(item);
      }
    }
    if (parsed.length === 0) {
      throw new ApiError(502, 'ygdk_error', '未获取到阳光打卡分类');
    }
    for (let i = 0; i < parsed.length; i++) {
      if (parsed[i].name.indexOf('体育') >= 0) {
        return parsed[i];
      }
    }
    for (let i = 0; i < parsed.length; i++) {
      if (parsed[i].classifyId === 1) {
        return parsed[i];
      }
    }
    return parsed[0];
  }

  private static async fetchItems(classifyId: number): Promise<YgdkItem[]> {
    const params = new Map<string, string>();
    params.set('page', '1');
    params.set('limit', '1000');
    params.set('classify_id', classifyId.toString());
    const result = await LocalYgdkService.postForm(PATH_ITEM, params);
    const list = LocalYgdkService.arrayOf(result, 'list');
    const items: YgdkItem[] = [];
    for (let i = 0; i < list.length; i++) {
      const item = LocalYgdkService.toItem(list[i]);
      if (item !== null) {
        items.push(item);
      }
    }
    if (items.length === 0) {
      throw new ApiError(502, 'ygdk_error', '未获取到阳光打卡项目列表');
    }
    return items;
  }

  private static async fetchCount(classifyId: number): Promise<YgdkCountRaw> {
    const params = new Map<string, string>();
    params.set('classify_id', classifyId.toString());
    params.set('user_id', await LocalYgdkService.uid());
    const result = await LocalYgdkService.postForm(PATH_COUNT, params);
    return {
      termCount: LocalYgdkService.intOf(result, 'term_count'),
      termCountShow: LocalYgdkService.intOf(result, 'term_count_show'),
      termGoodCount: LocalYgdkService.intOf(result, 'term_good_count'),
      termGoodCountShow: LocalYgdkService.intOf(result, 'term_good_count_show'),
      weekCount: LocalYgdkService.intOf(result, 'week_count'),
      weekNum: LocalYgdkService.intOf(result, 'week_num'),
      monthCount: LocalYgdkService.intOf(result, 'month_count'),
      monthNum: LocalYgdkService.intOf(result, 'month_num'),
      dayCount: LocalYgdkService.intOf(result, 'day_count'),
      termNum: LocalYgdkService.intOf(result, 'term_num')
    };
  }

  private static async fetchTermName(): Promise<string> {
    const result = await LocalYgdkService.postForm(PATH_TERM, new Map<string, string>());
    return LocalYgdkService.stringOf(result, 'name');
  }

  /** 统计口径与原实现一致：优先「有效次数 show」，目标值优先接口给的、其次分类自带。 */
  private static mapSummary(
    classify: YgdkClassifyRaw,
    count: YgdkCountRaw,
    termName: string
  ): YgdkSummary {
    const termCount: number = LocalYgdkService.firstNumber([
      count.termGoodCountShow, count.termGoodCount, count.termCountShow, count.termCount
    ]);
    const termTarget: number = LocalYgdkService.firstNumber([count.termNum, classify.termNum]);
    const weekTarget: number = LocalYgdkService.firstNumber([count.weekNum, classify.weekNum]);
    const monthTarget: number = LocalYgdkService.firstNumber([count.monthNum, classify.monthNum]);
    return {
      termName: termName.length > 0 ? termName : undefined,
      termCount: termCount,
      termTarget: termTarget > 0 ? termTarget : undefined,
      weekCount: count.weekCount,
      weekTarget: weekTarget > 0 ? weekTarget : undefined,
      monthCount: count.monthCount,
      monthTarget: monthTarget > 0 ? monthTarget : undefined,
      dayCount: count.dayCount,
      goodCount: LocalYgdkService.firstNumber([count.termGoodCountShow, count.termGoodCount])
    };
  }

  private static firstNumber(values: (number | undefined)[]): number {
    for (let i = 0; i < values.length; i++) {
      const value = values[i];
      if (value !== undefined && value !== null) {
        return value;
      }
    }
    return 0;
  }

  /* ---------------------------- 会话 ---------------------------- */

  private static async uid(): Promise<string> {
    const auth: YgdkAuthData = await LocalYgdkService.ensureLogin();
    return auth.uid.toString();
  }

  private static async ensureLogin(force: boolean = false): Promise<YgdkAuthData> {
    const current = LocalYgdkService.auth;
    if (!force && current !== null) {
      return current;
    }
    const code: string = await LocalYgdkService.fetchOauthCode();
    const auth: YgdkAuthData = await LocalYgdkService.exchangeCode(code);
    LocalYgdkService.auth = auth;
    Logger.info('阳光打卡会话就绪（uid=' + auth.uid + '）');
    return auth;
  }

  /** 逐跳走 oauth 跳转链找 `code`（原实现同样遍历每跳的地址与 Location）。 */
  private static async fetchOauthCode(): Promise<string> {
    let current: string = OAUTH_URL;
    for (let hop = 0; hop < MAX_OAUTH_HOPS; hop++) {
      const response: UpstreamResponse = await UpstreamClient.get(current, false);
      const fromUrl: string = extractCode(response.url);
      if (fromUrl.length > 0) {
        return fromUrl;
      }
      if (response.location.length === 0) {
        break;
      }
      const next: string = resolveLocation(response.url, response.location);
      const fromLocation: string = extractCode(next);
      if (fromLocation.length > 0) {
        return fromLocation;
      }
      current = next;
    }
    throw new ApiError(401, 'ygdk_session_expired',
      '无法获取阳光打卡登录 code，请返回设置页重新登录后重试');
  }

  /** 用 code 换 uid + token。 */
  private static async exchangeCode(code: string): Promise<YgdkAuthData> {
    const url: string = YGDK_FRONT_BASE + PATH_EXCHANGE + '?code=' + encodeURIComponent(code);
    const response: UpstreamResponse = await UpstreamClient.get(url, false, {
      'x-requested-with': 'XMLHttpRequest'
    });
    const result = LocalYgdkService.unwrap(response, '阳光打卡登录失败');
    // 有的版本把 uid/token 放在 result.data 里
    const nested = LocalYgdkService.objectOf(result, 'data');
    const source: Object = nested === null ? result : nested;

    const uid: number = LocalYgdkService.intOf(source, 'uid');
    let token: string = LocalYgdkService.stringOf(source, 'token');
    if (uid <= 0) {
      throw new ApiError(401, 'ygdk_session_expired', '阳光打卡返回的 uid 缺失');
    }
    if (token.length === 0) {
      throw new ApiError(401, 'ygdk_session_expired', '阳光打卡返回的 token 缺失');
    }
    try {
      token = decodeURIComponent(token);
    } catch (error) {
      // token 未编码时 decode 可能抛错，保留原值
    }
    return { uid: uid, token: token };
  }

  /* ---------------------------- 请求 ---------------------------- */

  /**
   * 发一次业务请求（表单里自动补 uid + token）。
   *
   * `code === -98` 表示会话失效 —— 清掉 token 重登一次再试（原实现的
   * `withFreshClientRetry`）。
   */
  private static async postForm(
    path: string,
    params: Map<string, string>
  ): Promise<Object> {
    let attempt: number = 0;
    while (attempt < 2) {
      const auth: YgdkAuthData = await LocalYgdkService.ensureLogin(attempt > 0);
      const form = new Map<string, string>();
      const keys: string[] = Array.from(params.keys());
      for (let i = 0; i < keys.length; i++) {
        const value: string | undefined = params.get(keys[i]);
        form.set(keys[i], value === undefined ? '' : value);
      }
      form.set('uid', auth.uid.toString());
      form.set('token', auth.token);

      const response: UpstreamResponse = await UpstreamClient.postForm(
        API_BASE + path,
        formEncode(form),
        false,
        { 'x-requested-with': 'XMLHttpRequest' });

      const probe = LocalYgdkService.probe(response);
      if (probe.ok) {
        return probe.result as Object;
      }
      if (!probe.authExpired || attempt > 0) {
        throw new ApiError(502, 'ygdk_error', probe.message);
      }
      Logger.warn('阳光打卡会话已失效，重新换取后重试：' + probe.message);
      LocalYgdkService.auth = null;
      LocalYgdkService.context = null;
      attempt++;
    }
    throw new ApiError(502, 'ygdk_error', '阳光打卡请求失败');
  }

  private static probe(response: UpstreamResponse): YgdkProbe {
    if (!response.isOk()) {
      return { ok: false, authExpired: false, result: null, message: '上游返回 HTTP ' + response.status };
    }
    let envelope: YgdkEnvelope;
    try {
      envelope = JSON.parse(response.body) as YgdkEnvelope;
    } catch (error) {
      return { ok: false, authExpired: false, result: null, message: '阳光打卡返回无法解析' };
    }
    const code: number = envelope.code === undefined ? -1 : envelope.code;
    if (code === 1) {
      const result = envelope.result;
      if (result === undefined || result === null) {
        return { ok: false, authExpired: false, result: null, message: '阳光打卡没有返回内容' };
      }
      return { ok: true, authExpired: false, result: result, message: '' };
    }
    if (code === -98) {
      return { ok: false, authExpired: true, result: null, message: '登录状态已失效' };
    }
    const message: string = envelope.msg === undefined || envelope.msg.length === 0 ?
      '阳光打卡请求失败' : envelope.msg;
    return { ok: false, authExpired: false, result: null, message: message };
  }

  private static unwrap(response: UpstreamResponse, what: string): Object {
    const probe = LocalYgdkService.probe(response);
    if (!probe.ok || probe.result === null) {
      throw new ApiError(502, 'ygdk_error', what + '：' + probe.message);
    }
    return probe.result;
  }

  /* ---------------------------- JSON 取值 ---------------------------- */

  private static objectOf(source: Object, key: string): Object | null {
    const value = (source as Record<string, Object>)[key];
    if (value === undefined || value === null || typeof value !== 'object') {
      return null;
    }
    if (Array.isArray(value)) {
      return null;
    }
    return value;
  }

  private static arrayOf(source: Object, key: string): Object[] {
    const value = (source as Record<string, Object>)[key];
    if (value === undefined || value === null || !Array.isArray(value)) {
      return [];
    }
    return value as Object[];
  }

  private static intOf(source: Object, key: string): number {
    const value = (source as Record<string, Object>)[key];
    if (typeof value === 'number') {
      return value as number;
    }
    if (typeof value === 'string') {
      const parsed = parseInt(value as string, 10);
      return isNaN(parsed) ? 0 : parsed;
    }
    return 0;
  }

  private static stringOf(source: Object, key: string): string {
    const value = (source as Record<string, Object>)[key];
    if (typeof value === 'string') {
      return (value as string).trim();
    }
    if (typeof value === 'number') {
      return (value as number).toString();
    }
    return '';
  }

  private static boolOf(source: Object, key: string): boolean {
    const value = (source as Record<string, Object>)[key];
    if (typeof value === 'boolean') {
      return value as boolean;
    }
    if (typeof value === 'number') {
      return (value as number) === 1;
    }
    return false;
  }

  private static toClassify(source: Object): YgdkClassifyRaw | null {
    const classifyId: number = LocalYgdkService.intOf(source, 'classify_id');
    const name: string = LocalYgdkService.stringOf(source, 'name');
    if (classifyId <= 0 || name.length === 0) {
      return null;
    }
    const termNum: number = LocalYgdkService.intOf(source, 'term_num');
    const monthNum: number = LocalYgdkService.intOf(source, 'month_num');
    const weekNum: number = LocalYgdkService.intOf(source, 'week_num');
    return {
      classifyId: classifyId,
      name: name,
      termNum: termNum > 0 ? termNum : undefined,
      monthNum: monthNum > 0 ? monthNum : undefined,
      weekNum: weekNum > 0 ? weekNum : undefined
    };
  }

  private static toItem(source: Object): YgdkItem | null {
    const itemId: number = LocalYgdkService.intOf(source, 'item_id');
    const name: string = LocalYgdkService.stringOf(source, 'name');
    if (itemId <= 0 || name.length === 0) {
      return null;
    }
    const type: number = LocalYgdkService.intOf(source, 'type');
    const sort: number = LocalYgdkService.intOf(source, 'sort');
    return {
      itemId: itemId,
      name: name,
      type: type > 0 ? type : undefined,
      sort: sort > 0 ? sort : undefined
    };
  }

  private static toRecord(source: Object): YgdkRecord | null {
    const recordId: number = LocalYgdkService.intOf(source, 'record_id');
    if (recordId <= 0) {
      return null;
    }
    const itemId: number = LocalYgdkService.intOf(source, 'item_id');
    const state: number = LocalYgdkService.intOf(source, 'state');
    const place: string = LocalYgdkService.stringOf(source, 'place');
    const itemName: string = LocalYgdkService.stringOf(source, 'item_name');
    const createdAt: string = LocalYgdkService.stringOf(source, 'create_time_fmt');
    return {
      recordId: recordId,
      itemId: itemId > 0 ? itemId : undefined,
      itemName: itemName.length > 0 ? itemName : undefined,
      startTime: timestampText(LocalYgdkService.intOf(source, 'start_time')),
      endTime: timestampText(LocalYgdkService.intOf(source, 'end_time')),
      place: place.length > 0 ? place : undefined,
      isOpen: LocalYgdkService.intOf(source, 'isopen') === 1,
      state: state,
      createdAtLabel: createdAt.length > 0 ? createdAt : undefined
    };
  }
}

/** 信封探测结果。 */
interface YgdkProbe {
  ok: boolean;
  /** `code === -98`：会话失效，值得重登一次再试。 */
  authExpired: boolean;
  result: Object | null;
  message: string;
}
