import { AppConfig, ConnectionMode, connectionModeName } from '../common/AppConfig';
import { Logger } from '../common/Logger';
import { ApiError } from './ApiError';
import { LocalWebVpn } from './LocalWebVpn';
import { UpstreamClient, UpstreamResponse } from './UpstreamClient';

/** 单步探测的故障归类。 */
export enum ProbeKind {
  /** 探测成功。 */
  OK = 'OK',
  /** 返回登录门户网页 —— 地址对，但未登录。 */
  PORTAL = 'PORTAL',
  /** 返回 5xx 错误页 —— 地址对，上游自身故障。 */
  UPSTREAM_DOWN = 'UPSTREAM_DOWN',
  /** 返回 4xx —— 地址或路径不对。 */
  BAD_PATH = 'BAD_PATH',
  /** 根本没连上。 */
  UNREACHABLE = 'UNREACHABLE'
}

/** 单次探测结果。 */
export class ProbeStep {
  path: string = '';
  status: number = 0;
  elapsedMs: number = 0;
  ok: boolean = false;
  kind: ProbeKind = ProbeKind.UNREACHABLE;
  note: string = '';
}

/** 上游统一响应信封里我们只需要 code 字段。 */
interface CodeEnvelope {
  code?: number;
}

/** 诊断结论。 */
export class DiagnosticResult {
  mode: ConnectionMode = ConnectionMode.DIRECT;
  /** 当前模式下的实际入口地址（WebVPN 模式下是网关改写后的地址）。 */
  baseUrl: string = '';
  reachable: boolean = false;
  loggedIn: boolean = false;
  headline: string = '';
  detail: string = '';
  steps: ProbeStep[] = [];
}

/**
 * 连通性自检（本地模式）。
 *
 * 服务端已下线，因此这里探的是**真正的上游**，分两步：
 *
 * 1. `sso.buaa.edu.cn/login` —— 统一认证入口是否可达。这一步同时验证了
 *    WebVPN 的域名加密是否正确（写错的话网关不会给出登录页）；
 * 2. `uc.buaa.edu.cn/api/uc/status` —— 会话是否仍然有效。
 *
 * 把「地址写错 / 不在校园网 / 上游宕机 / 未登录」这四类情况区分开，
 * 因为对应的处置动作完全不同。
 */
export class NetworkDiagnostics {
  private static readonly CAS_LOGIN_URL: string = 'https://' + AppConfig.UPSTREAM_SSO_HOST + '/login';
  private static readonly UC_STATUS_URL: string = 'https://' + AppConfig.UPSTREAM_UC_HOST + '/api/uc/status';

  static async probe(mode: ConnectionMode): Promise<DiagnosticResult> {
    const result = new DiagnosticResult();
    result.mode = mode;
    result.baseUrl = await LocalWebVpn.describeEntry(mode);

    const lines: string[] = [];
    lines.push('模式：' + connectionModeName(mode));
    lines.push('认证入口：' + AppConfig.authEntryDisplay(mode));
    if (mode === ConnectionMode.WEBVPN) {
      lines.push('实际请求：' + result.baseUrl);
    }

    // ---- 第一步：统一认证入口 ----
    const authStep = await NetworkDiagnostics.probeAuth();
    result.steps.push(authStep);
    lines.push('');
    lines.push('GET ' + authStep.path + '  →  ' +
      (authStep.note.length > 0 ? authStep.note : 'HTTP ' + authStep.status) +
      '（' + authStep.elapsedMs + ' ms）');

    // ---- 第二步：会话状态 ----
    const sessionStep = await NetworkDiagnostics.probeSession();
    result.steps.push(sessionStep);
    lines.push('');
    lines.push('GET ' + sessionStep.path + '  →  ' +
      (sessionStep.note.length > 0 ? sessionStep.note : 'HTTP ' + sessionStep.status) +
      '（' + sessionStep.elapsedMs + ' ms）');

    const authOk: boolean = authStep.ok;
    result.loggedIn = sessionStep.ok;
    result.reachable = authOk;

    lines.push('');
    if (authOk && sessionStep.ok) {
      result.headline = '网络正常，已登录';
      lines.push('结论：统一认证入口可达，且上游会话有效。');
    } else if (authOk && sessionStep.kind === ProbeKind.PORTAL) {
      result.headline = '网络正常，尚未登录';
      lines.push('结论：统一认证入口可达，但当前没有有效的上游会话。');
      lines.push('处置：正常现象 —— 在登录页完成一次统一身份认证即可。');
    } else if (authOk) {
      result.headline = '网络正常，会话状态未知';
      lines.push('结论：统一认证入口可达，会话接口返回了非预期内容（HTTP ' + sessionStep.status + '）。');
      lines.push('处置：重新登录一次即可刷新会话。');
    } else if (authStep.kind === ProbeKind.UPSTREAM_DOWN) {
      result.headline = '上游服务故障（非客户端问题）';
      lines.push('结论：请求已经打到学校系统，但对方返回 HTTP ' + authStep.status + '。');
      lines.push('这是学校侧的故障，换网络、改模式都无法解决，只能稍后重试。');
    } else if (authStep.kind === ProbeKind.UNREACHABLE) {
      result.headline = '认证入口不可达';
      if (mode === ConnectionMode.DIRECT) {
        lines.push('结论：连不上统一认证入口。');
        lines.push('处置：直连模式要求处在校园网或校园 VPN 内 —— 若当前在校外，');
        lines.push('请切到「WebVPN」模式后重试。');
      } else {
        lines.push('结论：连不上 WebVPN 网关，域名加密后的地址未能返回登录页。');
        lines.push('处置：确认设备可以访问外网；若可以，请把上面的「实际请求」地址');
        lines.push('在浏览器里打开一次，看网关给出的具体错误。');
      }
    } else {
      result.headline = '入口可达但不是登录页';
      lines.push('结论：服务器有响应（HTTP ' + authStep.status + '），但返回的不是统一认证页面。');
      lines.push('处置：确认网络没有经过任何代理或强制门户（如酒店 / 机场 WiFi 的认证页）。');
    }

    result.detail = lines.join('\n');
    Logger.info('连接诊断：' + result.headline + '\n' + result.detail);
    return result;
  }

  /** 探测统一认证登录页。 */
  private static async probeAuth(): Promise<ProbeStep> {
    return await NetworkDiagnostics.step(NetworkDiagnostics.CAS_LOGIN_URL, '', false);
  }

  /**
   * 探测会话状态。
   *
   * 这里用真实的上游客户端而不是裸 http —— 它会把当前 Cookie 一起带上，
   * 因此能真正回答「我还登录着吗」，而不只是「接口通不通」。
   */
  private static async probeSession(): Promise<ProbeStep> {
    return await NetworkDiagnostics.step(NetworkDiagnostics.UC_STATUS_URL, 'X-Requested-With', true);
  }

  private static async step(logicalUrl: string, headerName: string, expectJson: boolean): Promise<ProbeStep> {
    const step = new ProbeStep();
    step.path = logicalUrl;
    const startedAt = Date.now();
    try {
      const headers: Record<string, string> = {};
      if (headerName.length > 0) {
        headers[headerName] = 'XMLHttpRequest';
      }
      const response: UpstreamResponse = await UpstreamClient.get(logicalUrl, false, headers);
      step.status = response.status;

      if (expectJson) {
        const isJson: boolean = response.body.trimStart().startsWith('{');
        if (response.status >= 500) {
          step.kind = ProbeKind.UPSTREAM_DOWN;
          step.note = 'HTTP ' + response.status + '，上游错误';
        } else if (!isJson) {
          step.kind = ProbeKind.PORTAL;
          step.note = '未登录（返回登录门户而非接口数据）';
        } else if (response.status >= 300) {
          step.kind = ProbeKind.PORTAL;
          step.note = 'HTTP ' + response.status + '，未登录';
        } else {
          const loggedIn: boolean = NetworkDiagnostics.envelopeCode(response.body) === 0;
          step.ok = loggedIn;
          step.kind = loggedIn ? ProbeKind.OK : ProbeKind.PORTAL;
          step.note = loggedIn ? '已登录' : '未登录（code≠0）';
        }
      } else {
        const isHtml: boolean = response.body.trimStart().toLowerCase().startsWith('<!doctype html') ||
          response.body.trimStart().toLowerCase().startsWith('<html');
        if (response.status >= 500) {
          step.kind = ProbeKind.UPSTREAM_DOWN;
          step.note = 'HTTP ' + response.status;
        } else if (response.status === 404) {
          step.kind = ProbeKind.BAD_PATH;
          step.note = 'HTTP 404';
        } else if (isHtml || response.status >= 300) {
          // 登录页 / 跳转都说明入口是活的
          step.ok = true;
          step.kind = ProbeKind.OK;
          step.note = response.status >= 300
            ? 'HTTP ' + response.status + '（已有会话，重定向）'
            : 'HTTP ' + response.status + '，登录页正常';
        } else {
          step.kind = ProbeKind.BAD_PATH;
          step.note = 'HTTP ' + response.status + '，非登录页';
        }
      }
    } catch (error) {
      step.kind = ProbeKind.UNREACHABLE;
      step.note = error instanceof ApiError
        ? (error as ApiError).friendlyMessage()
        : (error as Error).message;
    } finally {
      step.elapsedMs = Date.now() - startedAt;
    }
    return step;
  }

  /** 从 `{ code, … }` 信封里取 code；解析失败返回 -1。 */
  private static envelopeCode(body: string): number {
    try {
      const parsed = JSON.parse(body) as CodeEnvelope;
      const value = parsed.code;
      return value === undefined ? -1 : value;
    } catch (error) {
      return -1;
    }
  }
}
