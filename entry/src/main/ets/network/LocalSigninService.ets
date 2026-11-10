import { AppConfig } from '../common/AppConfig';
import { DateUtil } from '../common/DateUtil';
import { Logger } from '../common/Logger';
import { ApiError } from './ApiError';
import { resolveLocation, UpstreamClient, UpstreamResponse } from './UpstreamClient';
import { SigninActionResult, SigninClass } from '../model/ApiTypes';

/**
 * 本地模式下的课堂签到（iclass「一体化课堂」，客户端直接对接校内上游）。
 *
 * ## 上游契约从哪来
 *
 * 全部照抄原 UBAA 服务端的 `signin/` 三个文件（每个方法都标注了出处）：
 *
 * | 本文件 | 原实现 |
 * | --- | --- |
 * | `walkForLoginName` / `extractLoginName` | `SigninLoginNameSupport.kt` |
 * | `performLogin` / `fetchTodayClasses` / `signIn` | `SigninClient.kt` |
 * | `friendlyMessage` | `SigninClient.sanitizeSignInMessage` |
 *
 * 因此返回给 UI 的对象与原 `/api/v1/signin/*` 完全同构，页面不需要知道
 * 服务端已经不在了。
 *
 * ## 为什么 iclass 要单独一套会话
 *
 * iclass 不属于 CAS 体系：它有自己的 `userId` + `sessionId`，登录后由服务端下发，
 * 之后所有请求靠请求头 `sessionId` 认人。所以即便 SSO 会话正常，也必须先
 * 「换成 iclass 的会话」才能查课、签到。
 *
 * ## 换取凭据是 loginName，不是学号
 *
 * iclass 的登录接口不吃学号，吃的是**登录名** `loginName`。它不在任何接口的
 * 返回值里，只能从门户跳转链上捡：
 *
 *   1. GET `https://iclass.buaa.edu.cn:8346/?type=jumpMyCenter`；
 *   2. 未登录时这条链会 302 到统一身份认证，认证过再 302 回来，而**回跳目标
 *      URL 的查询串里就带着 `loginName`**；
 *   3. 于是逐跳跟随，每跳都检查「实际请求地址」与「Location 头」里的
 *      `loginName`，取到即可。
 *
 * 拿到 loginName 之后 `password` 传空串就能登录 —— iclass 把「持有有效 SSO
 * 会话」直接当成了身份凭证，这也是原实现能免密登录的原因。换句话说：
 * **本功能的安全性完全依赖门外那道 CAS，iclass 侧没有任何额外凭据。**
 */

/* ============================== 上游地址 ============================== */

/**
 * iclass 门户（跳转链上会带回 loginName）。
 *
 * **端口是 8346**，与登录接口的 8347 不是一个 —— 这是上游自己的划分，
 * 别顺手「统一」掉（原 `SIGNIN_MY_CENTER_URL`）。
 */
const ICLASS_PORTAL_URL: string = 'https://iclass.buaa.edu.cn:8346/?type=jumpMyCenter';

/** iclass 登录入口（原 `SigninClient.login`）。 */
const ICLASS_LOGIN_URL: string = 'https://iclass.buaa.edu.cn:8347/app/user/login.action';

/** 课程排课 + 签到状态（原 `SigninClient.getClasses`）。 */
const ICLASS_COURSE_URL: string =
  'https://iclass.buaa.edu.cn:8347/app/course/get_stu_course_sched.action';

/**
 * 签到类接口的基址（原 `SigninClient.signinCheckinUrl` 的落点）。
 *
 * 实测 iclass 的 8347 端口在**直连与 WebVPN 两种模式下都能走 https**，且
 * `stu_scan_sign.action` / `get_timestamp.action` 在 8347 上均存在、路径统一
 * **不带 `eschool` 前缀**（带 eschool 前缀的路径在 8347 上是 404）。
 *
 * 原实现里「直连走 `http://8081/eschool/...`」是历史入口；要迁就它就得给整个
 * 应用开明文 HTTP 许可（HarmonyOS 默认拦截 http://），得不偿失 —— 这里统一
 * 走 8347 的 https，两种连接模式共用同一条入口。
 */
const ICLASS_API_BASE: string = 'https://iclass.buaa.edu.cn:8347/';

/** 统一身份认证入口（门户没带回 loginName 时显式换取一次）。 */
const CAS_LOGIN_URL: string = 'https://' + AppConfig.UPSTREAM_SSO_HOST + '/login';

/** 跳转链最大跳数（原 `SIGNIN_LOGIN_REDIRECT_LIMIT`）。 */
const SIGNIN_LOGIN_REDIRECT_LIMIT: number = 8;

/* ============================== 工具 ============================== */

function enc(value: string): string {
  return encodeURIComponent(value);
}

/** 把可能是字符串也可能是数字的上游字段统一成去空白的字符串。 */
function textOf(value: string | number | undefined): string {
  if (value === undefined || value === null) {
    return '';
  }
  if (typeof value === 'number') {
    return value.toString();
  }
  return (value as string).trim();
}

/** 百分号解码；串里有非法转义时原样返回（不为一个参数把整条跳转链打断）。 */
function percentDecode(text: string): string {
  if (text.indexOf('%') < 0) {
    return text;
  }
  try {
    return decodeURIComponent(text);
  } catch (error) {
    return text;
  }
}

/* ============================== 响应契约 ============================== */

/** iclass 的通用信封：`STATUS` 为 "0" / "200" / "success" 表示成功。 */
interface IclassEnvelope<T> {
  STATUS?: string | number;
  ERRMSG?: string;
  result?: T;
}

/** 登录返回的会话标识（原 `SigninClient.login` 取 `result.id` / `result.sessionId`）。 */
interface IclassLoginResult {
  id?: string | number;
  sessionId?: string;
}

/** 一堂课的排课与签到状态（原 `SigninClassDto`）。 */
interface IclassCourseRaw {
  id?: string | number;
  courseName?: string;
  classBeginTime?: string;
  classEndTime?: string;
  signStatus?: string | number;
}

/** 签到返回体（原实现只认 `result.stuSignStatus == "1"`）。 */
interface IclassSignResult {
  stuSignStatus?: string | number;
}

/**
 * 服务器时间戳。
 *
 * 注意它在响应**顶层**，不是 `result.timestamp` —— 原实现是
 * `client.get(...).body<JsonObject>().get("timestamp")`，直接取的顶层字段。
 */
interface IclassTimestamp {
  timestamp?: string | number;
}

/** 只用来偷看 STATUS / ERRMSG 的轻量结构（会话探活时用）。 */
interface IclassStatusProbe {
  STATUS?: string | number;
  ERRMSG?: string;
}

/* ============================== 服务 ============================== */

export class LocalSigninService {
  /** 本进程内是否已换到 iclass 会话。 */
  private static ready: boolean = false;
  private static userId: string = '';
  private static sessionId: string = '';

  /* ------------------------------ 对外 ------------------------------ */

  /**
   * 今日可签到的课堂（含已签 / 未签状态）。
   *
   * @throws ApiError 会话换不到、上游故障或返回无法解析时抛出
   */
  static async fetchTodayClasses(): Promise<SigninClass[]> {
    await LocalSigninService.ensureLogin();
    const url = ICLASS_COURSE_URL +
      '?id=' + enc(LocalSigninService.userId) +
      '&dateStr=' + LocalSigninService.todayCompact();

    let response = await UpstreamClient.get(url, true, LocalSigninService.sessionHeaders());
    if (LocalSigninService.needsRelogin(response)) {
      Logger.warn('课堂签到会话已失效，重新换取后重试');
      await LocalSigninService.relogin();
      response = await UpstreamClient.get(url, true, LocalSigninService.sessionHeaders());
      if (LocalSigninService.needsRelogin(response)) {
        // 重登之后依然不成功：当作「今天没有需要签到的课」，
        // 与原实现第二轮回退空列表一致（避免把「无数据」渲染成整页报错）
        Logger.warn('课堂列表仍未取到（' + response.status + '），按空列表处理');
        return [];
      }
    }

    const envelope =
      LocalSigninService.parse<IclassCourseRaw[]>(response, '获取签到课堂失败');
    const list = envelope.result;
    if (list === undefined || list === null) {
      return [];
    }
    const classes = LocalSigninService.toClasses(list);
    Logger.info('今日签到课堂（' + LocalSigninService.todayCompact() + '）：' +
      classes.length + ' 堂');
    return classes;
  }

  /**
   * 对指定课程提交一次签到。
   *
   * 这是**不可撤销**的真实业务动作，只应由用户点击触发。
   *
   * @throws ApiError 会话换不到或上游故障时抛出
   */
  static async signIn(courseId: string): Promise<SigninActionResult> {
    await LocalSigninService.ensureLogin();
    let timestamp = await LocalSigninService.fetchTimestamp();
    if (timestamp.length === 0) {
      // 从「打开页面」到「点签到」之间会话可能被服务端回收，重换一次即可自愈
      Logger.warn('取服务器时间失败，重新换取会话后重试');
      await LocalSigninService.relogin();
      timestamp = await LocalSigninService.fetchTimestamp();
    }
    if (timestamp.length === 0) {
      throw new ApiError(502, 'signin_error', '获取服务器时间失败，请稍后重试');
    }

    const url = LocalSigninService.checkinUrl('app/course/stu_scan_sign.action');
    const body = 'id=' + enc(LocalSigninService.userId) +
      '&courseSchedId=' + enc(courseId) +
      '&timestamp=' + enc(timestamp);

    let response = await UpstreamClient.postForm(
      url, body, true, LocalSigninService.sessionHeaders());
    if (LocalSigninService.signRetryWorthy(response)) {
      Logger.warn('课堂签到会话已失效，重新换取后重试');
      await LocalSigninService.relogin();
      response = await UpstreamClient.postForm(
        url, body, true, LocalSigninService.sessionHeaders());
    }

    const envelope = LocalSigninService.parse<IclassSignResult>(response, '签到失败');
    const result = envelope.result;
    const signStatus = result === undefined ? '' : textOf(result.stuSignStatus);
    const success = LocalSigninService.isStatusOk(envelope.STATUS) && signStatus === '1';

    const raw = textOf(envelope.ERRMSG);
    if (!success) {
      Logger.warn('签到未成功：' + (raw.length > 0 ? raw : '上游未给出原因'));
    }
    return {
      success: success,
      message: LocalSigninService.friendlyMessage(success, raw)
    };
  }

  /* ---------------------------- 会话准备 ---------------------------- */

  /** 确保 iclass 会话可用：先解析登录名，再用登录名换会话。 */
  private static async ensureLogin(): Promise<void> {
    if (LocalSigninService.ready) {
      return;
    }
    let loginName = await LocalSigninService.walkForLoginName(ICLASS_PORTAL_URL);
    if (loginName.length === 0) {
      // 兜底：CAS 过滤器没返回 302 而是直接吐了登录页时，显式带 service 再换一次
      Logger.warn('门户跳转链未带回 loginName，显式走一次统一认证换取');
      loginName = await LocalSigninService.walkForLoginName(
        CAS_LOGIN_URL + '?service=' + enc(ICLASS_PORTAL_URL));
    }
    if (loginName.length === 0) {
      throw new ApiError(401, 'upstream_session_expired',
        '课堂签到会话未建立：未能取到课堂系统登录名，请返回设置页重新登录后重试');
    }
    await LocalSigninService.performLogin(loginName);
    LocalSigninService.ready = true;
  }

  private static async relogin(): Promise<void> {
    LocalSigninService.ready = false;
    LocalSigninService.userId = '';
    LocalSigninService.sessionId = '';
    await LocalSigninService.ensureLogin();
  }

  /** 用 loginName 换 iclass 会话（原 `SigninClient.login`，`password` 传空串）。 */
  private static async performLogin(loginName: string): Promise<void> {
    const url = ICLASS_LOGIN_URL +
      '?password=&phone=' + enc(loginName) +
      '&userLevel=1&verificationType=2&verificationUrl=';
    const response = await UpstreamClient.get(url, true);
    const envelope =
      LocalSigninService.parse<IclassLoginResult>(response, '课堂系统登录失败');

    if (!LocalSigninService.isStatusOk(envelope.STATUS)) {
      const message = textOf(envelope.ERRMSG);
      throw new ApiError(401, 'upstream_session_expired',
        '课堂系统登录失败：' + (message.length > 0 ? message : '上游未返回会话'));
    }
    const result = envelope.result;
    const userId = result === undefined ? '' : textOf(result.id);
    const sessionId = result === undefined ? '' : textOf(result.sessionId);
    if (userId.length === 0 || sessionId.length === 0) {
      throw new ApiError(502, 'signin_error', '课堂系统登录失败：上游未返回会话标识');
    }
    LocalSigninService.userId = userId;
    LocalSigninService.sessionId = sessionId;
    Logger.info('课堂签到会话就绪（userId=' + userId + '）');
  }

  /**
   * 逐跳跟随跳转链，从每一跳的「实际请求地址」与「Location 头」里找 loginName。
   *
   * 为什么不直接用 `UpstreamClient.follow`：它只返回最后一跳，而 loginName
   * 恰恰可能落在**中间某一跳**上（回跳那一刻带上，之后又被重定向掉）。
   *
   * WebVPN 模式下每一跳的实际地址是网关地址（`d.buaa.edu.cn/https-8346/...`），
   * 但查询串是原样透传的，所以照样能取到。
   */
  private static async walkForLoginName(startUrl: string): Promise<string> {
    let current = startUrl;
    for (let hop = 0; hop < SIGNIN_LOGIN_REDIRECT_LIMIT; hop++) {
      const fromCurrent = LocalSigninService.extractLoginName(current);
      if (fromCurrent.length > 0) {
        return fromCurrent;
      }
      const response = await UpstreamClient.get(current, false);
      const fromUrl = LocalSigninService.extractLoginName(response.url);
      if (fromUrl.length > 0) {
        return fromUrl;
      }
      if (response.location.length > 0) {
        const fromLocation = LocalSigninService.extractLoginName(response.location);
        if (fromLocation.length > 0) {
          return fromLocation;
        }
      }
      if (!response.isRedirect()) {
        return '';
      }
      current = resolveLocation(response.url, response.location);
    }
    return '';
  }

  /**
   * 从 URL 的查询串里取 `loginName`（原 `extractSigninLoginNameFromUrl`）。
   *
   * 先截到 `#` 之前，避免把前端的哈希路由当成查询参数。
   */
  private static extractLoginName(url: string): string {
    const queryIndex = url.indexOf('?');
    if (queryIndex < 0) {
      return '';
    }
    let query = url.substring(queryIndex + 1);
    const hashIndex = query.indexOf('#');
    if (hashIndex >= 0) {
      query = query.substring(0, hashIndex);
    }
    const parts = query.split('&');
    for (let i = 0; i < parts.length; i++) {
      const part = parts[i];
      const eq = part.indexOf('=');
      const key = eq >= 0 ? part.substring(0, eq) : part;
      if (key.toLowerCase() !== 'loginname') {
        continue;
      }
      const value = eq >= 0 ? part.substring(eq + 1) : '';
      if (value.length === 0) {
        continue;
      }
      return percentDecode(value);
    }
    return '';
  }

  /**
   * 取服务器时间戳（签到请求必须带上，上游据此判断签到时窗）。
   *
   * 拿不到时返回空串而**不抛错** —— 调用方要用它区分「换个会话还能救」与
   * 「真的取不到」，把判据留在调用处更好读。
   */
  private static async fetchTimestamp(): Promise<string> {
    const url = LocalSigninService.checkinUrl('app/common/get_timestamp.action');
    // 原实现对这一个接口没有加 sessionId 头，照抄
    const response = await UpstreamClient.get(url, true);
    if (!response.isOk()) {
      return '';
    }
    const trimmed = response.body.trimStart();
    if (!trimmed.startsWith('{')) {
      return '';
    }
    try {
      const parsed = JSON.parse(trimmed) as IclassTimestamp;
      const value = parsed.timestamp;
      if (value === undefined || value === null) {
        return '';
      }
      return textOf(value);
    } catch (error) {
      return '';
    }
  }

  /* ------------------------------ 内部 ------------------------------ */

  /**
   * 组装签到类接口的实际地址。
   *
   * 两种连接模式统一走 8347 的 https、路径不带 `eschool` 前缀（见 ICLASS_API_BASE
   * 注释），故这里只收一个路径参数。
   */
  private static checkinUrl(path: string): string {
    return ICLASS_API_BASE + path;
  }

  /** iclass 用请求头 `sessionId` 认人（原实现唯一必带的业务头）。 */
  private static sessionHeaders(): Record<string, string> {
    const headers: Record<string, string> = {};
    headers['sessionid'] = LocalSigninService.sessionId;
    return headers;
  }

  /**
   * HTTP / HTML 层的会话失效：3xx、非 2xx、或停在门户登录页。
   *
   * iclass 对失效的会话**不跳转、也不回 401**，通常照常 200 返回 JSON、只把
   * `STATUS` 置成失败 —— 所以 STATUS 层的判断单独放在调用方（不同接口的
   * 宽严尺度不一样，见 `needsRelogin` 与 `signRetryWorthy`）。
   */
  private static transportDead(response: UpstreamResponse): boolean {
    if (response.isRedirect() || !response.isOk()) {
      return true;
    }
    return !response.body.trimStart().startsWith('{');
  }

  /**
   * 课程列表的会话判定：STATUS 失败也重换一次（与原 `getClasses` 一致）。
   *
   * 极少数接口（`get_timestamp`）不带 STATUS 字段，那种视为正常。
   */
  private static needsRelogin(response: UpstreamResponse): boolean {
    if (LocalSigninService.transportDead(response)) {
      return true;
    }
    try {
      const probe = JSON.parse(response.body.trimStart()) as IclassStatusProbe;
      const status = probe.STATUS;
      if (status === undefined) {
        return false;
      }
      return !LocalSigninService.isStatusOk(status);
    } catch (error) {
      return true;
    }
  }

  /**
   * 签到响应是否值得「重换会话再试一次」。
   *
   * 与课程列表不同：签到的 STATUS 失败绝大多数是**业务原因**（不是上课时间、
   * 签到未开始、不在范围），重换会话救不了，反而白跑一遍 SSO 跳转链（真机
   * 实测 `当前时间不是上课时间！` 触发过一整轮重试，多花约 1.5 秒）。原实现
   * 对签到也只信 `ERRMSG` 里的「登录」字样 —— 只有它才说明会话真没了。
   */
  private static signRetryWorthy(response: UpstreamResponse): boolean {
    if (LocalSigninService.transportDead(response)) {
      return true;
    }
    try {
      const probe = JSON.parse(response.body.trimStart()) as IclassStatusProbe;
      if (LocalSigninService.isStatusOk(probe.STATUS)) {
        return false;
      }
      const message = probe.ERRMSG === undefined ? '' : textOf(probe.ERRMSG);
      return message.indexOf('登录') >= 0;
    } catch (error) {
      return true;
    }
  }

  /** `STATUS` 是否表示成功（原 `isStatusSuccess`）。 */
  private static isStatusOk(status: string | number | undefined): boolean {
    const value = textOf(status);
    return value === '0' || value === '200' || value === 'success';
  }

  /** 解析 iclass 信封；HTTP 层或 JSON 层出问题时抛出可读错误。 */
  private static parse<T>(response: UpstreamResponse, what: string): IclassEnvelope<T> {
    if (response.isRedirect()) {
      throw new ApiError(401, 'upstream_session_expired',
        what + '：课堂系统会话已失效，请重新登录');
    }
    if (!response.isOk()) {
      if (response.body.indexOf('<html') >= 0 || response.body.indexOf('<!DOCTYPE') >= 0) {
        throw ApiError.fromHtmlResponse(response.status, response.body,
          AppConfig.hostOf(response.url));
      }
      throw new ApiError(response.status, 'upstream_down',
        what + '：上游返回 HTTP ' + response.status);
    }
    const trimmed = response.body.trimStart();
    if (!trimmed.startsWith('{')) {
      throw new ApiError(502, 'upstream_down', what + '：上游返回的是网页而不是数据');
    }
    try {
      return JSON.parse(trimmed) as IclassEnvelope<T>;
    } catch (error) {
      throw new ApiError(502, 'upstream_down', what + '：上游返回的数据无法解析');
    }
  }

  /** 上游数组 → UI 契约（与 `SigninClassDto` 逐字段对应）。 */
  private static toClasses(list: IclassCourseRaw[]): SigninClass[] {
    const out: SigninClass[] = [];
    for (let i = 0; i < list.length; i++) {
      const item = list[i];
      if (item === undefined || item === null) {
        continue;
      }
      const courseId = textOf(item.id);
      const courseName = textOf(item.courseName);
      // 没有课程 id 就无法发起签到，直接丢掉比留一个点了没反应的按钮好
      if (courseId.length === 0 || courseName.length === 0) {
        continue;
      }
      const status = parseInt(textOf(item.signStatus), 10);
      out.push({
        courseId: courseId,
        courseName: courseName,
        classBeginTime: textOf(item.classBeginTime),
        classEndTime: textOf(item.classEndTime),
        signStatus: isNaN(status) ? 0 : status
      });
    }
    return out;
  }

  /** 上游要的日期格式是 `yyyyMMdd`（原 `DateTimeFormatter.ofPattern("yyyyMMdd")`）。 */
  private static todayCompact(): string {
    return DateUtil.today().split('-').join('');
  }

  /**
   * 把上游的原始报错翻成人话（原 `sanitizeSignInMessage`）。
   *
   * 上游的 ERRMSG 是写给运维看的（「用户不存在」「不在范围」），直接甩到界面上
   * 既含糊又吓人，这里逐条映射。判断顺序与原实现保持一致。
   */
  private static friendlyMessage(success: boolean, rawMessage: string): string {
    if (success) {
      return rawMessage.length > 0 ? rawMessage : '签到成功';
    }
    if (rawMessage.indexOf('已签到') >= 0) {
      return '您今天已经签到过了';
    }
    if (rawMessage.indexOf('未开始') >= 0) {
      return '当前还未到签到时间';
    }
    if (rawMessage.indexOf('不是上课时间') >= 0) {
      return '当前不是上课时间，无法签到';
    }
    if (rawMessage.indexOf('已结束') >= 0) {
      return '本次签到已结束';
    }
    if (rawMessage.indexOf('范围') >= 0) {
      return '当前不在可签到范围内';
    }
    if (rawMessage.indexOf('用户不存在') >= 0) {
      return '签到账号不存在，请联系管理员';
    }
    if (rawMessage.indexOf('课程') >= 0 && rawMessage.indexOf('不存在') >= 0) {
      return '未找到对应课程，请刷新后重试';
    }
    return '签到失败，请稍后重试';
  }
}
