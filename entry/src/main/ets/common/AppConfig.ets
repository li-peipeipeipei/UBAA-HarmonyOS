/**
 * 全局配置。
 *
 * ## 架构现状（重要）
 *
 * UBAA 原本有三条链路，其中 SERVER_RELAY（自建 Ktor 服务端代抓 CAS 并签发 JWT）
 * **已停止部署**。因此本项目不再有「服务地址」可配 —— 登录与取数全部由客户端
 * 直接对接校内上游：
 *
 * ```
 *  DIRECT ：https://sso.buaa.edu.cn、https://uc.buaa.edu.cn …（需校园网）
 *  WEBVPN ：同样的上游，但经 https://d.buaa.edu.cn 加密转发（校外可用）
 * ```
 *
 * 两种模式访问的是同一批上游，区别只在地址是否经过网关改写（见 LocalWebVpn）。
 * 历史遗留的 `/api/v1/*` 常量与 TokenStore 里的服务地址读写保留着，供中转模式
 * 万一恢复时复用，但登录链路已不再依赖它们。
 */
export class AppConfig {
  /** WebVPN 网关域名（校外访问时的唯一入口）。 */
  static readonly WEBVPN_GATEWAY_HOST: string = 'd.buaa.edu.cn';

  /** 校内统一身份认证主机。 */
  static readonly UPSTREAM_SSO_HOST: string = 'sso.buaa.edu.cn';

  /** 校内用户中心主机（会话校验 / 个人信息）。 */
  static readonly UPSTREAM_UC_HOST: string = 'uc.buaa.edu.cn';

  /** 校内教务主机（课表 / 成绩 / 考试）。 */
  static readonly UPSTREAM_BYXT_HOST: string = 'byxt.buaa.edu.cn';

  /**
   * 历史遗留：SERVER_RELAY 的服务地址。
   *
   * 服务端目前已停止部署（该地址上的 /health/ready、/api/v1/* 均为 nginx 5xx），
   * 保留仅为兼容旧配置读写路径，登录流程不再使用。
   */
  static readonly DEFAULT_API_BASE_URL: string = 'https://ubaa.mofrp.top:2021';

  /** 统一 API 前缀（历史遗留，配合 DEFAULT_API_BASE_URL 使用）。 */
  static readonly API_PREFIX: string = '/api/v1';

  /** 客户端版本号，用于 User-Agent 与关于页展示。 */
  static readonly APP_VERSION: string = '0.1.0';

  /** 连接超时（毫秒）。 */
  static readonly CONNECT_TIMEOUT: number = 10000;

  /** 读写超时（毫秒）。 */
  static readonly READ_TIMEOUT: number = 30000;

  /** 本地持久化文件名。 */
  static readonly PREF_STORE_NAME: string = 'ubaa_pref';

  /** 应用级缓存键。 */
  static readonly PREF_API_BASE_URL: string = 'api_base_url';
  static readonly PREF_CLIENT_ID: string = 'client_id';
  static readonly PREF_CONNECTION_MODE: string = 'connection_mode';
  static readonly PREF_DEMO_MODE: string = 'demo_mode';

  /** 历史遗留：按模式隔离的服务地址键。 */
  static baseUrlKey(mode: ConnectionMode): string {
    return AppConfig.PREF_API_BASE_URL + '_' + mode;
  }

  /** 历史遗留：各模式的默认服务地址（服务端已下线，两模式同值）。 */
  static defaultBaseUrl(mode: ConnectionMode): string {
    return AppConfig.DEFAULT_API_BASE_URL;
  }

  /** 历史遗留：连通性自检探针路径。 */
  static readonly HEALTH_PATH: string = '/health/ready';

  /** 取地址中的「主机:端口」部分，用于错误提示与诊断展示。 */
  static hostOf(url: string): string {
    let value = url.trim();
    const schemeIndex = value.indexOf('://');
    if (schemeIndex >= 0) {
      value = value.substring(schemeIndex + 3);
    }
    const slashIndex = value.indexOf('/');
    if (slashIndex >= 0) {
      value = value.substring(0, slashIndex);
    }
    return value.length > 0 ? value : url;
  }

  /** 当前模式下「统一认证入口」的展示文案。 */
  static authEntryDisplay(mode: ConnectionMode): string {
    return mode === ConnectionMode.WEBVPN
      ? AppConfig.UPSTREAM_SSO_HOST + '（经 ' + AppConfig.WEBVPN_GATEWAY_HOST + ' 加密转发）'
      : AppConfig.UPSTREAM_SSO_HOST + '（直连）';
  }

  /** 当前模式下「会话校验入口」的展示文案。 */
  static sessionCheckDisplay(mode: ConnectionMode): string {
    return mode === ConnectionMode.WEBVPN
      ? AppConfig.UPSTREAM_UC_HOST + '（经 ' + AppConfig.WEBVPN_GATEWAY_HOST + ' 加密转发）'
      : AppConfig.UPSTREAM_UC_HOST + '（直连）';
  }

  /** 演示模式提示语，登录页与设置页共用。 */
  static readonly DEMO_BANNER: string = '演示模式：数据全部来自本地示例，不会访问网络';
}

/**
 * 连接模式。
 *
 * - DIRECT：直连校内上游（sso / uc / byxt）。需处在校园网或已连校园 VPN。
 * - WEBVPN：同样直连校内上游，但地址经北航 WebVPN 网关（d.buaa.edu.cn）加密转发，
 *   校外可用，需先通过统一身份认证。
 *
 * 登录态（上游 Cookie）按模式各自隔离保存，切换模式不会互相污染
 * （见 TokenStore.modeScopedKey）。
 */
export enum ConnectionMode {
  DIRECT = 'DIRECT',
  WEBVPN = 'WEBVPN'
}

/** 首次启动、且用户从未选择过模式时的默认值。 */
export const DEFAULT_CONNECTION_MODE: ConnectionMode = ConnectionMode.DIRECT;

export class ConnectionModeMeta {
  mode: ConnectionMode;
  displayName: string;
  description: string;

  constructor(mode: ConnectionMode, displayName: string, description: string) {
    this.mode = mode;
    this.displayName = displayName;
    this.description = description;
  }
}

export function allConnectionModes(): ConnectionModeMeta[] {
  return [
    new ConnectionModeMeta(ConnectionMode.DIRECT, '校内直连',
      '直接访问学校统一认证与教务系统，需连接校园网或校园 VPN'),
    new ConnectionModeMeta(ConnectionMode.WEBVPN, 'WebVPN',
      '经 WebVPN 网关加密转发访问同样的校内系统，校外可用')
  ];
}

export function connectionModeName(mode: ConnectionMode): string {
  const list = allConnectionModes();
  for (let i = 0; i < list.length; i++) {
    if (list[i].mode === mode) {
      return list[i].displayName;
    }
  }
  return '未知模式';
}
