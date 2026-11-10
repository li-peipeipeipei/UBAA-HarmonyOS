import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { AppConfig, ConnectionMode, DEFAULT_CONNECTION_MODE } from '../common/AppConfig';
import { GlobalContext } from '../common/GlobalContext';
import { Logger } from '../common/Logger';

const KEY_ACCESS_TOKEN: string = 'access_token';
const KEY_REFRESH_TOKEN: string = 'refresh_token';
const KEY_ACCESS_EXPIRES: string = 'access_token_expires_at';
const KEY_REFRESH_EXPIRES: string = 'refresh_token_expires_at';
const KEY_USER_NAME: string = 'user_name';
const KEY_USER_SCHOOL_ID: string = 'user_school_id';
const KEY_USERNAME: string = 'login_username';
const KEY_TERM_CODE: string = 'selected_term_code';
const KEY_TERM_NAME: string = 'selected_term_name';
const KEY_WEEK: string = 'selected_week';
const KEY_LOCAL_SESSION: string = 'local_auth_session';
const KEY_LOCAL_COOKIES: string = 'local_connection_cookies';
const KEY_SAVED_CREDENTIALS: string = 'saved_credentials';
const KEY_FEATURE_USAGE: string = 'feature_usage';

/**
 * 「记住密码」的混淆盐。
 *
 * ⚠️ 这是**混淆**不是加密 —— 密钥就编译在包里，任何人反编译 HAP 都能还原。
 * 它只解决「偏好设置文件里明晃晃一行明文密码」这种一望即知的问题。
 * 真正的隔离靠系统沙箱：Preferences 在应用私有目录，其他应用读不到。
 * 要更强的话应迁移到 `@kit.AssetStoreKit`（asset），接口保持这三个方法不变即可。
 */
const CREDENTIAL_SALT: string = 'UBAANext-HarmonyOS/credentials/v1';

/** 逐字符 XOR 后转 4 位十六进制，保证任意 UTF-16 字符（含中文、emoji 密码）都能往返。 */
function encodeCredential(text: string): string {
  let out = '';
  for (let i = 0; i < text.length; i++) {
    const mixed = text.charCodeAt(i) ^ CREDENTIAL_SALT.charCodeAt(i % CREDENTIAL_SALT.length);
    let hex = mixed.toString(16);
    while (hex.length < 4) {
      hex = '0' + hex;
    }
    out += hex;
  }
  return out;
}

/** 与 encodeCredential 对应；格式不对（旧数据 / 被改动）时返回空串。 */
function decodeCredential(encoded: string): string {
  let out = '';
  let index = 0;
  while (index + 4 <= encoded.length) {
    const mixed = parseInt(encoded.substring(index, index + 4), 16);
    if (isNaN(mixed)) {
      return '';
    }
    out += String.fromCharCode(mixed ^ CREDENTIAL_SALT.charCodeAt((index / 4) % CREDENTIAL_SALT.length));
    index += 4;
  }
  return out;
}

/** 本地会话（Token + 基础用户信息）。 */
export class StoredSession {
  accessToken: string = '';
  refreshToken: string = '';
  accessTokenExpiresAt: string = '';
  refreshTokenExpiresAt: string = '';
  userName: string = '';
  schoolId: string = '';
  username: string = '';

  isValid(): boolean {
    return this.refreshToken.length > 0;
  }
}

/**
 * 本地模式（客户端直连校内上游）的登录态。
 *
 * 本地模式没有 JWT —— 登录态就是上游 Cookie（见 StoredCookie），这份记录只保存
 * 「谁、什么时候登的」，用于界面展示与过期判断。
 */
export interface LocalAuthSession {
  username: string;
  userName: string;
  schoolId: string;
  authenticatedAt: string;
  lastActivity: string;
}

/**
 * 上游 Cookie。
 *
 * @ohos.net.http 不维护跨请求的 Cookie，登录态必须自己存自己带，
 * 并按连接模式隔离 —— DIRECT 与 WEBVPN 走的是不同域名，混用会互相污染。
 */
export interface StoredCookie {
  name: string;
  value: string;
  domain: string;
  path: string;
  /** 绝对过期时间（epoch 毫秒）；0 表示会话 Cookie，关闭应用即失效。 */
  expiresAt: number;
  secure: boolean;
}

/**
 * 「记住密码」保存的登录凭据。
 *
 * @property username 学号。
 * @property password 密码（内存中是明文，落盘前经 encodeCredential 混淆）。
 * @property remember 是否勾选了「记住密码」；false 时不应回填密码。
 */
export interface SavedCredentials {
  username: string;
  password: string;
  remember: boolean;
}

/**
 * 本地持久化。
 *
 * 说明：当前使用 Preferences 保存 Token；如需更高安全等级，
 * 后续可平滑迁移到 @kit.AssetStoreKit（asset）做密钥级存储。
 */
export class TokenStore {
  private static pref: preferences.Preferences | null = null;

  /** 打开本地存储；失败时返回 null，调用方走降级路径（返回默认值 / 放弃持久化）。 */
  private static store(): preferences.Preferences | null {
    if (TokenStore.pref === null) {
      try {
        const context: common.UIAbilityContext = GlobalContext.getContext();
        TokenStore.pref = preferences.getPreferencesSync(context, { name: AppConfig.PREF_STORE_NAME });
      } catch (error) {
        Logger.error('打开本地存储失败：' + (error as Error).message);
        return null;
      }
    }
    return TokenStore.pref;
  }

  private static readString(key: string, fallback: string): string {
    const store = TokenStore.store();
    if (store === null) {
      return fallback;
    }
    try {
      const value = store.getSync(key, fallback);
      if (typeof value === 'string') {
        return value as string;
      }
    } catch (error) {
      Logger.error('读取本地配置失败：' + (error as Error).message);
    }
    return fallback;
  }

  private static writeString(key: string, value: string): void {
    const store = TokenStore.store();
    if (store === null) {
      return;
    }
    try {
      store.putSync(key, value);
    } catch (error) {
      Logger.error('写入本地配置失败：' + (error as Error).message);
    }
  }

  /* ------------------------- 会话 ------------------------- */

  static getSession(): StoredSession {
    const session = new StoredSession();
    session.accessToken = TokenStore.readString(KEY_ACCESS_TOKEN, '');
    session.refreshToken = TokenStore.readString(KEY_REFRESH_TOKEN, '');
    session.accessTokenExpiresAt = TokenStore.readString(KEY_ACCESS_EXPIRES, '');
    session.refreshTokenExpiresAt = TokenStore.readString(KEY_REFRESH_EXPIRES, '');
    session.userName = TokenStore.readString(KEY_USER_NAME, '');
    session.schoolId = TokenStore.readString(KEY_USER_SCHOOL_ID, '');
    session.username = TokenStore.readString(KEY_USERNAME, '');
    return session;
  }

  static saveSession(session: StoredSession): void {
    TokenStore.writeString(KEY_ACCESS_TOKEN, session.accessToken);
    TokenStore.writeString(KEY_REFRESH_TOKEN, session.refreshToken);
    TokenStore.writeString(KEY_ACCESS_EXPIRES, session.accessTokenExpiresAt);
    TokenStore.writeString(KEY_REFRESH_EXPIRES, session.refreshTokenExpiresAt);
    TokenStore.writeString(KEY_USER_NAME, session.userName);
    TokenStore.writeString(KEY_USER_SCHOOL_ID, session.schoolId);
    TokenStore.writeString(KEY_USERNAME, session.username);
    TokenStore.flush();
  }

  /** 仅更新令牌，保留用户信息。 */
  static updateTokens(
    accessToken: string,
    refreshToken: string,
    accessExpiresAt: string,
    refreshExpiresAt: string
  ): void {
    TokenStore.writeString(KEY_ACCESS_TOKEN, accessToken);
    TokenStore.writeString(KEY_REFRESH_TOKEN, refreshToken);
    TokenStore.writeString(KEY_ACCESS_EXPIRES, accessExpiresAt);
    TokenStore.writeString(KEY_REFRESH_EXPIRES, refreshExpiresAt);
    TokenStore.flush();
  }

  static clear(): void {
    TokenStore.writeString(KEY_ACCESS_TOKEN, '');
    TokenStore.writeString(KEY_REFRESH_TOKEN, '');
    TokenStore.writeString(KEY_ACCESS_EXPIRES, '');
    TokenStore.writeString(KEY_REFRESH_EXPIRES, '');
    TokenStore.writeString(KEY_USER_NAME, '');
    TokenStore.writeString(KEY_USER_SCHOOL_ID, '');
    TokenStore.writeString(KEY_USERNAME, '');
    TokenStore.flush();
  }

  /* ------------------------- 记住密码 ------------------------- */

  /**
   * 读取「记住密码」保存的凭据。
   *
   * 未保存、勾选已取消或数据格式异常时一律返回空值，调用方不必再判 null。
   */
  static getSavedCredentials(): SavedCredentials {
    const empty: SavedCredentials = { username: '', password: '', remember: false };
    const raw = TokenStore.readString(KEY_SAVED_CREDENTIALS, '');
    if (raw.length === 0) {
      return empty;
    }
    try {
      const parsed = JSON.parse(raw) as SavedCredentials;
      if (parsed === null || parsed === undefined) {
        return empty;
      }
      const encoded = parsed.password === undefined || parsed.password === null ? '' : parsed.password;
      return {
        username: parsed.username === undefined || parsed.username === null ? '' : parsed.username,
        password: decodeCredential(encoded),
        remember: parsed.remember === true
      };
    } catch (error) {
      Logger.warn('记住密码的数据无法解析，按未保存处理：' + (error as Error).message);
      return empty;
    }
  }

  /** 保存凭据（用户勾选「记住密码」并在登录成功后调用）。 */
  static saveCredentials(username: string, password: string): void {
    const payload: SavedCredentials = {
      username: username,
      password: encodeCredential(password),
      remember: true
    };
    TokenStore.writeString(KEY_SAVED_CREDENTIALS, JSON.stringify(payload));
    TokenStore.flush();
  }

  /** 清掉保存的凭据（取消勾选「记住密码」时调用）。 */
  static clearSavedCredentials(): void {
    TokenStore.writeString(KEY_SAVED_CREDENTIALS, '');
    TokenStore.flush();
  }

  /* ------------------------- 功能使用统计 ------------------------- */

  /**
   * 各功能入口被点开的次数（键是功能标题）。
   *
   * 首页「快捷入口」按它降序排 —— 常用的自然浮到前面，没用过的保持默认顺序。
   * 数据格式异常时按「没有记录」处理，不影响页面。
   */
  static getFeatureUsage(): Record<string, number> {
    const raw = TokenStore.readString(KEY_FEATURE_USAGE, '');
    if (raw.length === 0) {
      return {};
    }
    try {
      const parsed = JSON.parse(raw) as Record<string, number>;
      return parsed === null ? {} : parsed;
    } catch (error) {
      Logger.warn('功能使用统计解析失败，按空处理：' + (error as Error).message);
      return {};
    }
  }

  /** 记一次功能使用（点开磁贴时调用）。 */
  static recordFeatureUse(title: string): void {
    if (title.length === 0) {
      return;
    }
    const usage: Record<string, number> = TokenStore.getFeatureUsage();
    const current: number | undefined = usage[title];
    usage[title] = (current === undefined || current === null ? 0 : current) + 1;
    TokenStore.writeString(KEY_FEATURE_USAGE, JSON.stringify(usage));
    TokenStore.flush();
  }

  /* ------------------------- 设备标识 ------------------------- */

  /** 获取（或首次生成）客户端唯一标识，用于服务端 preload 会话绑定。 */
  static getOrCreateClientId(): string {
    let clientId = TokenStore.readString(AppConfig.PREF_CLIENT_ID, '');
    if (clientId.length === 0) {
      clientId = 'harmony-' + Date.now().toString(36) + '-' + Math.floor(Math.random() * 1e9).toString(36);
      TokenStore.writeString(AppConfig.PREF_CLIENT_ID, clientId);
      TokenStore.flush();
    }
    return clientId;
  }

  /* ------------------------- 连接配置 ------------------------- */

  /**
   * 读取指定模式的服务地址；未指定模式时取当前模式。
   *
   * 回退顺序：该模式自定义值 -> 旧版全局值（仅 DIRECT 兼容）-> 该模式出厂默认值。
   * 每个模式各存一份，切换模式不会互相覆盖。
   */
  static getApiBaseUrl(mode?: ConnectionMode): string {
    const target: ConnectionMode = mode === undefined ? TokenStore.getConnectionMode() : mode;
    const scoped = TokenStore.readString(AppConfig.baseUrlKey(target), '');
    if (scoped.length > 0) {
      return scoped;
    }
    if (target === ConnectionMode.DIRECT) {
      const legacy = TokenStore.readString(AppConfig.PREF_API_BASE_URL, '');
      if (legacy.length > 0) {
        return legacy;
      }
    }
    return AppConfig.defaultBaseUrl(target);
  }

  static setApiBaseUrl(url: string, mode?: ConnectionMode): void {
    const target: ConnectionMode = mode === undefined ? TokenStore.getConnectionMode() : mode;
    TokenStore.writeString(AppConfig.baseUrlKey(target), url);
    if (target === ConnectionMode.DIRECT) {
      // 同步旧键，便于老版本数据继续生效
      TokenStore.writeString(AppConfig.PREF_API_BASE_URL, url);
    }
    TokenStore.flush();
  }

  static getConnectionMode(): ConnectionMode {
    const value = TokenStore.readString(AppConfig.PREF_CONNECTION_MODE, DEFAULT_CONNECTION_MODE);
    if (value === ConnectionMode.WEBVPN) {
      return ConnectionMode.WEBVPN;
    }
    return ConnectionMode.DIRECT;
  }

  static setConnectionMode(mode: ConnectionMode): void {
    TokenStore.writeString(AppConfig.PREF_CONNECTION_MODE, mode);
    TokenStore.flush();
  }

  /* ------------------------- 演示模式 ------------------------- */

  /** 演示模式：所有 API 调用改为返回本地示例数据，不发起网络请求。 */
  static getDemoMode(): boolean {
    return TokenStore.readString(AppConfig.PREF_DEMO_MODE, '0') === '1';
  }

  static setDemoMode(enabled: boolean): void {
    TokenStore.writeString(AppConfig.PREF_DEMO_MODE, enabled ? '1' : '0');
    TokenStore.flush();
  }

  /* ------------------------- 课表偏好 ------------------------- */

  static getSelectedTerm(): string[] {
    return [
      TokenStore.readString(KEY_TERM_CODE, ''),
      TokenStore.readString(KEY_TERM_NAME, '')
    ];
  }

  static setSelectedTerm(code: string, name: string): void {
    TokenStore.writeString(KEY_TERM_CODE, code);
    TokenStore.writeString(KEY_TERM_NAME, name);
    TokenStore.flush();
  }

  static getSelectedWeek(): number {
    const store = TokenStore.store();
    if (store === null) {
      return 0;
    }
    try {
      const value = store.getSync(KEY_WEEK, 0);
      if (typeof value === 'number') {
        return value as number;
      }
    } catch (error) {
      Logger.error('读取周次失败：' + (error as Error).message);
    }
    return 0;
  }

  static setSelectedWeek(week: number): void {
    const store = TokenStore.store();
    if (store === null) {
      return;
    }
    try {
      store.putSync(KEY_WEEK, week);
    } catch (error) {
      Logger.error('写入周次失败：' + (error as Error).message);
      return;
    }
    TokenStore.flush();
  }

  /* ------------------- 本地模式会话（客户端直连校内上游） ------------------- */

  /**
   * 生成按模式隔离的键：`<前缀>_DIRECT` / `<前缀>_WEBVPN`。
   *
   * 两种模式访问的是不同域名（直连 sso.buaa.edu.cn / 经 d.buaa.edu.cn 转发），
   * 各自的 Cookie 互不通用，混存会导致切换模式后带着上一个模式的无效 Cookie。
   */
  static modeScopedKey(prefix: string, mode: ConnectionMode): string {
    return prefix + '_' + mode;
  }

  static getLocalSession(mode?: ConnectionMode): LocalAuthSession | null {
    const target: ConnectionMode = mode === undefined ? TokenStore.getConnectionMode() : mode;
    const raw = TokenStore.readString(TokenStore.modeScopedKey(KEY_LOCAL_SESSION, target), '');
    if (raw.length === 0) {
      return null;
    }
    try {
      return JSON.parse(raw) as LocalAuthSession;
    } catch (error) {
      Logger.error('本地会话解析失败：' + (error as Error).message);
      return null;
    }
  }

  static saveLocalSession(session: LocalAuthSession, mode?: ConnectionMode): void {
    const target: ConnectionMode = mode === undefined ? TokenStore.getConnectionMode() : mode;
    TokenStore.writeString(TokenStore.modeScopedKey(KEY_LOCAL_SESSION, target), JSON.stringify(session));
    TokenStore.flush();
  }

  static hasLocalSession(mode?: ConnectionMode): boolean {
    return TokenStore.getLocalSession(mode) !== null;
  }

  static clearLocalSession(mode?: ConnectionMode): void {
    const target: ConnectionMode = mode === undefined ? TokenStore.getConnectionMode() : mode;
    TokenStore.writeString(TokenStore.modeScopedKey(KEY_LOCAL_SESSION, target), '');
    TokenStore.writeString(TokenStore.modeScopedKey(KEY_LOCAL_COOKIES, target), '');
    TokenStore.flush();
  }

  /** 清掉两种模式的本地会话（退出登录 / 凭据失效时用）。 */
  static clearAllLocalSessions(): void {
    TokenStore.clearLocalSession(ConnectionMode.DIRECT);
    TokenStore.clearLocalSession(ConnectionMode.WEBVPN);
  }

  static loadCookies(mode?: ConnectionMode): StoredCookie[] {
    const target: ConnectionMode = mode === undefined ? TokenStore.getConnectionMode() : mode;
    const raw = TokenStore.readString(TokenStore.modeScopedKey(KEY_LOCAL_COOKIES, target), '');
    if (raw.length === 0) {
      return [];
    }
    try {
      const parsed = JSON.parse(raw) as StoredCookie[];
      return parsed === null ? [] : parsed;
    } catch (error) {
      Logger.error('Cookie 解析失败：' + (error as Error).message);
      return [];
    }
  }

  static saveCookies(cookies: StoredCookie[], mode?: ConnectionMode): void {
    const target: ConnectionMode = mode === undefined ? TokenStore.getConnectionMode() : mode;
    const key = TokenStore.modeScopedKey(KEY_LOCAL_COOKIES, target);
    TokenStore.writeString(key, cookies.length > 0 ? JSON.stringify(cookies) : '');
    TokenStore.flush();
  }

  static clearCookies(mode?: ConnectionMode): void {
    TokenStore.saveCookies([], mode);
  }

  private static flush(): void {
    const store = TokenStore.store();
    if (store === null) {
      return;
    }
    store.flush().catch((error: Error) => {
      Logger.error('持久化写入失败: ' + error.message);
    });
  }
}
