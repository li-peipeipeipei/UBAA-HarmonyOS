import { util } from '@kit.ArkTS';
import { Logger } from '../common/Logger';
import { ApiError, CaptchaRequiredError } from './ApiError';
import { CasParser } from './CasParser';
import { resolveLocation, stripQuery, UpstreamClient, UpstreamResponse } from './UpstreamClient';
import { LocalAuthSession, TokenStore } from './TokenStore';
import { LocalWebVpn } from './LocalWebVpn';
import {
  CaptchaInfo,
  LoginPreloadResponse,
  LoginResponse,
  SessionStatusResponse,
  UserData,
  UserInfo
} from '../model/ApiTypes';

/**
 * 本地模式登录（客户端自己完成校内统一身份认证）。
 *
 * ## 为什么登录要搬到客户端
 *
 * 原生 UBAA 里登录有两种实现：SERVER_RELAY（服务端抓 CAS 页、提交、签 JWT）与
 * 本地模式（客户端自己打 sso / uc）。本项目复用的是 SERVER_RELAY 那一套
 * （`/api/v1/auth/*`），但该服务端已停止部署 —— 于是登录链路上根本没人替我们
 * 完成 CAS。参考实现的本地模式（`LocalConnectionAuth.kt`）就是为这种场景写的，
 * 本文件是它在 ArkTS 侧的等价实现。
 *
 * ## 完整流程
 *
 * ```
 *  GET  sso.buaa.edu.cn/login          → 取 execution + 探测验证码
 *  POST sso.buaa.edu.cn/login (表单)   → 不自动跟随，逐跳检查
 *  GET  uc.buaa.edu.cn/api/login?…     → 用刚拿到的 SSO 会话换取 UC 会话
 *  GET  uc.buaa.edu.cn/api/uc/status   → code==0 且带 data 才算登录成功
 * ```
 *
 * ## 登录态是什么
 *
 * **上游 Cookie**，不是 JWT。因此本地模式没有 accessToken / refreshToken，
 * `LoginResponse` 里这两个字段必然为空串，会话有效性靠实时打 `uc/status` 判定
 * （见 `validate`）。
 *
 * ## 校验为什么不能省
 *
 * `POST /login` 返回 200 并不代表成功 —— CAS 在账号密码错误时同样返回 200 的
 * 登录页。唯一的权威判据是 UC 侧会话是否真的建立起来了。
 */

const CAS_LOGIN_URL: string = 'https://sso.buaa.edu.cn/login';
const CAS_LOGOUT_URL: string = 'https://sso.buaa.edu.cn/logout';
const CAS_CAPTCHA_URL: string = 'https://sso.buaa.edu.cn/captcha';
const UC_STATUS_URL: string = 'https://uc.buaa.edu.cn/api/uc/status';
const UC_USERINFO_URL: string = 'https://uc.buaa.edu.cn/api/uc/userinfo';
const UC_ACTIVATE_URL: string =
  'https://uc.buaa.edu.cn/api/login?target=https%3A%2F%2Fuc.buaa.edu.cn%2F%23%2Fuser%2Flogin';

/** 单条重定向链最大跳数（正常登录不超过 5 跳，超过说明打转了）。 */
const MAX_REDIRECT_HOPS: number = 10;

/** UC 的响应信封：{ code, msg, data }。 */
interface UcEnvelope {
  code?: number;
  msg?: string;
  data?: UserInfo;
}

/** 会话校验结果。 */
export enum LocalSessionState {
  /** 上游会话有效。 */
  VALID = 'VALID',
  /** 上游明确表示未登录（应清除本地会话）。 */
  INVALID = 'INVALID',
  /** 上游暂时不可用（5xx / 网络失败），不能据此清除会话。 */
  TRANSIENT = 'TRANSIENT'
}

export class LocalValidation {
  state: LocalSessionState = LocalSessionState.INVALID;
  session: LocalAuthSession | null = null;
}

function nowIso(): string {
  return new Date().toISOString();
}

function toUserData(session: LocalAuthSession): UserData {
  return { name: session.userName, schoolid: session.schoolId };
}

export class LocalAuthService {
  /* ============================ 登录前置 ============================ */

  /**
   * 拉取登录页，取出一次性令牌并探测验证码。
   *
   * 只做「探测」不做「自动登录」：会话恢复由 Index 的 `status()` 负责，
   * 这里重复跑一遍只会白多一次网络往返。
   */
  static async preload(): Promise<LoginPreloadResponse> {
    const result: LoginPreloadResponse = { captchaRequired: false };
    const page = await UpstreamClient.get(CAS_LOGIN_URL, false);
    // 302 说明已有 SSO 会话，此时登录页不需要填写任何东西
    if (!page.isOk()) {
      return result;
    }
    const html = page.body;
    const execution = CasParser.extractExecution(html);
    if (execution.length > 0) {
      result.execution = execution;
    }
    const captcha = CasParser.detectCaptcha(html, CAS_CAPTCHA_URL);
    if (captcha !== null) {
      result.captchaRequired = true;
      result.captcha = await LocalAuthService.hydrateCaptcha(captcha);
    }
    return result;
  }

  /* ============================== 登录 ============================== */

  /**
   * 执行一次完整登录。
   *
   * @throws CaptchaRequiredError 需要验证码（携带图片与新的 execution，调用方应重试）
   * @throws ApiError 凭据错误（code `cas_login_failed`）/ 上游不可用（`auth_upstream_timeout`）
   */
  static async login(
    username: string,
    password: string,
    captcha: string,
    execution: string
  ): Promise<LoginResponse> {
    const loginPage = await UpstreamClient.get(CAS_LOGIN_URL, false);

    if (loginPage.isRedirect()) {
      // 已有 SSO 会话：不必再提交凭据，直接去 UC 换会话
      Logger.info('SSO 已存在会话，跳过凭据提交');
      await LocalAuthService.activateUcLogin();
    } else {
      if (!loginPage.isOk()) {
        throw new ApiError(loginPage.status, 'cas_page_failed',
          '统一身份认证页面加载失败（HTTP ' + loginPage.status + '），请确认网络或改用 WebVPN 模式');
      }

      const html = loginPage.body;
      // 页面自带的提示（如「密码已过期」）优先原样透出
      const tip = CasParser.extractTipText(html);
      if (tip.length > 0) {
        throw new ApiError(400, 'cas_login_failed', tip);
      }

      const actualExecution = execution.length > 0 ? execution : CasParser.extractExecution(html);
      if (actualExecution.length === 0) {
        // 拿空令牌去提交只会被服务端判成「凭据无效」，报错会指向错误的方向
        throw new ApiError(500, 'cas_page_failed',
          '未能从统一认证页面解析到登录令牌，页面可能已改版或网络被劫持，请稍后重试');
      }
      const captchaInfo = CasParser.detectCaptcha(html, CAS_CAPTCHA_URL);
      if (captchaInfo !== null && captcha.length === 0) {
        throw new CaptchaRequiredError(
          await LocalAuthService.hydrateCaptcha(captchaInfo),
          actualExecution,
          '本次登录需要验证码'
        );
      }

      const formBody = (captchaInfo !== null || captcha.length > 0)
        ? CasParser.buildCaptchaLoginBody(username, password, captcha, actualExecution)
        : CasParser.buildLoginBody(html, username, password, actualExecution, captcha);

      Logger.info('提交 CAS 凭据：账号 ' + username + '，模式 ' +
        TokenStore.getConnectionMode() + '，目标 ' + CAS_LOGIN_URL);
      const submit = await UpstreamClient.postForm(CAS_LOGIN_URL, formBody, false);
      Logger.info('CAS 提交响应：状态 ' + submit.status.toString() +
        '，Location ' + submit.location + '，最终地址 ' + submit.url);
      await LocalAuthService.followAndCheck(submit);
      await LocalAuthService.activateUcLogin();
    }

    const validation = await LocalAuthService.validate();
    if (validation.state === LocalSessionState.VALID && validation.session !== null) {
      const session = validation.session;
      session.username = session.username.length > 0 ? session.username : username;
      TokenStore.saveLocalSession(session);
      Logger.info('本地模式登录成功：' + session.userName + ' / ' + session.schoolId);
      return {
        user: toUserData(session),
        // 本地模式没有 JWT，令牌字段按契约留空（参考实现同样如此）
        accessToken: '',
        refreshToken: '',
        accessTokenExpiresAt: '',
        refreshTokenExpiresAt: ''
      };
    }
    if (validation.state === LocalSessionState.TRANSIENT) {
      throw new ApiError(503, 'auth_upstream_timeout', '统一认证服务响应超时，请稍后重试');
    }
    throw new ApiError(401, 'cas_login_failed', '账号或密码验证未通过，请重新输入');
  }

  /* ============================ 会话校验 ============================ */

  /**
   * 实时校验上游会话。
   *
   * 必须区分「未登录」与「上游挂了」：前者要清本地会话并回登录页，后者清掉会
   * 让用户在网络抖动时被莫名登出。
   */
  static async validate(): Promise<LocalValidation> {
    const result = new LocalValidation();
    let response: UpstreamResponse;
    try {
      response = await UpstreamClient.get(UC_STATUS_URL, false, {
        // UC 的接口对非 XHR 请求会返回登录页而不是 JSON
        'X-Requested-With': 'XMLHttpRequest'
      });
    } catch (error) {
      Logger.warn('会话校验网络失败：' + (error as Error).message);
      result.state = LocalSessionState.TRANSIENT;
      return result;
    }

    if (response.status >= 500) {
      result.state = LocalSessionState.TRANSIENT;
      return result;
    }
    if (!response.isOk()) {
      result.state = LocalSessionState.INVALID;
      return result;
    }
    // 被重定向或返回 HTML，说明会话已失效（回到了统一认证门户）
    if (!response.body.trimStart().startsWith('{')) {
      result.state = LocalSessionState.INVALID;
      return result;
    }

    let envelope: UcEnvelope;
    try {
      envelope = JSON.parse(response.body) as UcEnvelope;
    } catch (error) {
      Logger.warn('会话校验响应解析失败');
      result.state = LocalSessionState.INVALID;
      return result;
    }
    const code = envelope.code === undefined ? -1 : envelope.code;
    const info = envelope.data;
    if (code !== 0 || info === undefined || info === null) {
      result.state = LocalSessionState.INVALID;
      return result;
    }

    const previous = TokenStore.getLocalSession();
    const session: LocalAuthSession = {
      username: LocalAuthService.pickUsername(info, previous),
      userName: info.name === undefined ? '' : info.name,
      schoolId: info.schoolid === undefined ? '' : info.schoolid,
      authenticatedAt: previous !== null && previous.authenticatedAt.length > 0
        ? previous.authenticatedAt
        : nowIso(),
      lastActivity: nowIso()
    };

    result.state = LocalSessionState.VALID;
    result.session = session;
    return result;
  }

  /** 查询登录状态（Index 恢复会话 / 设置页展示用）。 */
  static async status(): Promise<SessionStatusResponse> {
    const stored = TokenStore.getLocalSession();
    if (stored === null) {
      throw ApiError.unauthorized();
    }
    const validation = await LocalAuthService.validate();
    if (validation.state === LocalSessionState.VALID && validation.session !== null) {
      const session = validation.session;
      TokenStore.saveLocalSession(session);
      return {
        user: toUserData(session),
        lastActivity: session.lastActivity,
        authenticatedAt: session.authenticatedAt
      };
    }
    if (validation.state === LocalSessionState.TRANSIENT) {
      throw new ApiError(503, 'auth_upstream_timeout', '统一认证服务响应超时，请稍后重试');
    }
    TokenStore.clearLocalSession();
    throw ApiError.unauthorized();
  }

  /** 注销：尽力通知上游退出，随后无条件清空本地登录态。 */
  static async logout(): Promise<void> {
    try {
      await LocalAuthService.followTo(CAS_LOGOUT_URL);
    } catch (error) {
      Logger.warn('上游注销失败，本地登录态仍会清除：' + (error as Error).message);
    }
    TokenStore.clearAllLocalSessions();
  }

  /* ============================ 用户信息 ============================ */

  /** 从校内用户中心读取个人信息（本地模式下这是唯一可用的用户信息源）。 */
  static async fetchUserInfo(): Promise<UserInfo> {
    const response = await UpstreamClient.get(UC_USERINFO_URL, false, {
      'X-Requested-With': 'XMLHttpRequest'
    });
    if (!response.isOk() || !response.body.trimStart().startsWith('{')) {
      throw ApiError.unauthorized();
    }
    const envelope = JSON.parse(response.body) as UcEnvelope;
    const code = envelope.code === undefined ? -1 : envelope.code;
    if (code !== 0 || envelope.data === undefined || envelope.data === null) {
      throw new ApiError(500, 'user_info_failed', '个人信息获取失败，请稍后重试');
    }
    return envelope.data;
  }

  /** 验证码图片地址（本地模式下直接指向统一认证的验证码接口）。 */
  static captchaUrl(captchaId: string): string {
    return CAS_CAPTCHA_URL + '?captchaId=' + captchaId;
  }

  /* ============================== 内部 ============================== */

  /** 拉取验证码图片并内联成 data URI（跨域图片直接给 URL 可能加载不出来）。 */
  private static async hydrateCaptcha(captcha: CaptchaInfo): Promise<CaptchaInfo> {
    const hydrated: CaptchaInfo = {
      id: captcha.id,
      type: captcha.type,
      imageUrl: captcha.imageUrl
    };
    try {
      const response = await UpstreamClient.getBinary(LocalAuthService.captchaUrl(captcha.id));
      if (response.isOk() && response.bytes !== null && response.bytes.length > 0) {
        const helper = new util.Base64Helper();
        hydrated.base64Image = 'data:image/jpeg;base64,' + helper.encodeToStringSync(response.bytes);
      }
    } catch (error) {
      Logger.warn('验证码图片获取失败：' + (error as Error).message);
    }
    return hydrated;
  }

  /**
   * 用已有的 SSO 会话换取 UC 会话。
   *
   * UC 侧没有会话时会 302 到统一认证，再拿 ticket 跳回来 —— 这条链上的每一跳
   * 都必须带上各自域名的 Cookie，所以只能逐跳手动跟随（见 followTo 的注释）。
   */
  private static async activateUcLogin(): Promise<void> {
    // ⚠️ **必须带错误检查**（对齐原版 `activateUcLogin` 用的是
    // `followRedirectsAndCheckError`）—— 只跟随不检查的话，
    // UC 侧失败会被静默吞掉，最后只能报「账号或密码验证未通过」这种
    // **指向错误方向**的提示（密码其实是对的，是会话没建起来）。
    const response = await LocalAuthService.followTo(UC_ACTIVATE_URL);
    const body: string = response.body;
    const markerIndex: number = response.url.indexOf('exception.message=');
    if (markerIndex >= 0) {
      throw new ApiError(401, 'cas_login_failed', LocalAuthService.decodeMessage(
        response.url.substring(markerIndex + 'exception.message='.length)
      ));
    }
    const loginError: string = CasParser.findLoginError(body);
    if (response.status === 401 || loginError.length > 0) {
      throw new ApiError(401, 'cas_login_failed',
        loginError.length > 0 ? loginError : '账号或密码错误，请重试');
    }
    Logger.info('UC 会话激活完成，最终状态 ' + response.status);
  }

  /**
   * 逐跳跟随重定向（实现见 `UpstreamClient.follow`）。
   *
   * 为什么不用 `maxRedirects` 自动跟随：`@ohos.net.http` 的自动重定向只认第一次
   * 请求上挂的 Cookie，中间跳转不会重新按目标域名组装 Cookie 头。而这条链恰好
   * 在 sso / uc 两个域之间来回跳，缺一跳 Cookie 就断。
   */
  private static async followTo(
    url: string,
    extraHeaders?: Record<string, string>
  ): Promise<UpstreamResponse> {
    return await UpstreamClient.follow(url, extraHeaders);
  }

  /**
   * 跟随登录提交后的跳转链，并在每一跳上判定成败。
   *
   * CAS 的失败信息散落在三个地方，缺一个就会把失败当成功：
   * 1. 跳转目标 URL 里的 `exception.message=`（凭据类的软失败）
   * 2. 页面里的 tip-text / errors 容器（文案面向用户，直接透出）
   * 3. 又回到了带 username+password 的登录表单（被退回）
   */
  private static async followAndCheck(initial: UpstreamResponse): Promise<void> {
    let current = initial;
    let passwordExpiryIgnored = false;
    let hops = 0;

    while (true) {
      while (current.isRedirect() && hops < MAX_REDIRECT_HOPS) {
        hops++;
        const resolved: string = resolveLocation(current.url, current.location);
        // ⚠️ **WebVPN 模式下必须「解包 → HSTS 升级 → 重包」**（对齐原版
        // `LocalConnectionAuth.followRedirectsAndCheckError`）：
        //   1. 网关返回的 Location 是**网关地址**（主机名加密的），
        //      直接当校内地址再包装一次 =双重包装 → 地址错乱 →
        //      凭据根本没提交到 SSO → 表现为「账号或密码验证未通过」（密码其实是对的）；
        //   2. SSO 开了 HSTS，浏览器会自动把 http 升成 https，
        //      **原生客户端没这层机制**，不升级就是明文请求，SSO 会拒。
        const unwrapped: string = await LocalWebVpn.fromWebVpnUrl(resolved);
        const secured: string = LocalWebVpn.secureCasTransportUrl(unwrapped);
        current = await UpstreamClient.get(secured, false);
      }

      const body = current.body;

      // 「密码过期 / 账号风险」不是失败，是要求确认一次「继续」
      if (CasParser.isIgnorablePasswordExpiryPage(body)) {
        if (passwordExpiryIgnored) {
          throw new ApiError(400, 'cas_login_failed', '登录失败，请稍后重试');
        }
        const execution = CasParser.extractExecution(body);
        if (execution.length === 0) {
          throw new ApiError(400, 'cas_login_failed', '登录失败，请稍后重试');
        }
        passwordExpiryIgnored = true;
        current = await UpstreamClient.postForm(
          stripQuery(current.url),
          CasParser.buildIgnorePasswordExpiryBody(execution),
          false
        );
        continue;
      }

      const marker = 'exception.message=';
      const markerIndex = current.url.indexOf(marker);
      if (markerIndex >= 0) {
        throw new ApiError(401, 'cas_login_failed', LocalAuthService.decodeMessage(
          current.url.substring(markerIndex + marker.length)
        ));
      }

      const loginError = CasParser.findLoginError(body);
      if (current.status === 401 || loginError.length > 0) {
        throw new ApiError(401, 'cas_login_failed',
          loginError.length > 0 ? loginError : '账号或密码错误，请重试');
      }
      if (CasParser.hasLoginForm(body)) {
        throw new ApiError(401, 'cas_login_failed', '账号或密码错误，请重试');
      }
      return;
    }
  }

  /** 从查询串里取出到 `&` 为止的一段并解码成可读文案。 */
  private static decodeMessage(raw: string): string {
    let text = raw;
    const amp = text.indexOf('&');
    if (amp >= 0) {
      text = text.substring(0, amp);
    }
    try {
      text = decodeURIComponent(text.replace(/\+/g, ' '));
    } catch (error) {
      // 编码不合法时保留原文，总比抛异常好
    }
    return text.length > 0 ? text : '账号或密码错误，请重试';
  }

  private static pickUsername(info: UserInfo, previous: LocalAuthSession | null): string {
    if (info.schoolid !== undefined && info.schoolid.length > 0) {
      return info.schoolid;
    }
    if (info.username !== undefined && info.username.length > 0) {
      return info.username;
    }
    return previous !== null ? previous.username : '';
  }
}
