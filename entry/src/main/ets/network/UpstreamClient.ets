import { BusinessError } from '@kit.BasicServicesKit';
import { rcp } from '@kit.RemoteCommunicationKit';
import { AppConfig, ConnectionMode } from '../common/AppConfig';
import { Logger } from '../common/Logger';
import { ApiError } from './ApiError';
import { HttpEngine } from './HttpEngine';
import { LocalWebVpn } from './LocalWebVpn';
import { StoredCookie, TokenStore } from './TokenStore';

/** 上游响应。 */
export class UpstreamResponse {
  status: number = 0;
  body: string = '';
  /** 实际请求到的地址（WebVPN 模式下是网关地址，不是传入的逻辑地址）。 */
  url: string = '';
  /** 3xx 的 Location 头（相对路径原样保留）。 */
  location: string = '';
  /** 二进制响应体（验证码图片）。 */
  bytes: Uint8Array | null = null;

  isRedirect(): boolean {
    return this.status >= 300 && this.status < 400 && this.location.length > 0;
  }

  isOk(): boolean {
    return this.status >= 200 && this.status < 300;
  }
}

/** 单次请求参数。 */
class SendOptions {
  body: string = '';
  contentType: string = '';
  accept: string = 'application/json, text/javascript, */*; q=0.01';
  /** 是否自动跟随重定向。CAS 流程必须为 false，要逐跳读取 Location 与 Cookie。 */
  followRedirects: boolean = true;
  /** 期望二进制响应（验证码图片）。 */
  binary: boolean = false;
  extraHeaders: Record<string, string> = {};
  /**
   * 二进制请求体（手工拼好的 multipart 用）。
   *
   * 设了它就**不再看 `body`**；`contentType` 仍需调用方自己带上 boundary。
   * 见 `postRaw()` 的说明。
   */
  rawBody: ArrayBuffer | null = null;
}

/** 日期类英文缩写 —— 用来区分「多个 Set-Cookie 的逗号」与「Expires 里的逗号」。 */
const DATE_TOKENS: string[] = [
  'mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun',
  'jan', 'feb', 'mar', 'apr', 'may', 'jun', 'jul', 'aug', 'sep', 'oct', 'nov', 'dec'
];

const COOKIE_START_RE = new RegExp('^\\s*([A-Za-z0-9_\\-\\.%]+)\\s*=');

function looksLikeCookieStart(text: string): boolean {
  const matched = COOKIE_START_RE.exec(text);
  if (matched === null) {
    return false;
  }
  return DATE_TOKENS.indexOf(matched[1].toLowerCase()) < 0;
}

/**
 * 拆分 `Set-Cookie` 串。
 *
 * 多个 Set-Cookie 可能被合并成一行并用 `, ` 连接，但 `Expires=Wed, 21 Oct ...`
 * 里也有逗号，因此只有「逗号后面紧跟 name=value」时才算分隔符。
 */
function splitSetCookie(raw: string): string[] {
  const out: string[] = [];
  let current = '';
  for (let i = 0; i < raw.length; i++) {
    const ch = raw.charAt(i);
    if (ch === ',') {
      if (looksLikeCookieStart(raw.substring(i + 1))) {
        if (current.trim().length > 0) {
          out.push(current.trim());
        }
        current = '';
        continue;
      }
    }
    current += ch;
  }
  if (current.trim().length > 0) {
    out.push(current.trim());
  }
  return out;
}

function hostOfUrl(raw: string): string {
  const schemeIndex = raw.indexOf('://');
  if (schemeIndex < 0) {
    return '';
  }
  let rest = raw.substring(schemeIndex + 3);
  const slashIndex = rest.indexOf('/');
  if (slashIndex >= 0) {
    rest = rest.substring(0, slashIndex);
  }
  const colonIndex = rest.lastIndexOf(':');
  const host = colonIndex > 0 ? rest.substring(0, colonIndex) : rest;
  return host.toLowerCase();
}

function pathOfUrl(raw: string): string {
  const schemeIndex = raw.indexOf('://');
  if (schemeIndex < 0) {
    return '/';
  }
  const rest = raw.substring(schemeIndex + 3);
  const slashIndex = rest.indexOf('/');
  if (slashIndex < 0) {
    return '/';
  }
  const pathAndQuery = rest.substring(slashIndex);
  const queryIndex = pathAndQuery.indexOf('?');
  const hashIndex = pathAndQuery.indexOf('#');
  let end = pathAndQuery.length;
  if (queryIndex >= 0 && queryIndex < end) {
    end = queryIndex;
  }
  if (hashIndex >= 0 && hashIndex < end) {
    end = hashIndex;
  }
  const path = pathAndQuery.substring(0, end);
  return path.length > 0 ? path : '/';
}

/** 把相对 Location 补成绝对地址。 */
export function resolveLocation(currentUrl: string, location: string): string {
  if (location.startsWith('http://') || location.startsWith('https://')) {
    return location;
  }
  const schemeIndex = currentUrl.indexOf('://');
  if (schemeIndex < 0) {
    return location;
  }
  const scheme = currentUrl.substring(0, schemeIndex);
  let rest = currentUrl.substring(schemeIndex + 3);
  const slashIndex = rest.indexOf('/');
  const authority = slashIndex >= 0 ? rest.substring(0, slashIndex) : rest;

  if (location.startsWith('//')) {
    return scheme + ':' + location;
  }
  if (location.startsWith('/')) {
    return scheme + '://' + authority + location;
  }
  const pathAndQuery = slashIndex >= 0 ? rest.substring(slashIndex) : '/';
  const queryIndex = pathAndQuery.indexOf('?');
  const path = queryIndex >= 0 ? pathAndQuery.substring(0, queryIndex) : pathAndQuery;
  const lastSlash = path.lastIndexOf('/');
  const basePath = lastSlash >= 0 ? path.substring(0, lastSlash + 1) : '/';
  return scheme + '://' + authority + basePath + location;
}

/** 去掉查询串（密码过期中间页要求 POST 回不带参数的原地址）。 */
export function stripQuery(url: string): string {
  const index = url.indexOf('?');
  return index >= 0 ? url.substring(0, index) : url;
}

/**
 * 校内上游 HTTP 客户端（本地模式专用）。
 *
 * ## 为什么不用 `@ohos.net.http`
 *
 * 最初这里用的是 `@ohos.net.http` + `maxRedirects: 0`，以为 0 表示「不跟随重定向」。
 * 实测下来（设备日志 `NETSTACK: [http_exec.cpp:741] CURLcode result 47`）它在底层
 * 直接映射到 libcurl 的 `CURLOPT_MAXREDIRS = 0`：**FOLLOWLOCATION 仍然是开的，
 * 于是只要服务端回一个 3xx 就立刻抛 2300047（重定向次数达到最大值）**。
 * 结果是根本拿不到 302 本身，而 CAS 登录的正确性恰恰全在跳转链上
 * （哪一跳的 Location、哪一跳下发了 Cookie），登录必崩。
 *
 * 改用 Remote Communication Kit（RCP）：它的 `transfer.autoRedirect` 是真正的
 * 开关，关掉之后 3xx 会作为普通响应返回，`headers.location` 能读到跳转目标，
 * 还能逐跳收下 `response.cookies`。
 *
 * ## 另外两件事也必须自己做
 *
 * 1. **Cookie 必须自己管**：RCP 不会跨请求维护 Cookie 罐，而登录态就是 Cookie；
 * 2. **模式改写统一收口**：所有地址都要按当前连接模式翻译（见 LocalWebVpn.rewrite）。
 */
export class UpstreamClient {
  /** 发起请求。logicalUrl 必须是「校内原始地址」，模式改写在这里统一完成。 */
  private static async send(
    method: string,
    logicalUrl: string,
    options: SendOptions
  ): Promise<UpstreamResponse> {
    const mode = TokenStore.getConnectionMode();
    const url = await LocalWebVpn.rewrite(logicalUrl, mode);

    const headers: rcp.RequestHeaders = {};
    headers['accept'] = options.accept;
    headers['user-agent'] = UpstreamClient.userAgent();
    headers['accept-language'] = 'zh-CN,zh;q=0.9';
    if (options.contentType.length > 0) {
      headers['content-type'] = options.contentType;
    }
    const extraKeys = Object.keys(options.extraHeaders);
    for (let i = 0; i < extraKeys.length; i++) {
      headers[extraKeys[i].toLowerCase()] = options.extraHeaders[extraKeys[i]];
    }
    const cookieHeader = UpstreamClient.cookieHeaderFor(url, mode);
    if (cookieHeader.length > 0) {
      headers['cookie'] = cookieHeader;
    }

    const transfer: rcp.TransferConfiguration = {
      // 关键：关掉自动重定向，让 3xx 作为普通响应返回给调用方
      autoRedirect: options.followRedirects,
      timeout: {
        connectMs: AppConfig.CONNECT_TIMEOUT,
        transferMs: AppConfig.READ_TIMEOUT
      }
    };
    const sessionConfig: rcp.SessionConfiguration = {
      requestConfiguration: { transfer: transfer }
    };
    // 一次请求一个会话：会话级配置是固定的，而每次请求的 Cookie / 头都不同
    const session = rcp.createSession(sessionConfig);

    const startedAt = Date.now();
    try {
      const request = options.rawBody !== null
        ? new rcp.Request(url, method, headers, options.rawBody)
        : new rcp.Request(url, method, headers, options.body.length > 0 ? options.body : undefined);
      const response = await session.fetch(request);

      const result = new UpstreamResponse();
      result.status = response.statusCode;
      result.url = url;

      const location = UpstreamClient.headerValue(response.headers, 'location');
      if (location.length > 0) {
        result.location = location;
      }

      if (options.binary) {
        const buffer = response.body;
        if (buffer !== undefined && buffer !== null && buffer.byteLength > 0) {
          result.bytes = new Uint8Array(buffer);
        }
      } else {
        const text = response.toString();
        result.body = text === null || text === undefined ? '' : text;
      }

      UpstreamClient.absorbCookies(response, url, mode);

      Logger.info('上游 ' + method + ' ' + url + ' -> ' + result.status +
        (result.location.length > 0 ? ' → ' + result.location : '') +
        ' (' + (Date.now() - startedAt) + 'ms)');
      return result;
    } catch (error) {
      const err = error as BusinessError;
      const code: number = err.code === undefined || err.code === null ? 0 : err.code;
      const message = err.message === undefined ? '' : err.message;
      Logger.error('上游请求失败 ' + method + ' ' + url + '：' + code + ' ' + message);
      throw ApiError.network(HttpEngine.httpErrorHint(code, message), hostOfUrl(url));
    } finally {
      session.close();
    }
  }

  private static userAgent(): string {
    return 'Mozilla/5.0 (Linux; HarmonyOS) AppleWebKit/537.36 UBAA-Harmony/' + AppConfig.APP_VERSION;
  }

  /** 读取响应头（键名大小写不固定，值可能是 string 或 string[]）。 */
  private static headerValue(headers: rcp.ResponseHeaders, name: string): string {
    const keys = Object.keys(headers);
    for (let i = 0; i < keys.length; i++) {
      if (keys[i].toLowerCase() !== name) {
        continue;
      }
      const value: string | string[] | undefined = headers[keys[i]];
      if (typeof value === 'string') {
        return value;
      }
      if (value !== undefined && value !== null && value.length > 0) {
        return value[0];
      }
    }
    return '';
  }

  /** 把响应里的 Cookie 并入当前模式的 Cookie 罐。 */
  private static absorbCookies(response: rcp.Response, url: string, mode: ConnectionMode): void {
    const host = hostOfUrl(url);
    if (host.length === 0) {
      return;
    }
    const jar = TokenStore.loadCookies(mode);
    const requestPath = pathOfUrl(url);
    let changed = false;

    // 首选 RCP 结构化解析好的 cookie（属性齐全，不用自己拆 Set-Cookie）
    const cookies = response.cookies;
    if (cookies !== undefined && cookies !== null && cookies.length > 0) {
      for (let i = 0; i < cookies.length; i++) {
        if (UpstreamClient.putResponseCookie(jar, cookies[i], host, requestPath)) {
          changed = true;
        }
      }
    }

    // 兜底：结构化字段缺失时，退回解析 Set-Cookie 头
    const rawSetCookie = UpstreamClient.headerValue(response.headers, 'set-cookie');
    if (rawSetCookie.length > 0) {
      const parts = splitSetCookie(rawSetCookie);
      for (let i = 0; i < parts.length; i++) {
        UpstreamClient.upsertCookie(jar, parts[i], host, requestPath);
        changed = true;
      }
    }

    if (changed) {
      TokenStore.saveCookies(UpstreamClient.prune(jar), mode);
    }
  }

  /** 写入一条 RCP 解析出的 cookie。返回是否产生了改动。 */
  private static putResponseCookie(
    jar: StoredCookie[],
    cookie: rcp.ResponseCookie,
    host: string,
    requestPath: string
  ): boolean {
    const name = cookie.name === undefined ? '' : cookie.name;
    if (name.length === 0) {
      return false;
    }
    const value = cookie.value === undefined ? '' : cookie.value;

    let domain = cookie.domain === undefined ? '' : cookie.domain;
    if (domain.length === 0) {
      domain = host;
    }
    domain = domain.replace(/^\./, '').toLowerCase();

    const cookiePath = cookie.path === undefined || cookie.path.length === 0 ? requestPath : cookie.path;
    const secure = cookie.isSecure === true;

    let expiresAt = 0;
    let remove = false;
    const maxAge = cookie.maxAge;
    if (maxAge !== undefined && maxAge !== null) {
      if (maxAge <= 0) {
        remove = true;
      } else {
        expiresAt = Date.now() + maxAge * 1000;
      }
    } else if (cookie.expires !== undefined && cookie.expires.length > 0) {
      const parsed = Date.parse(cookie.expires);
      if (!isNaN(parsed)) {
        expiresAt = parsed;
      }
    }

    UpstreamClient.putCookie(jar, name, value, domain, cookiePath, expiresAt, secure, remove);
    return true;
  }

  /** 解析一条 Set-Cookie 串并写入罐中（同名同域同路径覆盖）。 */
  private static upsertCookie(jar: StoredCookie[], setCookie: string, host: string, requestPath: string): void {
    const segments = setCookie.split(';');
    if (segments.length === 0) {
      return;
    }
    const pair = segments[0];
    const eq = pair.indexOf('=');
    if (eq <= 0) {
      return;
    }
    const name = pair.substring(0, eq).trim();
    const value = pair.substring(eq + 1).trim();
    if (name.length === 0) {
      return;
    }

    let domain = host;
    let path = requestPath.length > 0 ? requestPath : '/';
    let expiresAt = 0;
    let secure = false;
    let maxAge = -1;
    let hasExpires = false;

    for (let i = 1; i < segments.length; i++) {
      const segment = segments[i];
      const index = segment.indexOf('=');
      const key = (index >= 0 ? segment.substring(0, index) : segment).trim().toLowerCase();
      const attrValue = index >= 0 ? segment.substring(index + 1).trim() : '';
      if (key === 'domain' && attrValue.length > 0) {
        domain = attrValue.replace(/^\./, '').toLowerCase();
      } else if (key === 'path' && attrValue.length > 0) {
        path = attrValue;
      } else if (key === 'secure') {
        secure = true;
      } else if (key === 'max-age') {
        const parsed = parseInt(attrValue, 10);
        if (!isNaN(parsed)) {
          maxAge = parsed;
        }
      } else if (key === 'expires') {
        const parsed = Date.parse(attrValue);
        if (!isNaN(parsed)) {
          expiresAt = parsed;
          hasExpires = true;
        }
      }
    }

    // Max-Age 优先于 Expires
    let remove = false;
    if (maxAge >= 0) {
      if (maxAge === 0) {
        remove = true;
      } else {
        expiresAt = Date.now() + maxAge * 1000;
      }
    } else if (!hasExpires) {
      expiresAt = 0;
    }

    UpstreamClient.putCookie(jar, name, value, domain, path, expiresAt, secure, remove);
  }

  /** 按「域名|路径|名字」覆盖写一条 Cookie；remove 为真时只删除不写入。 */
  private static putCookie(
    jar: StoredCookie[],
    name: string,
    value: string,
    domain: string,
    path: string,
    expiresAt: number,
    secure: boolean,
    remove: boolean
  ): void {
    const key = domain + '|' + path + '|' + name;
    for (let i = jar.length - 1; i >= 0; i--) {
      if (jar[i].domain + '|' + jar[i].path + '|' + jar[i].name === key) {
        jar.splice(i, 1);
      }
    }
    // Max-Age=0 / 已过期表示删除，覆盖后不再写入
    if (remove) {
      return;
    }
    jar.push({
      name: name,
      value: value,
      domain: domain,
      path: path,
      expiresAt: expiresAt,
      secure: secure
    });
  }

  /** 丢弃已过期的 Cookie。 */
  private static prune(jar: StoredCookie[]): StoredCookie[] {
    const now = Date.now();
    const alive: StoredCookie[] = [];
    for (let i = 0; i < jar.length; i++) {
      if (jar[i].expiresAt > 0 && jar[i].expiresAt <= now) {
        continue;
      }
      alive.push(jar[i]);
    }
    return alive;
  }

  /** 组装某个地址该带的 Cookie 头。 */
  private static cookieHeaderFor(url: string, mode: ConnectionMode): string {
    const host = hostOfUrl(url);
    const path = pathOfUrl(url);
    const jar = UpstreamClient.prune(TokenStore.loadCookies(mode));
    const parts: string[] = [];
    for (let i = 0; i < jar.length; i++) {
      const cookie = jar[i];
      if (!UpstreamClient.domainMatches(host, cookie.domain)) {
        continue;
      }
      if (!UpstreamClient.pathMatches(path, cookie.path)) {
        continue;
      }
      if (cookie.secure && !url.startsWith('https://')) {
        continue;
      }
      parts.push(cookie.name + '=' + cookie.value);
    }
    return parts.join('; ');
  }

  private static domainMatches(host: string, domain: string): boolean {
    const normalizedHost = host.toLowerCase();
    const normalizedDomain = domain.replace(/^\./, '').toLowerCase();
    if (normalizedDomain.length === 0) {
      return false;
    }
    return normalizedHost === normalizedDomain || normalizedHost.endsWith('.' + normalizedDomain);
  }

  private static pathMatches(requestPath: string, cookiePath: string): boolean {
    const target = requestPath.length > 0 ? requestPath : '/';
    const prefix = cookiePath.length > 0 ? cookiePath : '/';
    return target === prefix || target.startsWith(prefix.endsWith('/') ? prefix : prefix + '/');
  }

  /* ------------------------------ 对外接口 ------------------------------ */

  static async get(
    logicalUrl: string,
    followRedirects: boolean = true,
    extraHeaders?: Record<string, string>
  ): Promise<UpstreamResponse> {
    const options = new SendOptions();
    options.followRedirects = followRedirects;
    if (extraHeaders !== undefined) {
      options.extraHeaders = extraHeaders;
    }
    return await UpstreamClient.send('GET', logicalUrl, options);
  }

  static async getBinary(logicalUrl: string, followRedirects: boolean = true): Promise<UpstreamResponse> {
    const options = new SendOptions();
    options.followRedirects = followRedirects;
    options.binary = true;
    return await UpstreamClient.send('GET', logicalUrl, options);
  }

  static async postForm(
    logicalUrl: string,
    body: string,
    followRedirects: boolean = true,
    extraHeaders?: Record<string, string>
  ): Promise<UpstreamResponse> {
    const options = new SendOptions();
    options.followRedirects = followRedirects;
    options.body = body;
    options.contentType = 'application/x-www-form-urlencoded; charset=UTF-8';
    if (extraHeaders !== undefined) {
      options.extraHeaders = extraHeaders;
    }
    return await UpstreamClient.send('POST', logicalUrl, options);
  }

  /**
   * 发**二进制请求体**（目前只有阳光打卡的图片上传用）。
   *
   * 为什么不用 RCP 自带的 `rcp.MultipartForm`：它的字段类型是
   * `Record<string, FormFieldValue | FormFieldFileValue>` 这种联合，ArkTS 里写这种字面量
   * 很容易被编译器挑刺；而 multipart 本身的格式极简单，自己拼成 `ArrayBuffer` 送进来最稳
   * （`rcp.RawDataContent` 就接受 `ArrayBuffer`）。
   *
   * ⚠️ `contentType` **必须自带 boundary**（形如 `multipart/form-data; boundary=xxx`），
   * RCP 不会替你补；缺了 boundary 上游一定解析失败。
   */
  static async postRaw(
    logicalUrl: string,
    body: ArrayBuffer,
    contentType: string,
    followRedirects: boolean = true,
    extraHeaders?: Record<string, string>
  ): Promise<UpstreamResponse> {
    const options = new SendOptions();
    options.followRedirects = followRedirects;
    options.rawBody = body;
    options.contentType = contentType;
    if (extraHeaders !== undefined) {
      options.extraHeaders = extraHeaders;
    }
    return await UpstreamClient.send('POST', logicalUrl, options);
  }

  /**
   * 发 JSON 请求体（SPOC 的接口要求 `application/json`，不是表单）。
   *
   * 默认不跟随重定向：SPOC 的登录跳转链要靠调用方逐跳读 `Location` 抓 token。
   */
  static async postJson(
    logicalUrl: string,
    body: string,
    followRedirects: boolean = false,
    extraHeaders?: Record<string, string>
  ): Promise<UpstreamResponse> {
    const options = new SendOptions();
    options.followRedirects = followRedirects;
    options.body = body;
    options.contentType = 'application/json; charset=UTF-8';
    if (extraHeaders !== undefined) {
      options.extraHeaders = extraHeaders;
    }
    return await UpstreamClient.send('POST', logicalUrl, options);
  }

  /**
   * 逐跳跟随重定向，返回最后一跳的响应。
   *
   * 为什么不用 RCP 的自动重定向：它只认第一次请求挂上的 Cookie，中间跳转不会
   * 按目标域名重新组装 Cookie 头。而 CAS 的链路恰恰在 sso / uc / byxt / app
   * 之间来回跳 —— 缺任何一跳的 Cookie，那一步就白跳。手动跟随每一跳都走
   * `send()`，才会各自带上正确的 Cookie 并收下新下发的 Cookie。
   *
   * 典型用途：用已有的 SSO 会话去「换取」某个子系统（教务、成绩、教室）的会话。
   */
  static async follow(
    logicalUrl: string,
    extraHeaders?: Record<string, string>
  ): Promise<UpstreamResponse> {
    let current = await UpstreamClient.get(logicalUrl, false, extraHeaders);
    let hops = 0;
    while (current.isRedirect() && hops < UpstreamClient.MAX_REDIRECT_HOPS) {
      hops++;
      const resolved: string = resolveLocation(current.url, current.location);
      // ⚠️ **必须「解包 → HSTS 升级」再交给 `get`**（`get` 会做一次 WebVPN 包装）：
      //   1. 网关返回的 Location 是**网关地址**（主机名加密），
      //      不解包直接再包装 = 双重包装 → 地址错乱 → 请求打不到目标；
      //   2. SSO 开了 HSTS，原生客户端必须自己把 http 升成 https。
      // 与 `LocalAuthService.followAndCheck` 同一套处理。
      const unwrapped: string = await LocalWebVpn.fromWebVpnUrl(resolved);
      const secured: string = LocalWebVpn.secureCasTransportUrl(unwrapped);
      current = await UpstreamClient.get(secured, false, extraHeaders);
    }
    return current;
  }

  /** 单条重定向链的最大跳数；正常换取会话不超过 5 跳。 */
  private static readonly MAX_REDIRECT_HOPS: number = 10;

  /** 该地址在 WebVPN 模式下的实际请求地址（诊断页展示用）。 */
  static async describe(logicalUrl: string): Promise<string> {
    return await LocalWebVpn.rewrite(logicalUrl, TokenStore.getConnectionMode());
  }
}
