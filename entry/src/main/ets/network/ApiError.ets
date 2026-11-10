import { CaptchaInfo } from '../model/ApiTypes';

/**
 * 业务异常。
 *
 * 与服务端错误契约对齐：{ "error": { "code": "...", "message": "..." } }
 */
export class ApiError extends Error {  /** 服务端错误码，如 invalid_token / invalid_credentials。 */
  readonly code: string;
  /** HTTP 状态码，网络层失败时为 0。 */
  readonly status: number;
  /** 是否为网络层失败（超时、DNS、无网络）。 */
  readonly networkFailure: boolean;
  /** 出错时请求的目标「主机:端口」，便于定位是哪个地址不通。 */
  readonly target: string;

  constructor(
    status: number,
    code: string,
    message: string,
    networkFailure: boolean = false,
    target: string = ''
  ) {
    super(message);
    this.name = 'ApiError';
    this.status = status;
    this.code = code;
    this.networkFailure = networkFailure;
    this.target = target;
  }

  static network(message: string, target: string = ''): ApiError {
    return new ApiError(0, 'network_error', message, true, target);
  }

  static unauthorized(target: string = ''): ApiError {
    return new ApiError(401, 'invalid_token', '登录状态已失效，请重新登录', false, target);
  }

  /** 服务端返回的是网页（WebVPN / CAS 登录页）而非接口数据。 */
  static portalPage(status: number, target: string): ApiError {
    return new ApiError(status, 'portal_page',
      '服务端返回的是网页而不是接口数据（常见于 WebVPN / CAS 登录拦截）', false, target);
  }

  /** 提取 HTML 文档标题，作为定位故障的补充线索。 */
  private static htmlTitle(body: string): string {
    const lower: string = body.toLowerCase();
    const open: number = lower.indexOf('<title>');
    if (open < 0) {
      return '';
    }
    const close: number = lower.indexOf('</title>', open);
    if (close < 0) {
      return '';
    }
    const text: string = body.substring(open + 7, close).trim();
    return text.length > 64 ? text.substring(0, 64) : text;
  }

  /**
   * 服务端返回 HTML 而非接口 JSON。
   *
   * 必须按状态码区分两种性质完全相反的情况，否则会把「服务端挂了」误报成「被登录页拦截」：
   * - 5xx：反向代理（nginx 等）自产的错误页，说明上游服务没起来 —— 地址是对的，问题在服务端
   * - 404：地址或路径不对，打到别的站点上去了
   * - 401 / 403：位置正确但没通过认证 —— 本域会话没了，重新登录即可（**不要**报成「服务端故障」）
   * - 2xx：接口位置正确但内容被登录门户替换 —— 真正的 WebVPN / CAS 拦截
   */
  static fromHtmlResponse(status: number, body: string, target: string): ApiError {
    const title: string = ApiError.htmlTitle(body);
    const titleHint: string = title.length > 0 ? '（错误页标题「' + title + '」）' : '';

    if (status >= 500) {
      let detail: string = '服务端错误';
      if (status === 502) {
        detail = '502 网关错误：反向代理连不上后端上游服务';
      } else if (status === 503) {
        detail = '503 服务不可用：后端服务未启动或正在重启';
      } else if (status === 504) {
        detail = '504 网关超时：后端服务响应超时';
      } else if (status === 500) {
        detail = '500 服务端内部错误';
      }
      return new ApiError(status, 'upstream_down',
        detail + titleHint + '。地址可达，属于服务端侧故障，客户端换网络或改地址都无法解决。',
        false, target);
    }

    // 401 / 403：接口在，但当前会话对这个子系统无效（如教务侧 Cookie 已过期）。
    // 走 invalid_token，让上层把它当「需要重新登录」而不是「服务端故障」。
    if (status === 401 || status === 403) {
      return new ApiError(401, 'invalid_token',
        '登录状态已失效（上游返回 HTTP ' + status + '）' + titleHint + '，请重新登录后再试。',
        false, target);
    }

    if (status === 404) {
      return new ApiError(404, 'http_404',
        '404 接口不存在' + titleHint + '：当前地址未部署 UBAA 接口，请检查地址与端口是否正确。',
        false, target);
    }

    if (status >= 200 && status < 300) {
      return new ApiError(status, 'portal_page',
        '接口位置正确，但返回的是网页而不是数据' + titleHint +
        '：请求被 WebVPN / CAS 登录门户接管了，请先在浏览器完成一次统一身份认证。',
        false, target);
    }

    return ApiError.portalPage(status, target);
  }

  /** 面向用户的可读文案。 */
  friendlyMessage(): string {
    // 网络层失败时 message 已是可读结论（含错误码含义），直接透出；否则会被泛化文案盖掉关键信息。
    if (this.networkFailure) {
      return this.message.length > 0 ? this.message : '网络连接失败，请检查网络后重试';
    }
    switch (this.code) {
      case 'invalid_credentials':
        return '学号或密码错误，请重新输入';
      case 'invalid_token':
        return '登录状态已失效，请重新登录';
      case 'invalid_refresh_token':
        return '登录已过期，请重新登录';
      case 'auth_upstream_timeout':
        return '学校服务响应超时，请稍后重试';
      case 'captcha_required':
        return '需要输入验证码';
      case 'unsupported_portal':
        return '当前账号类型暂不支持该功能';
      case 'schedule_error':
        return '课表数据获取失败，请稍后重试';
      case 'exam_error':
        return '考试数据获取失败，请稍后重试';
      case 'grade_error':
        return '成绩数据获取失败，请稍后重试';
      case 'user_info_failed':
        return '个人信息获取失败，请稍后重试';
      case 'internal_server_error':
        return '服务端开小差了，请稍后重试';
      case 'upstream_down':
        return this.message;
      case 'portal_page':
        return this.message;
      default:
        return this.message.length > 0 ? this.message : '请求失败，请稍后重试';
    }
  }
}

/**
 * 需要验证码时抛出。
 *
 * 两种来源共用这一个类型：
 * - 本地模式：CAS 登录页声明了 `config.captcha`，需带上验证码重试；
 * - 中转模式：服务端返回 422 挑战。
 *
 * `execution` 是必须原样回传的一次性令牌，丢一次整轮登录就废了。
 */
export class CaptchaRequiredError extends ApiError {
  readonly captcha: CaptchaInfo;
  readonly execution: string;

  constructor(captcha: CaptchaInfo, execution: string, message: string) {
    super(422, 'captcha_required', message);
    this.name = 'CaptchaRequiredError';
    this.captcha = captcha;
    this.execution = execution;
  }

  /** 面向用户的文案：带上验证码图片即可直接展示。 */
  friendlyMessage(): string {
    return this.message.length > 0 ? this.message : '需要输入验证码';
  }
}
