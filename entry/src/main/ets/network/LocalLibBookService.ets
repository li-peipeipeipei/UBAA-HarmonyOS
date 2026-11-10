import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import {
  BykcLibBookLibrary,
  BykcLibBookStorey,
  BykcLibBookArea,
  BykcLibBookSeat,
  BykcLibBookBooking
} from '../model/ApiTypes';
import { UpstreamClient, resolveLocation } from './UpstreamClient';
import { LocalWebVpn } from './LocalWebVpn';
import { TokenStore } from './TokenStore';

/**
 * 图书馆座位（对齐原版 `LocalLibBookApi.kt`）。
 *
 * ## 上游是**另一套认证**（与 UBAA 主站的 SSO 不同）
 *
 * ```
 * 1. GET https://sso.buaa.edu.cn/login?service=<图书馆的 /v4/login/cas>
 *    → 跟随重定向，从 URL 的 ?cas= 参数里取 CAS token
 * 2. POST https://booking.lib.buaa.edu.cn/v4/login/user  { "cas": "<token>" }
 *    → data.member.token  ← 图书馆自己的 token
 * 3. 之后所有请求带 header: Authorization: bearer<token>
 * ```
 *
 * ## 预约请求体是 **AES-128-CBC 加密**的
 *
 * `POST /v4/space/confirm` 的 body 是 `{ "aesjson": "<Base64密文>" }`，
 * 密文 = AES-128-CBC-NoPadding(PKCS7填充(JSON)) ，key/iv 见 `LibBookCrypto`。
 * key = **日期数字 + 其反转**（如 `20261025` → `2026102552016202`），
 * iv = 固定 `ZZWBKJ_ZHIHUAWEI`。
 *
 * ## 数据形状
 *
 * 楼馆 → 楼层（嵌在楼馆的 `children` 里，**不需要单独请求**）→ 分区 → 座位，
 * 中间多一步「分区详情」一次性带回可预约日期与时段。
 */

/** 图书馆上游根地址。 */
const LIBBOOK_BASE_URL: string = 'https://booking.lib.buaa.edu.cn';
/** CAS 登录入口（service 指向图书馆自己的回调）。 */
const LIBBOOK_CAS_LOGIN_URL: string =
  'https://sso.buaa.edu.cn/login?service=https%3A%2F%2Fbooking.lib.buaa.edu.cn%2Fv4%2Flogin%2Fcas';
/** 预约体加密用的固定 IV。 */
const LIBBOOK_AES_IV: string = 'ZZWBKJ_ZHIHUAWEI';
/** 单条重定向链最大跳数。 */
const LIBBOOK_MAX_HOPS: number = 8;

/** 座位可预约的状态码（上游 `status == "1"`）。 */
export const LIBBOOK_SEAT_AVAILABLE: string = '1';
/** 预约记录不可取消的状态码（用户取消 / 已结束）。 */
export const LIBBOOK_BOOKING_UNCANCELLABLE: string[] = ['6', '8'];
/** 预约记录状态里含这些词就不可取消。 */
export const LIBBOOK_BOOKING_CANCEL_KEYWORDS: string[] =
  ['取消', '结束', '已完成', '过期', '失效'];

/** 今天的日期（`yyyy-MM-dd`）。 */
function todayText(): string {
  const d = new Date();
  const m = (d.getMonth() + 1).toString().padStart(2, '0');
  const day = d.getDate().toString().padStart(2, '0');
  return d.getFullYear().toString() + '-' + m + '-' + day;
}

/** 取字符串字段（不存在返回空串）。 */
function strOf(source: Object, key: string): string {
  const value = (source as Record<string, Object>)[key];
  return typeof value === 'string' ? value : '';
}

/** 取数字字段（不存在返回 0）。 */
function numOf(source: Object, key: string): number {
  const value = (source as Record<string, Object>)[key];
  if (typeof value === 'number') {
    return value;
  }
  if (typeof value === 'string') {
    const parsed = parseInt(value, 10);
    return isNaN(parsed) ? 0 : parsed;
  }
  return 0;
}

/** 取字符串字段（不存在返回 undefined）。 */
function optStrOf(source: Object, key: string): string | undefined {
  const value = (source as Record<string, Object>)[key];
  return typeof value === 'string' ? value : undefined;
}

/** 取数组字段（不存在返回空数组）。 */
function arrOf(source: Object, key: string): Object[] {
  const value = (source as Record<string, Object>)[key];
  return Array.isArray(value) ? (value as Object[]) : [];
}

/** 取对象字段（不存在返回 null）。 */
function objOf(source: Object, key: string): Object | null {
  const value = (source as Record<string, Object>)[key];
  return (value !== null && typeof value === 'object') ? (value as Object) : null;
}

/** 从对象里取第一个非空的字符串字段（上游字段名有双写兼容）。 */
function firstStr(source: Object, keys: string[]): string {
  for (let i = 0; i < keys.length; i++) {
    const v = strOf(source, keys[i]);
    if (v.length > 0) {
      return v;
    }
  }
  return '';
}

export class LocalLibBookService {
  /** 图书馆自己的 token（CAS 换来的）。 */
  private static token: string = '';
  /** 上一次请求的时间戳（token 过期时重登用）。 */
  private static lastRequestAt: number = 0;

  /* ----------------------------- 对外接口 ----------------------------- */

  /** 楼馆列表（含嵌套的楼层）。 */
  static async fetchLibraries(day: string): Promise<BykcLibBookLibrary[]> {
    const data = await LocalLibBookService.request('space/pcTopFor', { 'day': day });
    const list = arrOf(data, 'list');
    const out: BykcLibBookLibrary[] = [];
    for (let i = 0; i < list.length; i++) {
      const raw = list[i];
      const children = arrOf(raw, 'children');
      const storeys: BykcLibBookStorey[] = [];
      for (let j = 0; j < children.length; j++) {
        storeys.push({
          id: strOf(children[j], 'id'),
          name: strOf(children[j], 'name'),
          freeNum: numOf(children[j], 'free_num'),
          totalNum: numOf(children[j], 'total_num')
        });
      }
      out.push({
        id: strOf(raw, 'id'),
        name: strOf(raw, 'name'),
        freeNum: numOf(raw, 'free_num'),
        totalNum: numOf(raw, 'total_num'),
        storeys: storeys
      });
    }
    return out;
  }

  /** 分区列表（按楼馆 + 楼层 + 日期）。 */
  static async fetchAreas(premisesId: string, storeyId: string, day: string): Promise<BykcLibBookArea[]> {
    const body: LibBookRequestBody = {
      'premisesIds': premisesId,
      'categoryIds': [],
      'storeyIds': storeyId.length > 0 ? [storeyId] : [],
      'boutiqueIds': [],
      'date': day
    };
    const data = await LocalLibBookService.request('space/pick', body);
    const list = arrOf(data, 'area');
    const out: BykcLibBookArea[] = [];
    for (let i = 0; i < list.length; i++) {
      const raw = list[i];
      out.push({
        id: strOf(raw, 'id'),
        name: strOf(raw, 'name'),
        areaName: strOf(raw, 'area'),
        premisesId: firstStr(raw, ['premises_id', 'premisesId']),
        storeyId: firstStr(raw, ['storey_id', 'storeyId']),
        freeNum: numOf(raw, 'free_num'),
        totalNum: numOf(raw, 'total_num')
      });
    }
    return out;
  }

  /**
   * 分区详情 —— **一次性带回可预约日期与时段**。
   *
   * 上游结构是 `data.date.list[]`，每个元素有 `day` 与 `times[]`。
   * 原版只取 `list[0]` 的时段（日期取 list 里第一个 day）。
   */
  static async fetchAreaDetail(areaId: string): Promise<LibBookAreaDetail> {
    const data = await LocalLibBookService.request('Space/map', { 'id': areaId });
    const dateObj = objOf(data, 'date');
    const list = dateObj === null ? [] : arrOf(dateObj, 'list');
    const dates: string[] = [];
    let slots: LibBookSlot[] = [];
    for (let i = 0; i < list.length; i++) {
      const day = strOf(list[i], 'day');
      if (day.length === 0) {
        dates.push(strOf(list[i], 'date'));
      } else {
        dates.push(day);
      }
      if (i === 0) {
        const times = arrOf(list[i], 'times');
        for (let j = 0; j < times.length; j++) {
          const start = strOf(times[j], 'start');
          const end = strOf(times[j], 'end');
          slots.push({
            id: strOf(times[j], 'id'),
            start: start,
            end: end,
            label: start + '-' + end
          });
        }
      }
    }
    const detail: LibBookAreaDetail = { dates: dates, slots: slots };
    return detail;
  }

  /** 座位列表。 */
  static async fetchSeats(areaId: string, day: string, startTime: string, endTime: string):
    Promise<BykcLibBookSeat[]> {
    const body: LibBookRequestBody = {
      'id': areaId,
      'day': day,
      'label_id': [],
      'start_time': startTime,
      'end_time': endTime,
      'begdate': '',
      'enddate': ''
    };
    const data = await LocalLibBookService.request('Space/seat', body);
    const list = arrOf(data, 'list');
    const out: BykcLibBookSeat[] = [];
    for (let i = 0; i < list.length; i++) {
      const raw = list[i];
      const status = strOf(raw, 'status');
      out.push({
        id: strOf(raw, 'id'),
        name: strOf(raw, 'name'),
        no: strOf(raw, 'no'),
        status: status,
        statusName: strOf(raw, 'status_name'),
        isAvailable: status === LIBBOOK_SEAT_AVAILABLE
      });
    }
    return out;
  }

  /**
   * 提交预约（**写操作** —— 会真实占用座位）。
   *
   * body 是 `{ "aesjson": "<AES-CBC 密文>" }`。
   */
  static async reserve(areaId: string, seatId: string, day: string, slot: LibBookSlot): Promise<string> {
    const plain: LibBookReservePlain = {
      'seat_id': seatId,
      'segment': slot.id,
      'day': day,
      'start_time': '',
      'end_time': ''
    };
    const aesjson: string = await LocalLibBookService.encryptReserve(plain, day);
    const data = await LocalLibBookService.request('space/confirm', { 'aesjson': aesjson });
    const message = firstStr(data, ['message', 'msg']);
    return message.length > 0 ? message : '预约成功';
  }

  /** 我的预约记录。 */
  static async fetchBookings(page: number, limit: number): Promise<BykcLibBookBooking[]> {
    const data = await LocalLibBookService.request('member/seat', {
      'type': '1',
      'page': page,
      'limit': limit
    });
    const list = arrOf(data, 'list');
    if (list.length === 0) {
      // 上游可能把数组放在 data 本身
      const direct = (data as Record<string, Object>)['list'];
      if (Array.isArray(direct)) {
        return LocalLibBookService.parseBookings(direct as Object[]);
      }
      return [];
    }
    return LocalLibBookService.parseBookings(list);
  }

  private static parseBookings(list: Object[]): BykcLibBookBooking[] {
    const out: BykcLibBookBooking[] = [];
    for (let i = 0; i < list.length; i++) {
      const raw = list[i];
      out.push({
        id: strOf(raw, 'id'),
        nameMerge: firstStr(raw, ['nameMerge', 'name_merge']),
        areaName: firstStr(raw, ['name', 'area_name']),
        seatNo: firstStr(raw, ['no', 'seat_no']),
        day: firstStr(raw, ['day', 'date']),
        beginTime: firstStr(raw, ['beginTime', 'begin_time']),
        endTime: firstStr(raw, ['endTime', 'end_time']),
        status: strOf(raw, 'status'),
        statusName: strOf(raw, 'status_name')
      });
    }
    return out;
  }

  /** 取消预约（**写操作**）。 */
  static async cancelBooking(bookingId: string): Promise<string> {
    const data = await LocalLibBookService.request('space/cancel', { 'id': bookingId });
    const message = firstStr(data, ['message', 'msg']);
    return message.length > 0 ? message : '取消成功';
  }

  /** 今天的日期（`yyyy-MM-dd`）。 */
  static today(): string {
    return todayText();
  }

  /* --------------------------- 预约体加密 --------------------------- */

  /**
   * AES-128-CBC-NoPadding 加密预约体 → Base64。
   *
   * - key = 日期数字 + 其反转（16 字节）；
   * - iv = 固定 `ZZWBKJ_ZHIHUAWEI`（16 字节）；
   * - 填充 = PKCS7（补满到 16 的倍数，每字节填补的长度）。
   */
  static async encryptReserve(body: LibBookReservePlain, day: string): Promise<string> {
    const digits: string = day.replace(/[^0-9]/g, '');
    if (digits.length !== 8) {
      throw new Error('图书馆日期格式不正确：' + day);
    }
    const keyText: string = digits + digits.split('').reverse().join('');
    const plain: string = JSON.stringify(body);
    const plainBytes: Uint8Array = new Uint8Array(plain.length);
    for (let i = 0; i < plain.length; i++) {
      plainBytes[i] = plain.charCodeAt(i) & 0xff;
    }
    // PKCS7 填充
    const padLength: number = 16 - (plainBytes.length % 16);
    const padded: Uint8Array = new Uint8Array(plainBytes.length + padLength);
    padded.set(plainBytes, 0);
    for (let i = plainBytes.length; i < padded.length; i++) {
      padded[i] = padLength;
    }
    const cipher: Uint8Array = await LocalLibBookService.aesCbcEncrypt(padded, keyText, LIBBOOK_AES_IV);
    return LocalLibBookService.bytesToBase64(cipher);
  }

  /**
   * AES-128-CBC-NoPadding 加密。
   *
   * ⚠️ CryptoFramework 的 CBC 模式**必须显式给 IV**（不是零 IV）——
   * 上游的 Java 侧也是这么做的。
   */
  private static async aesCbcEncrypt(plain: Uint8Array, keyText: string, ivText: string): Promise<Uint8Array> {
    const cipher = cryptoFramework.createCipher('AES128|CBC|NoPadding');
    const keyGenerator = cryptoFramework.createSymKeyGenerator('AES128');
    const keyBlob: cryptoFramework.DataBlob = { data: LocalLibBookService.textToBytes(keyText) };
    const symKey = await keyGenerator.convertKey(keyBlob);
    const ivSpec: cryptoFramework.IvParamsSpec = {
      algName: 'IvParamsSpec',
      iv: { data: LocalLibBookService.textToBytes(ivText) }
    };
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, ivSpec);
    const output = await cipher.doFinal({ data: plain });
    return output.data;
  }

  private static textToBytes(text: string): Uint8Array {
    const out = new Uint8Array(text.length);
    for (let i = 0; i < text.length; i++) {
      out[i] = text.charCodeAt(i) & 0xff;
    }
    return out;
  }

  private static bytesToBase64(bytes: Uint8Array): string {
    // `new util.Base64Helper().encodeToStringSync()` 直接吃 Uint8Array
    return new util.Base64Helper().encodeToStringSync(bytes);
  }

  /* ------------------------------ 请求层 ------------------------------ */

  /**
   * 调 `/v4/<path>`，返回 `data` 节点。
   *
   * token 失效（上游 message 含「登录失效 / 请重新登录 / 未登录」）时
   * 自动重登一次再重试。
   */
  private static async request(path: string, body: LibBookRequestBody): Promise<Object> {
    await LocalLibBookService.ensureLogin(false);
    const raw: Object = await LocalLibBookService.postV4(path, body, true);
    if (LocalLibBookService.isLoginExpired(raw)) {
      LocalLibBookService.token = '';
      await LocalLibBookService.ensureLogin(true);
      return LocalLibBookService.postV4(path, body, true);
    }
    const code: number = numOf(raw, 'code');
    if (code !== 0 && code !== 1) {
      const message = firstStr(raw, ['message', 'msg']);
      throw new Error(message.length > 0 ? message : '图书馆接口请求失败');
    }
    const data = objOf(raw, 'data');
    return data === null ? raw : data;
  }

  /** 发一次 POST，解析出整个响应对象。 */
  private static async postV4(path: string, body: LibBookRequestBody, withAuth: boolean): Promise<Object> {
    const url = LIBBOOK_BASE_URL + '/v4/' + path;
    const headers: Record<string, string> = {
      'accept': 'application/json, text/plain, */*',
      'content-type': 'application/json',
      'x-requested-with': 'XMLHttpRequest',
      'referer': LIBBOOK_BASE_URL,
      'origin': LIBBOOK_BASE_URL
    };
    if (withAuth) {
      headers['authorization'] = 'bearer' + LocalLibBookService.token;
    }
    const response = await UpstreamClient.postJson(url, JSON.stringify(body), false, headers);
    if (response.status < 200 || response.status >= 300) {
      throw new Error('图书馆接口响应异常（HTTP ' + response.status.toString() + '）');
    }
    try {
      return JSON.parse(response.body) as Object;
    } catch (error) {
      throw new Error('图书馆接口返回了非 JSON 响应');
    }
  }

  /** 图书馆 token 是否失效。 */
  private static isLoginExpired(raw: Object): boolean {
    const message = firstStr(raw, ['message', 'msg']);
    return message.indexOf('登录失效') >= 0 || message.indexOf('请重新登录') >= 0 ||
      message.indexOf('未登录') >= 0;
  }

  /**
   * 拿 token：先 CAS 换 cas 参数，再调 `login/user` 换图书馆 token。
   */
  private static async ensureLogin(forceRefresh: boolean): Promise<void> {
    // 图书馆的 CAS 登录**依赖已有的 SSO 会话**（主站的登录态）——
    // 没有它，CAS 跳转会停在登录页，捞不到 cas 参数。
    if (!TokenStore.hasLocalSession()) {
      throw new Error('请先登录后再使用图书馆座位功能');
    }
    if (!forceRefresh && LocalLibBookService.token.length > 0) {
      return;
    }
    LocalLibBookService.token = '';
    const cas: string = await LocalLibBookService.fetchCasToken();
    const raw: Object = await LocalLibBookService.postV4('login/user', { 'cas': cas }, false);
    const data = objOf(raw, 'data');
    const member = data === null ? null : objOf(data, 'member');
    const token: string = member === null ? '' : strOf(member, 'token');
    if (token.length === 0) {
      throw new Error('图书馆登录成功但未返回 token');
    }
    LocalLibBookService.token = token;
    LocalLibBookService.lastRequestAt = Date.now();
  }

  /**
   * 走 CAS 登录链，从 URL 里捞 `cas` 参数。
   *
   * 上游 service 指向图书馆的 `/v4/login/cas`，SSO 登录成功后会带着
   * `?cas=xxx` 跳回去 —— 那个 cas 就是图书馆要的凭证。
   */
  private static async fetchCasToken(): Promise<string> {
    let currentUrl: string = LIBBOOK_CAS_LOGIN_URL;
    for (let hop = 0; hop < LIBBOOK_MAX_HOPS; hop++) {
      const response = await UpstreamClient.get(currentUrl, false, {
        'accept': 'application/json, text/plain, */*',
        'referer': LIBBOOK_BASE_URL,
        'origin': LIBBOOK_BASE_URL
      });
      const fromUrl: string = LocalLibBookService.extractCasToken(response.url);
      if (fromUrl.length > 0) {
        return fromUrl;
      }
      const fromLocation: string = LocalLibBookService.extractCasToken(response.location);
      if (fromLocation.length > 0) {
        return fromLocation;
      }
      if (response.location.length === 0) {
        break;
      }
      const resolved: string = resolveLocation(response.url, response.location);
      // WebVPN 模式下 Location 是网关地址 → 先解包再 HSTS 升级
      const unwrapped: string = await LocalWebVpn.fromWebVpnUrl(resolved);
      currentUrl = LocalWebVpn.secureCasTransportUrl(unwrapped);
    }
    throw new Error('未能获取图书馆 CAS 参数');
  }

  /** 从 URL 里提取 `cas` 参数（支持 `?cas=` 与 `&cas=`）。 */
  private static extractCasToken(url: string): string {
    if (url.length === 0) {
      return '';
    }
    const match = url.match(/[?&#]cas=([^&#]+)/);
    return match === null ? '' : match[1];
  }
}

/**
 * 上游请求体。
 *
 * ⚠️ ArkTS **不允许把对象字面量直接赋给 `Record<K,V>`**（`arkts-no-untyped-obj-literals`），
 * 所以请求体一律用**显式 interface**。
 */
export interface LibBookRequestBody {
  // 楼馆查询
  day?: string;
  // 分区查询
  premisesIds?: string;
  categoryIds?: string[];
  storeyIds?: string[];
  boutiqueIds?: string[];
  date?: string;
  // 分区详情
  id?: string;
  // 座位查询
  label_id?: string[];
  start_time?: string;
  end_time?: string;
  begdate?: string;
  enddate?: string;
  // 登录
  cas?: string;
  // 我的预约
  type?: string;
  page?: number;
  limit?: number;
  // 预约（加密体）
  aesjson?: string;
  /** 加密体内部字段（`aesjson` 明文 JSON 的结构）。 */
  seat_id?: string;
  segment?: string;
}

/** 预约请求的**明文**结构（加密前）。 */
export interface LibBookReservePlain {
  seat_id: string;
  segment: string;
  day: string;
  start_time: string;
  end_time: string;
}

/** 分区详情（含可预约日期与时段）。 */
export interface LibBookAreaDetail {
  /** 可预约日期列表。 */
  dates: string[];
  /** 时段列表（上游 `data.date.list[0].times`）。 */
  slots: LibBookSlot[];
}

/** 预约时段。 */
export interface LibBookSlot {
  id: string;
  start: string;
  end: string;
  label: string;
}
