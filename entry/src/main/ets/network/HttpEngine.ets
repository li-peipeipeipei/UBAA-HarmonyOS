import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { AppConfig } from '../common/AppConfig';
import { Logger } from '../common/Logger';
import { ApiError } from './ApiError';
import { StoredSession, TokenStore } from './TokenStore';
import { ErrorResponse, TokenRefreshRequest, TokenRefreshResponse } from '../model/ApiTypes';

/** 原始响应封装（不解析业务结构，交由上层 as 转换）。 */
export class HttpResult {
  status: number = 0;
  body: string = '';

  constructor(status: number, body: string) {
    this.status = status;
    this.body = body;
  }

  isOk(): boolean {
    return this.status >= 200 && this.status < 300;
  }
}

/**
 * HTTP 引擎。
 *
 * 职责：
 * 1. 统一拼接 API 基址与 /api/v1 前缀
 * 2. 自动注入 Authorization: Bearer <accessToken>
 * 3. 遇到 401 自动使用 refreshToken 换新令牌并重试一次
 * 4. 把服务端 { error: { code, message } } 契约转换为 ApiError
 */
export class HttpEngine {
  /** 防止并发刷新令牌。 */
  private static refreshing: boolean = false;

  /** 判断是否已经在刷新（供并发请求等待）。 */
  private static async waitForRefresh(): Promise<boolean> {
    let waited = 0;
    while (HttpEngine.refreshing && waited < 5000) {
      await HttpEngine.sleep(100);
      waited += 100;
    }
    return TokenStore.getSession().isValid();
  }

  private static sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }

  private static buildUrl(path: string, query?: Map<string, string>): string {
    let url = TokenStore.getApiBaseUrl();
    if (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    url = url + path;
    if (query !== undefined && query.size > 0) {
      const parts: string[] = [];
      query.forEach((value: string, key: string) => {
        parts.push(encodeURIComponent(key) + '=' + encodeURIComponent(value));
      });
      url = url + '?' + parts.join('&');
    }
    return url;
  }

  private static async rawRequest(
    method: http.RequestMethod,
    url: string,
    body: string | undefined,
    needAuth: boolean
  ): Promise<HttpResult> {
    const headers: Record<string, string> = {
      'Content-Type': 'application/json',
      'Accept': 'application/json',
      'User-Agent': 'UBAA-Harmony/' + AppConfig.APP_VERSION
    };
    if (needAuth) {
      const session = TokenStore.getSession();
      if (session.accessToken.length > 0) {
        headers['Authorization'] = 'Bearer ' + session.accessToken;
      }
    }

    const options: http.HttpRequestOptions = {
      method: method,
      header: headers,
      connectTimeout: AppConfig.CONNECT_TIMEOUT,
      readTimeout: AppConfig.READ_TIMEOUT,
      expectDataType: http.HttpDataType.STRING
    };
    if (body !== undefined) {
      options.extraData = body;
    }

    const request = http.createHttp();
    const startedAt = Date.now();
    try {
      const response = await request.request(url, options);
      let text = '';
      if (typeof response.result === 'string') {
        text = response.result as string;
      } else {
        text = JSON.stringify(response.result);
      }
      Logger.info('HTTP ' + method + ' ' + url + ' -> ' + response.responseCode + ' (' + (Date.now() - startedAt) + 'ms)');

      // WebVPN / CAS 场景下接口常被重定向到登录页：这里显式识别，避免上层拿到 HTML 后再报「JSON 解析失败」。
      // 注意按状态码区分：nginx 的 502 错误页同样是 HTML，但那是上游宕机，不是登录拦截。
      if (HttpEngine.looksLikeHtml(text)) {
        Logger.warn('响应为网页而非接口数据：' + url + '，状态码 ' + response.responseCode);
        throw ApiError.fromHtmlResponse(response.responseCode, text, AppConfig.hostOf(url));
      }
      return new HttpResult(response.responseCode, text);
    } catch (error) {
      // 上面主动抛出的业务异常已经是可读结论，不能再当业务错误二次包装，
      // 否则会被拼成「……（错误码 portal_page）」这种噪音。
      if (error instanceof ApiError) {
        throw error as ApiError;
      }
      const err = error as BusinessError;
      const code: number = err.code === undefined || err.code === null ? 0 : err.code;
      Logger.error('HTTP 请求失败 ' + url + ': ' + code + ' ' + err.message + ' (' + (Date.now() - startedAt) + 'ms)');
      throw ApiError.network(HttpEngine.httpErrorHint(code, err.message), AppConfig.hostOf(url));
    } finally {
      request.destroy();
    }
  }

  /** 响应体是否为 HTML 文档。 */
  private static looksLikeHtml(text: string): boolean {
    if (text.length === 0) {
      return false;
    }
    const head = text.trimStart().toLowerCase();
    return head.startsWith('<!doctype html') || head.startsWith('<html');
  }

  /** 把 @ohos.net.http 的错误码翻译成可操作的中文提示。 */
  static httpErrorHint(code: number, raw: string): string {
    switch (code) {
      case 2300001:
        return '不支持的协议（地址需以 http:// 或 https:// 开头）';
      case 2300003:
        return '地址格式不正确';
      case 2300005:
        return '代理地址无法解析';
      case 2300006:
        return '域名解析失败，请检查地址拼写或 DNS';
      case 2300007:
        return '无法连接到服务器（端口可能写错，或被防火墙拦截）';
      case 2300008:
        return '服务器响应格式非法';
      case 2300009:
        return '访问被服务器拒绝';
      case 2300028:
        return '连接超时，服务器未响应';
      case 2300047:
        return '重定向次数过多（多为 CAS / WebVPN 登录跳转）';
      case 2300052:
        return '服务器未返回任何内容';
      case 2300055:
        return '发送数据失败';
      case 2300056:
        return '接收数据失败，连接被中断';
      case 2300058:
        return '本地 SSL 证书错误';
      case 2300060:
        return 'SSL 证书校验失败（自签名或证书链不完整）';
      case 2300077:
        return 'SSL 证书不可用';
      case 2300094:
        return '服务端认证失败';
      default:
        // 无明确错误码时不要拼出「错误码 0」这种噪音
        if (code === 0) {
          return raw !== undefined && raw.length > 0 ? raw : '网络请求失败';
        }
        return (raw !== undefined && raw.length > 0 ? raw : '网络请求失败') + '（错误码 ' + code + '）';
    }
  }

  /** 使用 refreshToken 换取新令牌。 */
  private static async doRefresh(): Promise<boolean> {
    const session: StoredSession = TokenStore.getSession();
    if (session.refreshToken.length === 0) {
      return false;
    }
    const payload: TokenRefreshRequest = { refreshToken: session.refreshToken };
    const url = HttpEngine.buildUrl(AppConfig.API_PREFIX + '/auth/refresh');
    try {
      const result = await HttpEngine.rawRequest(
        http.RequestMethod.POST,
        url,
        JSON.stringify(payload),
        false
      );
      if (!result.isOk()) {
        Logger.warn('刷新令牌失败，状态码 ' + result.status);
        TokenStore.clear();
        return false;
      }
      const refreshed = JSON.parse(result.body) as TokenRefreshResponse;
      TokenStore.updateTokens(
        refreshed.accessToken,
        refreshed.refreshToken,
        refreshed.accessTokenExpiresAt,
        refreshed.refreshTokenExpiresAt
      );
      Logger.info('访问令牌已刷新');
      return true;
    } catch (error) {
      Logger.warn('刷新令牌异常：' + (error as Error).message);
      TokenStore.clear();
      return false;
    }
  }

  /**
   * 发起请求（自动处理 401 刷新与重试）。
   *
   * @param method HTTP 方法
   * @param path 形如 /api/v1/schedule/terms 的完整路径
   * @param body 请求体（JSON 字符串）
   * @param needAuth 是否附带登录态
   */
  static async request(
    method: http.RequestMethod,
    path: string,
    body?: string,
    needAuth: boolean = true,
    query?: Map<string, string>
  ): Promise<HttpResult> {
    const result = await HttpEngine.requestRaw(method, path, body, needAuth, query);
    if (!result.isOk()) {
      throw HttpEngine.toApiError(result);
    }
    return result;
  }

  /**
   * 同 request，但不把非 2xx 转为异常。
   * 供需要读取错误响应体（如 422 验证码挑战）的调用方使用。
   */
  static async requestRaw(
    method: http.RequestMethod,
    path: string,
    body?: string,
    needAuth: boolean = true,
    query?: Map<string, string>
  ): Promise<HttpResult> {
    const url = HttpEngine.buildUrl(path, query);
    let result = await HttpEngine.rawRequest(method, url, body, needAuth);

    if (result.status === 401 && needAuth) {
      if (HttpEngine.refreshing) {
        const ok = await HttpEngine.waitForRefresh();
        if (ok) {
          result = await HttpEngine.rawRequest(method, url, body, needAuth);
        }
      } else {
        HttpEngine.refreshing = true;
        const refreshed = await HttpEngine.doRefresh();
        HttpEngine.refreshing = false;
        if (refreshed) {
          result = await HttpEngine.rawRequest(method, url, body, needAuth);
        }
      }
    }
    return result;
  }

  /** 把非 2xx 响应解析为 ApiError。 */
  static toApiError(result: HttpResult): ApiError {
    const target = AppConfig.hostOf(TokenStore.getApiBaseUrl());
    let code = 'http_' + result.status;
    let message = HttpEngine.statusHint(result.status);
    if (result.body.length > 0) {
      try {
        const parsed = JSON.parse(result.body) as ErrorResponse;
        if (parsed.error !== undefined && parsed.error !== null) {
          code = parsed.error.code;
          message = parsed.error.message;
        }
      } catch (error) {
        Logger.warn('错误响应解析失败，原文：' + result.body.substring(0, 200));
      }
    }
    if (result.status === 401) {
      return ApiError.unauthorized(target);
    }
    if (result.status === 422) {
      return new ApiError(422, 'captcha_required', message, false, target);
    }
    return new ApiError(result.status, code, message, false, target);
  }

  /** 常见 HTTP 状态码的可操作提示。 */
  static statusHint(status: number): string {
    switch (status) {
      case 400:
        return '请求参数有误（400）';
      case 404:
        return '接口不存在（404）——服务地址或端口可能不对';
      case 405:
        return '请求方法不被允许（405）——确认路径带 /api/v1 前缀且未被重定向改成 GET';
      case 502:
        return '网关错误（502）——服务端未启动或反向代理失效';
      case 503:
        return '服务不可用（503）——服务端正在重启或过载';
      case 504:
        return '网关超时（504）——服务端访问学校系统超时';
      default:
        return '请求失败（' + status + '）';
    }
  }

  /** JSON 反序列化包装，统一捕获格式异常。 */
  static decode<T>(body: string, fallback: T): T {
    try {
      return JSON.parse(body) as T;
    } catch (error) {
      Logger.error('JSON 解析失败：' + (error as Error).message);
      return fallback;
    }
  }
}
