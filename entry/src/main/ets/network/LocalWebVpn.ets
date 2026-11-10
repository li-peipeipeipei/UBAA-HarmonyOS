import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { AppConfig, ConnectionMode } from '../common/AppConfig';
import { Logger } from '../common/Logger';

/**
 * 北航 WebVPN 访问支持（本地模式，不经自建服务端）。
 *
 * 北航 WebVPN 以「域名加密」方式代理校内资源，格式为：
 *
 *   https://d.buaa.edu.cn/<协议>[-<端口>]/<加密主机名><路径>
 *
 * 其中 `<加密主机名>` 的算法是固定的（网关侧公开约定，参考实现 UBAA 的
 * `LocalWebVpnSupport` 即照此实现）：
 *
 *   1. 明文主机名按 16 字节分块，末尾补字节 `'0'`(0x30) 至整块；
 *   2. AES-128 / CFB / NoPadding，密钥与 IV 同为固定串 `wrdvpnisthebest!`；
 *   3. 输出 = `IV 的 32 位十六进制` + `密文十六进制截断到「明文长度 × 2」位`。
 *
 * 例：`sso.buaa.edu.cn/login` 经 WebVPN 后变成
 * `https://d.buaa.edu.cn/https/<32位IV+密文>/login`。
 *
 * 直连模式（DIRECT）不做任何改写，原始地址直接访问，需处在校园网内。
 */

/** WebVPN 网关域名（唯一定义处见 AppConfig）。 */
const WEBVPN_GATEWAY_HOST: string = AppConfig.WEBVPN_GATEWAY_HOST;

/** WebVPN 固定的加解密密钥与 IV 文本。 */
const WEBVPN_KEY_TEXT: string = 'wrdvpnisthebest!';

const AES_BLOCK_SIZE: number = 16;
const DEFAULT_HTTP_PORT: number = 80;
const DEFAULT_HTTPS_PORT: number = 443;

/** 拆解后的 URL 片段（只解析我们真正用到的字段）。 */
class ParsedUrl {
  scheme: string = '';
  host: string = '';
  port: number = 0;
  path: string = '';
  query: string = '';
  fragment: string = '';
}

/** 仅供域名使用的 ASCII 编码（主机名一定在 ASCII 范围内）。 */
function stringToBytes(text: string): Uint8Array {
  const bytes = new Uint8Array(text.length);
  for (let i = 0; i < text.length; i++) {
    bytes[i] = text.charCodeAt(i) & 0xFF;
  }
  return bytes;
}

function pad2(value: number): string {
  return value < 16 ? '0' + value.toString(16) : value.toString(16);
}

function bytesToHex(bytes: Uint8Array): string {
  let out = '';
  for (let i = 0; i < bytes.length; i++) {
    out += pad2(bytes[i]);
  }
  return out;
}

/** 十六进制串 → 字节数组。 */
function hexToBytes(hex: string): Uint8Array {
  const out = new Uint8Array(Math.floor(hex.length / 2));
  for (let i = 0; i < out.length; i++) {
    const v = parseInt(hex.substring(i * 2, i * 2 + 2), 16);
    out[i] = isNaN(v) ? 0 : v;
  }
  return out;
}

/** 字节数组 → 字符串（按 UTF-8 解；主机名是 ASCII，用 latin1 也行）。 */
function bytesToString(bytes: Uint8Array, length: number): string {
  let out = '';
  const n = length >= 0 && length <= bytes.length ? length : bytes.length;
  for (let i = 0; i < n; i++) {
    out += String.fromCharCode(bytes[i]);
  }
  return out;
}

function parseUrl(raw: string): ParsedUrl | null {
  const schemeIndex = raw.indexOf('://');
  if (schemeIndex <= 0) {
    return null;
  }
  const parsed = new ParsedUrl();
  parsed.scheme = raw.substring(0, schemeIndex).toLowerCase();

  let rest = raw.substring(schemeIndex + 3);
  const hashIndex = rest.indexOf('#');
  if (hashIndex >= 0) {
    parsed.fragment = rest.substring(hashIndex + 1);
    rest = rest.substring(0, hashIndex);
  }

  const slashIndex = rest.indexOf('/');
  const authority = slashIndex >= 0 ? rest.substring(0, slashIndex) : rest;
  const pathAndQuery = slashIndex >= 0 ? rest.substring(slashIndex) : '';

  const queryIndex = pathAndQuery.indexOf('?');
  if (queryIndex >= 0) {
    parsed.path = pathAndQuery.substring(0, queryIndex);
    parsed.query = pathAndQuery.substring(queryIndex + 1);
  } else {
    parsed.path = pathAndQuery;
  }

  const colonIndex = authority.lastIndexOf(':');
  if (colonIndex > 0) {
    parsed.host = authority.substring(0, colonIndex);
    const portText = authority.substring(colonIndex + 1);
    parsed.port = portText.length > 0 ? parseInt(portText, 10) : 0;
    if (isNaN(parsed.port)) {
      parsed.port = 0;
    }
  } else {
    parsed.host = authority;
  }
  return parsed;
}

/**
 * AES-128 / CFB / NoPadding 加密。
 *
 * HarmonyOS CryptoFramework 的算法串格式为「算法|模式|填充」，与 Java 的
 * `Cipher.getInstance("AES/CFB/NoPadding")` 一一对应（参考实现走的就是后者）。
 */
async function aesCfbEncrypt(plain: Uint8Array, key: Uint8Array, iv: Uint8Array): Promise<Uint8Array> {
  const cipher = cryptoFramework.createCipher('AES128|CFB|NoPadding');
  const keyGenerator = cryptoFramework.createSymKeyGenerator('AES128');
  const keyBlob: cryptoFramework.DataBlob = { data: key };
  const symKey = await keyGenerator.convertKey(keyBlob);
  const ivSpec: cryptoFramework.IvParamsSpec = {
    algName: 'IvParamsSpec',
    iv: { data: iv }
  };
  await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, symKey, ivSpec);
  const output: cryptoFramework.DataBlob = await cipher.doFinal({ data: plain });
  return output.data;
}

/**
 * AES-128 / CFB / NoPadding 解密 —— `aesCfbEncrypt` 的逆运算。
 *
 * CryptoFramework 的 CFB 解密同样要显式给 IV（加密时用过同一个）。
 */
async function aesCfbDecrypt(cipher: Uint8Array, key: Uint8Array, iv: Uint8Array): Promise<Uint8Array> {
  const cipher2 = cryptoFramework.createCipher('AES128|CFB|NoPadding');
  const keyGenerator = cryptoFramework.createSymKeyGenerator('AES128');
  const keyBlob: cryptoFramework.DataBlob = { data: key };
  const symKey = await keyGenerator.convertKey(keyBlob);
  const ivSpec: cryptoFramework.IvParamsSpec = {
    algName: 'IvParamsSpec',
    iv: { data: iv }
  };
  await cipher2.init(cryptoFramework.CryptoMode.DECRYPT_MODE, symKey, ivSpec);
  const output = await cipher2.doFinal({ data: cipher });
  return output.data;
}

export class LocalWebVpn {
  /** 主机名是否为 WebVPN 网关自身（已是网关地址则不再二次加密）。 */
  static isGatewayHost(host: string): boolean {
    return host.toLowerCase() === WEBVPN_GATEWAY_HOST;
  }

  /** 按网关约定加密主机名，产出 URL 路径段。 */
  static async encryptHost(host: string): Promise<string> {
    const key = stringToBytes(WEBVPN_KEY_TEXT);
    const iv = stringToBytes(WEBVPN_KEY_TEXT);
    const plain = stringToBytes(host);

    const padLength = (AES_BLOCK_SIZE - (plain.length % AES_BLOCK_SIZE)) % AES_BLOCK_SIZE;
    const padded = new Uint8Array(plain.length + padLength);
    padded.set(plain, 0);
    // 网关约定补 '0'（0x30）而非 0x00
    for (let i = plain.length; i < padded.length; i++) {
      padded[i] = 0x30;
    }

    const encrypted = await aesCfbEncrypt(padded, key, iv);
    // 输出 = IV(32 hex) + 密文截断到明文长度
    return bytesToHex(iv) + bytesToHex(encrypted).substring(0, plain.length * 2);
  }

  /**
   * 主机名解密 —— `encryptHost` 的逆运算。
   *
   * WebVPN 网关返回的 `Location` 头里主机名是**加密的**，
   * 跟跳转链时必须先解出真实主机名才能判断「这是不是 SSO 的地址」。
   */
  static async decryptHost(encodedHost: string): Promise<string | null> {
    if (encodedHost.length < 32) {
      return null;
    }
    try {
      const iv = hexToBytes(encodedHost.substring(0, 32));
      const cipherText = hexToBytes(encodedHost.substring(32));
      // 密文被截断过（只保留明文长度），按 16 字节补齐再解
      const paddedLen = Math.ceil(cipherText.length / 16) * 16;
      const full = new Uint8Array(paddedLen);
      full.set(cipherText, 0);
      const plain = await aesCfbDecrypt(full, stringToBytes(WEBVPN_KEY_TEXT), iv);
      return bytesToString(plain, encodedHost.length / 2 - 16);
    } catch (error) {
      return null;
    }
  }

  /**
   * **解包**：把 WebVPN 网关地址还原成校内真实地址。
   *
   * 网关地址形如 `https://d.buaa.edu.cn/https/<密文主机>/<真实路径>?<查询>`，
   * 解出来是 `https://<真实主机>/<真实路径>?<查询>`。
   *
   * ## 为什么必须有这一步
   *
   * WebVPN 的 `Location` 头给的是**网关地址**。跟跳转时若直接把它当校内地址
   * 再包装一次，就会变成「双重包装」→ 地址彻底错乱 → 凭据根本没提交到 SSO
   * → 表现为「账号或密码验证未通过」（其实密码是对的）。
   *
   * 对齐原版 `LocalWebVpnSupport.fromWebVpnUrl`。
   */
  static async fromWebVpnUrl(raw: string): Promise<string> {
    const parsed = parseUrl(raw);
    if (parsed === null || !LocalWebVpn.isGatewayHost(parsed.host)) {
      return raw;
    }
    // 路径形如 /https/<密文>/<真实路径...>
    const segments: string[] = parsed.path.split('/').filter((s: string) => s.length > 0);
    if (segments.length < 2) {
      return raw;
    }
    const protocolPart: string = segments[0];
    const encodedHost: string = segments[1];
    const dashIndex: number = protocolPart.indexOf('-');
    const scheme: string = dashIndex > 0 ? protocolPart.substring(0, dashIndex) : protocolPart;
    const portText: string = dashIndex > 0 ? protocolPart.substring(dashIndex + 1) : '';
    if (scheme.length === 0) {
      return raw;
    }
    const host: string | null = await LocalWebVpn.decryptHost(encodedHost);
    if (host === null || host.length === 0) {
      return raw;
    }
    const port: number = portText.length > 0 ? parseInt(portText, 10) : 0;
    const authority: string =
      port > 0 ? scheme + '://' + host + ':' + port.toString() : scheme + '://' + host;
    // ⚠️ **只移除协议与加密主机两段前缀**，不能重组全部片段 ——
    // 重组会丢掉 `/web/` 这类路径的尾斜杠，导致 iHome 登录打转。
    // 原版注释也点了这一条。
    const restSegments: string[] = parsed.path.split('/');
    const pathPart: string = restSegments.length > 3 ? '/' + restSegments.slice(3).join('/') : '';
    const queryPart: string = parsed.query.length > 0 ? '?' + parsed.query : '';
    const fragmentPart: string = parsed.fragment.length > 0 ? '#' + parsed.fragment : '';
    return authority + pathPart + queryPart + fragmentPart;
  }

  /**
   * SSO 已启用 HSTS —— 原生客户端必须把旧 HTTP 跳转升级成 HTTPS。
   *
   * 只针对 `sso.buaa.edu.cn:80`，其余地址原样返回
   * （对齐原版 `CasTransport.secureCasTransportUrl`）。
   *
   * ## 为什么必须有
   *
   * 浏览器有 HSTS 预加载，能自动把 `http://sso.buaa.edu.cn` 升成 HTTPS；
   * **原生客户端没有这层机制** —— 不升级就是明文请求，SSO 侧会拒
   * （或返回一个不含 `execution` 的页面 → 后续提交被判「凭据无效」）。
   */
  static secureCasTransportUrl(url: string): string {
    return url.replace(
      /^http:\/\/sso\.buaa\.edu\.cn(?::80)?(?=[/?#]|$)/i,
      'https://sso.buaa.edu.cn'
    );
  }

  /**
   * 把校内地址改写成 WebVPN 地址；已是网关地址或无法解析时原样返回。
   */
  static async toWebVpnUrl(raw: string): Promise<string> {
    const parsed = parseUrl(raw);
    if (parsed === null || LocalWebVpn.isGatewayHost(parsed.host)) {
      return raw;
    }

    let protocolPart = parsed.scheme;
    if (parsed.port <= 0) {
      protocolPart = parsed.scheme;
    } else if (parsed.port === DEFAULT_HTTP_PORT && parsed.scheme === 'http') {
      protocolPart = 'http';
    } else if (parsed.port === DEFAULT_HTTPS_PORT && parsed.scheme === 'https') {
      protocolPart = 'https';
    } else {
      protocolPart = parsed.scheme + '-' + parsed.port;
    }

    const encodedHost = await LocalWebVpn.encryptHost(parsed.host);
    const queryPart = parsed.query.length > 0 ? '?' + parsed.query : '';
    const fragmentPart = parsed.fragment.length > 0 ? '#' + parsed.fragment : '';

    return 'https://' + WEBVPN_GATEWAY_HOST + '/' + protocolPart + '/' + encodedHost +
      parsed.path + queryPart + fragmentPart;
  }

  /**
   * 按当前连接模式把「逻辑上游地址」翻译成实际请求地址。
   *
   * 这是整个本地模式的唯一改写入口 —— 所有上游请求都必须过这一道，
   * 否则 WebVPN 模式下会绕过网关直接打校内域名（校外必然超时）。
   */
  static async rewrite(raw: string, mode: ConnectionMode): Promise<string> {
    if (mode !== ConnectionMode.WEBVPN) {
      return raw;
    }
    try {
      return await LocalWebVpn.toWebVpnUrl(raw);
    } catch (error) {
      Logger.error('WebVPN 地址改写失败：' + (error as Error).message);
      return raw;
    }
  }

  /** 供诊断页展示当前模式下的实际入口地址（不发起请求）。 */
  static async describeEntry(mode: ConnectionMode): Promise<string> {
    return await LocalWebVpn.rewrite('https://' + AppConfig.UPSTREAM_SSO_HOST + '/login', mode);
  }
}
