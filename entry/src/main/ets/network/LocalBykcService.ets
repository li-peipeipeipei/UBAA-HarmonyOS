import { util } from '@kit.ArkTS';
import { Logger } from '../common/Logger';
import { ApiError } from './ApiError';
import { BykcCrypto, BykcEncryptedRequest } from '../common/BykcCrypto';
import { LocalWebVpn } from './LocalWebVpn';
import { resolveLocation, UpstreamClient, UpstreamResponse } from './UpstreamClient';
import { TokenStore } from './TokenStore';
import {
  BykcCategoryStat,
  BykcChosenCourse,
  BykcCourse,
  BykcCourseDetail,
  BykcCoursesData,
  BykcStatistics
} from '../model/ApiTypes';

/**
 * 博雅课程（bykc）本地上游取数。
 *
 * ## 一、这是一套「加密网关」
 *
 * 所有业务都打到 `POST https://bykc.buaa.edu.cn/sscv/{apiName}`，报文加密（见 `BykcCrypto`）：
 * 请求体是 Base64(AES(明文))，头上带 `ak` / `sk` / `ts`，响应体同样要解密。
 * 会话靠一个 `auth_token`，从 `/sscv/cas/login` 的**跳转链**里捞（见 `ensureLogin`）。
 *
 * ## 二、状态是本地的
 *
 * 上游不给「可选 / 已选 / 人数已满」这类状态，得自己按报名与上课时间算（`resolveStatus`），
 * 规则与原版一致；列表默认把「已过期 / 选课结束」的课过滤掉。
 *
 * ## 三、写操作
 *
 * 选课 / 退选 / 签到都在下面（`chooseCourse` / `dropChosenCourse` / `signCourse`），
 * 参数与原版一致；界面上都走**二次确认**再发。签到坐标不用真定位，在签到点半径内随机生成。
 */
const BYKC_BASE: string = 'https://bykc.buaa.edu.cn';
/** 登录入口（走 SSO 跳转链，token 在跳转地址里）。 */
const PATH_CAS_LOGIN: string = '/sscv/cas/login';
/** 兜底入口（原版在第一个入口拿不到 token 时会再打一次它）。 */
const PATH_CAS_LOGIN_FALLBACK: string = '/cas-login?token=';
/** 业务接口前缀。 */
const PATH_API_PREFIX: string = '/sscv/';
/** 上游要求带上这两个头（照抄原版）。 */
const REFERER_URL: string = BYKC_BASE + '/system/course-select';
const ORIGIN_URL: string = BYKC_BASE;
/** 登录跳转链最大跳数。 */
const MAX_LOGIN_HOPS: number = 10;

/* ------------------------------ 取数辅助 ------------------------------ */

function objectOf(source: Object, key: string): Object | null {
  const value = (source as Record<string, Object>)[key];
  if (value === undefined || value === null || typeof value !== 'object' || Array.isArray(value)) {
    return null;
  }
  return value;
}

function arrayOf(source: Object, key: string): Object[] {
  const value = (source as Record<string, Object>)[key];
  return value === undefined || value === null || !Array.isArray(value) ? [] : (value as Object[]);
}

function stringOf(source: Object, key: string): string {
  const value = (source as Record<string, Object>)[key];
  if (typeof value === 'string') {
    return (value as string).trim();
  }
  if (typeof value === 'number') {
    return (value as number).toString();
  }
  return '';
}

function optionalString(source: Object, key: string): string | undefined {
  const text = stringOf(source, key);
  return text.length > 0 ? text : undefined;
}

function intOf(source: Object, key: string): number {
  const value = (source as Record<string, Object>)[key];
  if (typeof value === 'number') {
    return Math.floor(value as number);
  }
  if (typeof value === 'string') {
    const parsed = parseInt(value as string, 10);
    return isNaN(parsed) ? 0 : parsed;
  }
  return 0;
}

function optionalInt(source: Object, key: string): number | undefined {
  const value = (source as Record<string, Object>)[key];
  if (typeof value === 'number') {
    return Math.floor(value as number);
  }
  if (typeof value === 'string') {
    const parsed = parseInt(value as string, 10);
    return isNaN(parsed) ? undefined : parsed;
  }
  return undefined;
}

function boolOf(source: Object, key: string): boolean {
  const value = (source as Record<string, Object>)[key];
  if (typeof value === 'boolean') {
    return value as boolean;
  }
  if (typeof value === 'number') {
    return (value as number) === 1;
  }
  return false;
}

function stringList(source: Object, key: string): string[] {
  const list = arrayOf(source, key);
  const result: string[] = [];
  for (let i = 0; i < list.length; i++) {
    const text = typeof list[i] === 'string' ? (list[i] as string).trim() : '';
    if (text.length > 0 && result.indexOf(text) < 0) {
      result.push(text);
    }
  }
  return result;
}

/** 时间串统一成 `yyyy-MM-dd HH:mm`（上游格式不固定，认不出就原样返回）。 */
function dateTimeText(raw: string | undefined): string | undefined {
  if (raw === undefined || raw.length === 0) {
    return undefined;
  }
  const normalized = raw.replace('T', ' ');
  return normalized.length >= 16 ? normalized.substring(0, 16) : normalized;
}

/** 解析上游时间串（`yyyy-MM-dd[ HH:mm[:ss]]`）；认不出返回 null。 */
function parseDate(raw: string | undefined): Date | null {
  if (raw === undefined || raw.length === 0) {
    return null;
  }
  const normalized = raw.replace('T', ' ').trim();
  const parts = normalized.split(' ');
  const dateParts = parts[0].split('-');
  if (dateParts.length !== 3) {
    return null;
  }
  const year = parseInt(dateParts[0], 10);
  const month = parseInt(dateParts[1], 10);
  const day = parseInt(dateParts[2], 10);
  if (isNaN(year) || isNaN(month) || isNaN(day)) {
    return null;
  }
  let hour = 0;
  let minute = 0;
  let second = 0;
  if (parts.length > 1) {
    const timeParts = parts[1].split(':');
    hour = timeParts.length > 0 ? parseInt(timeParts[0], 10) : 0;
    minute = timeParts.length > 1 ? parseInt(timeParts[1], 10) : 0;
    second = timeParts.length > 2 ? parseInt(timeParts[2], 10) : 0;
    if (isNaN(hour) || isNaN(minute) || isNaN(second)) {
      hour = 0;
      minute = 0;
      second = 0;
    }
  }
  return new Date(year, month - 1, day, hour, minute, second, 0);
}

function within(start: Date | null, end: Date | null, now: Date): boolean {
  if (start === null || end === null) {
    return false;
  }
  return now.getTime() >= start.getTime() && now.getTime() <= end.getTime();
}

/** 去掉上游富文本的标签（课程简介是 HTML）。 */
function stripHtml(raw: string): string {
  if (raw.length === 0) {
    return '';
  }
  return raw.replace(/<[^>]*>/g, ' ')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/\s+/g, ' ')
    .trim();
}

/** 统计键形如 `大类|小类`，取竖线后面那段（没有竖线就用原值）。 */
function afterPipe(key: string): string {
  const index = key.indexOf('|');
  return index >= 0 ? key.substring(index + 1) : key;
}

/* ------------------------------ 信封结构 ------------------------------ */

interface BykcEnvelope {
  status?: string;
  data?: Object;
  errmsg?: string;
  msg?: string;
}

/** 详情里用得到的签到配置（上游把它塞在一个 JSON 字符串里）。 */
interface BykcSignConfig {
  signStart: Date | null;
  signEnd: Date | null;
  signOutStart: Date | null;
  signOutEnd: Date | null;
  hasPoints: boolean;
}

interface BykcSemester {
  startDate: string;
  endDate: string;
}

/**
 * 各接口的请求体。
 *
 * ⚠️ 必须写成**显式声明的接口**再 `JSON.stringify` —— ArkTS 不允许把对象字面量直接赋给
 * `Record<string, string>` 这类映射类型（`arkts-no-untyped-obj-literals`）。
 */
interface BykcPageRequest {
  pageNumber: number;
  pageSize: number;
}

interface BykcIdRequest {
  id: number;
}

interface BykcChosenRequest {
  startDate: string;
  endDate: string;
}

interface BykcCourseIdRequest {
  courseId: number;
}

interface BykcSignRequest {
  courseId: number;
  signLat: number;
  signLng: number;
  signType: number;
}

/** 签到点（经纬度 + 允许的半径，米）。 */
interface BykcSignPoint {
  lat: number;
  lng: number;
  radius: number;
}

function numberOf(source: Object, key: string): number {
  const value = (source as Record<string, Object>)[key];
  if (typeof value === 'number') {
    return value as number;
  }
  if (typeof value === 'string') {
    const parsed = parseFloat(value as string);
    return isNaN(parsed) ? 0 : parsed;
  }
  return 0;
}

export class LocalBykcService {
  /** 会话 token（内存态，进程重启即失效）。 */
  private static token: string | null = null;

  /* ---------------------------- 对外接口 ---------------------------- */

  /**
   * 课程列表。
   *
   * @param all 是否包含「已过期 / 选课结束」的课（默认过滤掉，与原版一致）。
   */
  static async fetchCourses(page: number, size: number,
    all: boolean = false): Promise<BykcCoursesData> {
    const request: BykcPageRequest = { pageNumber: page, pageSize: size };
    const data = await LocalBykcService.callApi('queryStudentSemesterCourseByPage', JSON.stringify(request));
    const now = new Date();
    const courses: BykcCourse[] = [];
    const list = arrayOf(data, 'content');
    for (let i = 0; i < list.length; i++) {
      const course = LocalBykcService.toCourse(list[i], now);
      // 已过期 / 选课结束的课默认不展示（要看得翻「全部」）
      const hidden = course.statusText === '已过期' || course.statusText === '选课结束';
      if (all || !hidden) {
        courses.push(course);
      }
    }
    const total = intOf(data, 'totalElements');
    Logger.info('博雅课程第 ' + page + ' 页：' + courses.length + ' 门（共 ' + total + '）');
    return {
      courses: courses,
      total: total,
      totalPages: intOf(data, 'totalPages'),
      page: page,
      pageSize: size
    };
  }

  /** 课程详情（含联系方式、简介、已选时的考勤）。 */
  static async fetchCourseDetail(courseId: number): Promise<BykcCourseDetail> {
    const request: BykcIdRequest = { id: courseId };
    const data = await LocalBykcService.callApi('queryCourseById', JSON.stringify(request));
    const now = new Date();
    const course = LocalBykcService.toCourse(data, now);
    const sign = LocalBykcService.parseSignConfig(stringOf(data, 'courseSignConfig'));

    let checkin: number | undefined = undefined;
    let pass: number | undefined = undefined;
    if (course.selected) {
      const chosen = await LocalBykcService.findChosen(courseId);
      if (chosen !== null) {
        checkin = chosen.checkin;
        pass = chosen.pass;
      }
    }
    const availability = LocalBykcService.resolveAvailability(sign, checkin, pass, now);
    const audiences: string[] = [];
    LocalBykcService.appendList(audiences, stringList(data, 'courseCampusList'));
    LocalBykcService.appendList(audiences, stringList(data, 'courseCollegeList'));
    LocalBykcService.appendList(audiences, stringList(data, 'courseTermList'));
    LocalBykcService.appendList(audiences, stringList(data, 'courseGroupList'));

    const college = objectOf(data, 'courseBelongCollege');
    const description = stripHtml(stringOf(data, 'courseDesc'));
    return {
      course: course,
      description: description.length > 0 ? description : undefined,
      contact: optionalString(data, 'courseContact'),
      contactMobile: optionalString(data, 'courseContactMobile'),
      organizer: college === null ? undefined : optionalString(college, 'collegeName'),
      audiences: audiences.length > 0 ? audiences.join('、') : undefined,
      checkin: checkin,
      pass: pass,
      canSign: availability.canSign,
      canSignOut: availability.canSignOut,
      signWindow: LocalBykcService.signWindowText(sign)
    };
  }

  /** 已选课程（按当前学期的窗口查）。 */
  static async fetchChosenCourses(): Promise<BykcChosenCourse[]> {
    const semester = await LocalBykcService.resolveSemester();
    const request: BykcChosenRequest = {
      startDate: semester.startDate,
      endDate: semester.endDate
    };
    const data = await LocalBykcService.callApi('queryChosenCourse', JSON.stringify(request));
    const now = new Date();
    const list = arrayOf(data, 'courseList');
    const result: BykcChosenCourse[] = [];
    for (let i = 0; i < list.length; i++) {
      const raw = list[i];
      const info = objectOf(raw, 'courseInfo');
      const sign = info === null ?
        null : LocalBykcService.parseSignConfig(stringOf(info, 'courseSignConfig'));
      const checkin = intOf(raw, 'checkin');
      const pass = optionalInt(raw, 'pass');
      const availability = LocalBykcService.resolveAvailability(sign, checkin, pass, now);
      const kind1 = info === null ? null : objectOf(info, 'courseNewKind1');
      const kind2 = info === null ? null : objectOf(info, 'courseNewKind2');
      result.push({
        chosenId: intOf(raw, 'id'),
        courseId: info === null ? 0 : intOf(info, 'id'),
        courseName: info === null ? '未知课程' : stringOf(info, 'courseName'),
        teacher: info === null ? undefined : optionalString(info, 'courseTeacher'),
        position: info === null ? undefined : optionalString(info, 'coursePosition'),
        category: kind1 === null ? undefined : optionalString(kind1, 'kindName'),
        subCategory: kind2 === null ? undefined : optionalString(kind2, 'kindName'),
        startDate: info === null ? undefined : dateTimeText(optionalString(info, 'courseStartDate')),
        endDate: info === null ? undefined : dateTimeText(optionalString(info, 'courseEndDate')),
        selectDate: dateTimeText(optionalString(raw, 'selectDate')),
        cancelEndDate: info === null ? undefined :
          dateTimeText(optionalString(info, 'courseCancelEndDate')),
        checkin: checkin,
        score: optionalInt(raw, 'score'),
        pass: pass,
        canSign: availability.canSign,
        canSignOut: availability.canSignOut,
        homework: optionalString(raw, 'homework')
      });
    }
    return result;
  }

  /** 分类统计（大类 / 小类 + 应修 / 已通过）。 */
  static async fetchStatistics(): Promise<BykcStatistics> {
    const data = await LocalBykcService.callApi('queryStatisticByUserId', '{}');
    const statistical = objectOf(data, 'statistical');
    const categories: BykcCategoryStat[] = [];
    if (statistical !== null) {
      const categoryKeys: string[] = Object.keys(statistical as Record<string, Object>);
      for (let i = 0; i < categoryKeys.length; i++) {
        const subMap = objectOf(statistical, categoryKeys[i]);
        if (subMap === null) {
          continue;
        }
        const subKeys: string[] = Object.keys(subMap as Record<string, Object>);
        for (let j = 0; j < subKeys.length; j++) {
          const entry = objectOf(subMap, subKeys[j]);
          if (entry === null) {
            continue;
          }
          categories.push({
            categoryName: afterPipe(categoryKeys[i]),
            subCategoryName: afterPipe(subKeys[j]),
            required: intOf(entry, 'assessmentCount'),
            passed: intOf(entry, 'completeAssessmentCount')
          });
        }
      }
    }
    return { validCount: intOf(data, 'validCount'), categories: categories };
  }

  /* ---------------------------- 写操作 ---------------------------- */

  /**
   * 选课。
   *
   * 上游的成功判定就是信封 `status === "0"`（`callApi` 已经统一处理），
   * 失败时的 `errmsg` 形如「重复报名」「人数已满」「不可选择」，直接透传给用户。
   */
  static async chooseCourse(courseId: number): Promise<string> {
    const request: BykcCourseIdRequest = { courseId: courseId };
    await LocalBykcService.callApi('choseCourse', JSON.stringify(request));
    Logger.info('博雅选课成功：' + courseId);
    return '选课成功';
  }

  /**
   * 退选。
   *
   * ⚠️ 请求体是 **`{ id: courseId }`** —— `delChosenCourse` 的 `id` 字段里放的是**课程 id**，
   * 不是选课记录 id。（原版 `deselectCourse(courseId)` 就是原样把课程 id 传进去的；
   * 我曾按「选课记录 id」传，上游找不到对应报名记录，一直退选失败。）
   */
  static async dropCourse(courseId: number): Promise<string> {
    const request: BykcIdRequest = { id: courseId };
    await LocalBykcService.callApi('delChosenCourse', JSON.stringify(request));
    Logger.info('博雅退选成功：courseId=' + courseId);
    return '退选成功';
  }

  /**
   * 签到（`signType = 1`）/ 签退（`signType = 2`）。
   *
   * 坐标**不用真定位**：取课程签到点，在它的半径内随机生成一个点即可 ——
   * 服务端只校验「是否落在某个签到点的半径内」，原版就是这么做的。
   */
  static async signCourse(courseId: number, signType: number): Promise<string> {
    const point: BykcSignPoint = await LocalBykcService.randomSignPoint(courseId);
    const request: BykcSignRequest = {
      courseId: courseId,
      signLat: point.lat,
      signLng: point.lng,
      signType: signType
    };
    await LocalBykcService.callApi('signCourseByUser', JSON.stringify(request));
    Logger.info('博雅' + (signType === 1 ? '签到' : '签退') + '成功：' + courseId);
    return signType === 1 ? '签到成功' : '签退成功';
  }

  /** 取该课程的一个签到点，并在半径内随机出一个坐标。 */
  private static async randomSignPoint(courseId: number): Promise<BykcSignPoint> {
    const request: BykcIdRequest = { id: courseId };
    const data = await LocalBykcService.callApi('queryCourseById', JSON.stringify(request));
    const points: BykcSignPoint[] = LocalBykcService.signPointsOf(data);
    if (points.length === 0) {
      throw new ApiError(400, 'bykc_no_sign_point', '该课程没有签到点，无法签到');
    }
    const point: BykcSignPoint = points[Math.floor(Math.random() * points.length)];
    if (point.radius <= 0) {
      return point;
    }
    // 半径内随机取点：距离用 sqrt(u)*R（保证面积均匀），角度均匀随机
    const distance: number = point.radius * Math.sqrt(Math.random());
    const angle: number = Math.random() * Math.PI * 2;
    return LocalBykcService.destination(point.lat, point.lng, distance, angle);
  }

  /** 解析课程配置里的签到点列表。 */
  private static signPointsOf(raw: Object): BykcSignPoint[] {
    const text: string = stringOf(raw, 'courseSignConfig');
    if (text.length === 0) {
      return [];
    }
    let parsed: Object;
    try {
      parsed = JSON.parse(text) as Object;
    } catch (error) {
      return [];
    }
    const list = arrayOf(parsed, 'signPointList');
    const points: BykcSignPoint[] = [];
    for (let i = 0; i < list.length; i++) {
      const lat: number = numberOf(list[i], 'lat');
      const lng: number = numberOf(list[i], 'lng');
      if (lat !== 0 || lng !== 0) {
        points.push({ lat: lat, lng: lng, radius: numberOf(list[i], 'radius') });
      }
    }
    return points;
  }

  /** 已知起点 + 距离 + 方位角 → 终点坐标（球面公式，与原版一致）。 */
  private static destination(lat: number, lng: number, distance: number,
    angle: number): BykcSignPoint {
    const earthRadius: number = 6371000;
    const angular: number = distance / earthRadius;
    const latRad: number = lat * Math.PI / 180;
    const lngRad: number = lng * Math.PI / 180;
    const destLat: number = Math.asin(Math.sin(latRad) * Math.cos(angular) +
      Math.cos(latRad) * Math.sin(angular) * Math.cos(angle));
    const destLng: number = lngRad + Math.atan2(
      Math.sin(angle) * Math.sin(angular) * Math.cos(latRad),
      Math.cos(angular) - Math.sin(latRad) * Math.sin(destLat));
    return {
      lat: destLat * 180 / Math.PI,
      lng: destLng * 180 / Math.PI,
      radius: 0
    };
  }

  /* ---------------------------- 会话 ---------------------------- */

  /**
   * 取（或复用）会话 token。
   *
   * 逐跳走 `/sscv/cas/login` 的跳转链：token 可能出现在**每一跳的实际地址**或 `Location` 里；
   * 一条都没捞到就再打一次 `/cas-login?token=`（原版的兜底），仍拿不到就按未登录报错。
   */
  private static async ensureLogin(force: boolean = false): Promise<string> {
    const current = LocalBykcService.token;
    if (!force && current !== null) {
      return current;
    }
    let token = await LocalBykcService.walkForToken(BYKC_BASE + PATH_CAS_LOGIN);
    if (token.length === 0) {
      token = await LocalBykcService.walkForToken(BYKC_BASE + PATH_CAS_LOGIN_FALLBACK);
    }
    if (token.length === 0) {
      throw new ApiError(401, 'bykc_session_expired', '博雅课程登录失败，请重新登录 UBAA 后再试');
    }
    LocalBykcService.token = token;
    Logger.info('博雅课程会话就绪');
    return token;
  }

  private static async walkForToken(startUrl: string): Promise<string> {
    let current: string = startUrl;
    for (let hop = 0; hop < MAX_LOGIN_HOPS; hop++) {
      const response: UpstreamResponse = await UpstreamClient.get(current, false);
      const fromUrl: string = LocalBykcService.extractToken(response.url);
      if (fromUrl.length > 0) {
        return fromUrl;
      }
      if (response.location.length === 0) {
        break;
      }
      const next: string = resolveLocation(response.url, response.location);
      const fromLocation: string = LocalBykcService.extractToken(next);
      if (fromLocation.length > 0) {
        return fromLocation;
      }
      current = next;
    }
    return '';
  }

  private static extractToken(url: string): string {
    if (url.length === 0) {
      return '';
    }
    const marker: number = url.indexOf('token=');
    if (marker < 0) {
      return '';
    }
    let value: string = url.substring(marker + 6);
    const ampersand: number = value.indexOf('&');
    if (ampersand >= 0) {
      value = value.substring(0, ampersand);
    }
    const hash: number = value.indexOf('#');
    if (hash >= 0) {
      value = value.substring(0, hash);
    }
    try {
      return decodeURIComponent(value).trim();
    } catch (error) {
      return value.trim();
    }
  }

  /* ---------------------------- 请求 ---------------------------- */

  /**
   * 发一次业务请求。
   *
   * 返回**已解密的 `data`**；`status !== "0"` 时按 `errmsg` 报错。
   * 会话失效（401 / 跳到 SSO / 密文里写着「会话已失效」）时丢 token 重登一次再试。
   */
  private static async callApi(apiName: string, paramsJson: string): Promise<Object> {
    let attempt: number = 0;
    while (attempt < 2) {
      const token: string = await LocalBykcService.ensureLogin(attempt > 0);
      const encrypted: BykcEncryptedRequest = await BykcCrypto.encryptRequest(paramsJson);
      const mode = TokenStore.getConnectionMode();
      const headers: Record<string, string> = {};
      headers['accept'] = 'application/json';
      headers['referer'] = await LocalWebVpn.rewrite(REFERER_URL, mode);
      headers['origin'] = await LocalWebVpn.rewrite(ORIGIN_URL, mode);
      headers['auth_token'] = token;
      headers['authtoken'] = token;
      headers['ak'] = encrypted.ak;
      headers['sk'] = encrypted.sk;
      headers['ts'] = encrypted.ts;

      const response: UpstreamResponse = await UpstreamClient.postJson(
        BYKC_BASE + PATH_API_PREFIX + apiName,
        encrypted.encryptedData,
        false,
        headers);

      if (response.status === 401 || response.status === 403) {
        LocalBykcService.token = null;
        attempt++;
        continue;
      }
      if (!response.isOk()) {
        throw new ApiError(502, 'bykc_error', '博雅课程服务返回 HTTP ' + response.status);
      }

      const decoded: string = await LocalBykcService.decodeBody(response.body, encrypted.aesKey);
      if (decoded.indexOf('会话已失效') >= 0 || decoded.indexOf('未登录') >= 0) {
        LocalBykcService.token = null;
        attempt++;
        continue;
      }
      let envelope: BykcEnvelope;
      try {
        envelope = JSON.parse(decoded) as BykcEnvelope;
      } catch (error) {
        throw new ApiError(502, 'bykc_error', '博雅课程返回无法解析');
      }
      const status: string = envelope.status === undefined ? '' : envelope.status;
      if (status !== '0') {
        const message: string = envelope.errmsg === undefined || envelope.errmsg.length === 0 ?
          '博雅课程请求失败' : envelope.errmsg;
        throw new ApiError(502, 'bykc_error', message);
      }
      const data = envelope.data;
      if (data === undefined || data === null) {
        throw new ApiError(502, 'bykc_error', '博雅课程没有返回内容');
      }
      return data as Object;
    }
    throw new ApiError(401, 'bykc_session_expired', '博雅课程会话已失效，请重新登录 UBAA 后再试');
  }

  /**
   * 解出明文 JSON。
   *
   * 上游的响应体有两种形态：**裸 Base64 字符串**、或**被 JSON 引号包起来的字符串**
   * （原版也是先尝试按 JSON 字符串解、失败再用原文）。
   */
  private static async decodeBody(body: string, aesKey: Uint8Array): Promise<string> {
    const trimmed: string = body.trim();
    if (trimmed.length === 0) {
      throw new ApiError(502, 'bykc_error', '博雅课程返回为空');
    }
    // 掉登录页（SSO）时会直接返回 HTML
    if (trimmed.startsWith('<')) {
      LocalBykcService.token = null;
      throw new ApiError(401, 'bykc_session_expired', '博雅课程会话已失效，请重新登录 UBAA 后再试');
    }
    let payload: string = trimmed;
    if (trimmed.startsWith('"')) {
      try {
        payload = JSON.parse(trimmed) as string;
      } catch (error) {
        payload = trimmed;
      }
    }
    const plain: string = await BykcCrypto.decryptResponse(payload, aesKey);
    return plain;
  }

  /* ---------------------------- 映射 ---------------------------- */

  private static toCourse(raw: Object, now: Date): BykcCourse {
    const selected: boolean = boolOf(raw, 'selected');
    const kind1 = objectOf(raw, 'courseNewKind1');
    const kind2 = objectOf(raw, 'courseNewKind2');
    const campuses = stringList(raw, 'courseCampusList');
    const rawCampus: string = stringOf(raw, 'courseCampus');
    if (campuses.length === 0 && rawCampus === 'ALL') {
      campuses.push('未指定校区');
    }
    const sign = LocalBykcService.parseSignConfig(stringOf(raw, 'courseSignConfig'));
    const status: string = LocalBykcService.resolveStatus(raw, selected, now);
    return {
      id: intOf(raw, 'id'),
      courseName: stringOf(raw, 'courseName'),
      teacher: optionalString(raw, 'courseTeacher'),
      position: optionalString(raw, 'coursePosition'),
      startDate: dateTimeText(optionalString(raw, 'courseStartDate')),
      endDate: dateTimeText(optionalString(raw, 'courseEndDate')),
      selectStartDate: dateTimeText(optionalString(raw, 'courseSelectStartDate')),
      selectEndDate: dateTimeText(optionalString(raw, 'courseSelectEndDate')),
      cancelEndDate: dateTimeText(optionalString(raw, 'courseCancelEndDate')),
      maxCount: intOf(raw, 'courseMaxCount'),
      currentCount: optionalInt(raw, 'courseCurrentCount'),
      category: kind1 === null ? undefined : optionalString(kind1, 'kindName'),
      subCategory: kind2 === null ? undefined : optionalString(kind2, 'kindName'),
      campuses: campuses,
      statusText: LocalBykcService.statusTextOf(status),
      status: status,
      selected: selected,
      hasSignPoints: sign !== null && sign.hasPoints
    };
  }

  /**
   * 课程状态（上游不给，本地按报名 / 上课时间算）。
   *
   * 判定顺序与原版一致：**先看上课时间是否已过 → 再看是否已选 → 报名是否结束 →
   * 名额是否已满 → 是否还没开始报名 → 否则可选**。
   *
   * 返回的是**枚举名**（`EXPIRED` / `SELECTED` / `ENDED` / `FULL` / `PREVIEW` / `AVAILABLE`），
   * 展示文案由 `statusTextOf` 转换 —— 筛选逻辑按枚举走，显示按中文。
   */
  private static resolveStatus(raw: Object, selected: boolean, now: Date): string {
    const courseStart = parseDate(optionalString(raw, 'courseStartDate'));
    if (courseStart !== null && now.getTime() > courseStart.getTime()) {
      return 'EXPIRED';
    }
    if (selected) {
      return 'SELECTED';
    }
    const selectEnd = parseDate(optionalString(raw, 'courseSelectEndDate'));
    if (selectEnd !== null && now.getTime() > selectEnd.getTime()) {
      return 'ENDED';
    }
    const currentCount = optionalInt(raw, 'courseCurrentCount');
    const maxCount = intOf(raw, 'courseMaxCount');
    if (currentCount !== undefined && maxCount > 0 && currentCount >= maxCount) {
      return 'FULL';
    }
    const selectStart = parseDate(optionalString(raw, 'courseSelectStartDate'));
    if (selectStart !== null && now.getTime() < selectStart.getTime()) {
      return 'PREVIEW';
    }
    return 'AVAILABLE';
  }

  /** 状态枚举名 → 展示文案（与原版的 `BykcCourseStatus.displayName` 一致）。 */
  private static statusTextOf(status: string): string {
    if (status === 'EXPIRED') {
      return '已过期';
    }
    if (status === 'SELECTED') {
      return '已选';
    }
    if (status === 'ENDED') {
      return '选课结束';
    }
    if (status === 'FULL') {
      return '人数已满';
    }
    if (status === 'PREVIEW') {
      return '预告';
    }
    return '可选';
  }

  /** 解析上游塞在字符串里的签到配置。 */
  private static parseSignConfig(raw: string): BykcSignConfig | null {
    if (raw.length === 0) {
      return null;
    }
    let parsed: Object;
    try {
      parsed = JSON.parse(raw) as Object;
    } catch (error) {
      return null;
    }
    return {
      signStart: parseDate(optionalString(parsed, 'signStartDate')),
      signEnd: parseDate(optionalString(parsed, 'signEndDate')),
      signOutStart: parseDate(optionalString(parsed, 'signOutStartDate')),
      signOutEnd: parseDate(optionalString(parsed, 'signOutEndDate')),
      hasPoints: arrayOf(parsed, 'signPointList').length > 0
    };
  }

  /**
   * 能不能签到 / 签退（与原版同一套判定）。
   *
   * - 签到：考核未通过 + 还没签过（`checkin` 为空或 0）+ 在签到时间窗内；
   * - 签退：考核未通过 + 还没签过或状态是 5 / 6 + 在签退时间窗内。
   */
  private static resolveAvailability(sign: BykcSignConfig | null, checkin: number | undefined,
    pass: number | undefined, now: Date): BykcAvailability {
    const unsigned: boolean = checkin === undefined || checkin === 0;
    const notPassed: boolean = pass !== 1;
    const canSign: boolean = notPassed && unsigned &&
      (sign !== null && within(sign.signStart, sign.signEnd, now));
    const canSignOut: boolean = notPassed && (unsigned || checkin === 5 || checkin === 6) &&
      (sign !== null && within(sign.signOutStart, sign.signOutEnd, now));
    return { canSign: canSign, canSignOut: canSignOut };
  }

  private static signWindowText(sign: BykcSignConfig | null): string | undefined {
    if (sign === null || sign.signStart === null || sign.signEnd === null) {
      return undefined;
    }
    return LocalBykcService.shortText(sign.signStart) + ' ~ ' + LocalBykcService.shortText(sign.signEnd);
  }

  private static shortText(date: Date): string {
    const pad = (value: number): string => value < 10 ? '0' + value.toString() : value.toString();
    return pad(date.getMonth() + 1) + '-' + pad(date.getDate()) + ' ' +
      pad(date.getHours()) + ':' + pad(date.getMinutes());
  }

  private static appendList(target: string[], source: string[]): void {
    for (let i = 0; i < source.length; i++) {
      if (target.indexOf(source[i]) < 0) {
        target.push(source[i]);
      }
    }
  }

  /** 查已选列表里对应这门课的记录（详情页要它的签到 / 考核）。 */
  private static async findChosen(courseId: number): Promise<BykcChosenCourse | null> {
    const list: BykcChosenCourse[] = await LocalBykcService.fetchChosenCourses();
    for (let i = 0; i < list.length; i++) {
      if (list[i].courseId === courseId) {
        return list[i];
      }
    }
    return null;
  }

  /**
   * 当前学期（查已选课程要按学期窗口过滤）。
   *
   * 取 `getAllConfig` 的学期表：优先「时间窗包含现在」的那个，否则取结束时间最晚的一个。
   */
  private static async resolveSemester(): Promise<BykcSemester> {
    const data = await LocalBykcService.callApi('getAllConfig', '{}');
    const semesters = arrayOf(data, 'semester');
    const now = new Date();
    let latest: BykcSemester | null = null;
    let latestEnd: number = 0;
    for (let i = 0; i < semesters.length; i++) {
      const startDate: string = stringOf(semesters[i], 'semesterStartDate');
      const endDate: string = stringOf(semesters[i], 'semesterEndDate');
      if (startDate.length === 0 || endDate.length === 0) {
        continue;
      }
      if (within(parseDate(startDate), parseDate(endDate), now)) {
        return { startDate: startDate, endDate: endDate };
      }
      const end = parseDate(endDate);
      const endValue: number = end === null ? 0 : end.getTime();
      if (endValue > latestEnd) {
        latestEnd = endValue;
        latest = { startDate: startDate, endDate: endDate };
      }
    }
    if (latest === null) {
      throw new ApiError(502, 'bykc_error', '无法获取博雅课程当前学期信息');
    }
    return latest;
  }
}

/**
 * 写操作的失败码（上游 `errmsg` 是中文原话，直接用即可）：
 * 「重复报名 / 已报名」= 已选过；「人数已满」= 名额不够；「不可选择 / 不可报名」= 不在报名窗口。
 * 所以界面上不需要额外映射，把 `errmsg` 弹给用户就是最准确的信息。
 */
interface BykcAvailability {
  canSign: boolean;
  canSignOut: boolean;
}
