import { CaptchaInfo } from '../model/ApiTypes';

/**
 * 校内统一认证（CAS / Apereo）登录页解析。
 *
 * 与参考实现 UBAA 的 `LocalCasParser` 保持同一套正则与表单构造规则 ——
 * 这不是随手写的启发式，而是对着学校 SSO 真实页面结构调出来的：
 *
 * - `execution` 是 CAS 的一次性令牌，必须从登录页里抠出来原样回传，缺了它
 *   服务端一律按「凭据无效」处理；
 * - 若登录页声明了 `config.captcha = { type, id }`，说明本次需要验证码；
 * - 失败提示藏在 `tip-text` / `errorDiv` / `errors` 几种容器里，文案直接面向用户，
 *   原样透出比换成「登录失败」有用得多。
 */

/** `name="execution"` 的 hidden input（CAS 标准写法，name 在前）。 */
const EXECUTION_RE = new RegExp('<input[^>]*name=["\']execution["\'][^>]*value=["\']([^"\']+)["\'][^>]*>', 'i');

/** 少数模板会把 value 写在 name 前面。 */
const EXECUTION_REVERSED_RE = new RegExp('<input[^>]*value=["\']([^"\']+)["\'][^>]*name=["\']execution["\'][^>]*>', 'i');

/** 提示文案容器（CAS 默认模板）。 */
const TIP_RE = new RegExp('<div[^>]*class=["\'][^"\']*tip-text[^"\']*["\'][^>]*>([\\s\\S]*?)</div>', 'i');

/** 验证码声明。 */
const CAPTCHA_RE = new RegExp('config\\.captcha\\s*=\\s*\\{\\s*type:\\s*[\'"]([^\'"]+)[\'"],\\s*id:\\s*[\'"]([^\'"]+)[\'"]');

/** 逐个 `<input ...>` 标签。 */
const INPUT_RE = new RegExp('<input\\b([^>]*)>', 'gi');

/** `<input>` 内部的属性键值对。 */
const ATTR_RE = new RegExp('([a-zA-Z_:][-a-zA-Z0-9_:.]*)\\s*=\\s*["\']([^"\']*)["\']', 'g');

/** 裸 `checked` 属性（没有 = 号）。 */
const CHECKED_RE = new RegExp('\\bchecked\\b', 'i');

/** 各种错误容器。 */
const ERROR_RES: RegExp[] = [
  new RegExp('<div[^>]*id=["\']errorDiv["\'][^>]*>([\\s\\S]*?)</div>', 'i'),
  new RegExp('<div[^>]*class=["\'][^"\']*errors[^"\']*["\'][^>]*>([\\s\\S]*?)</div>', 'i'),
  new RegExp('<p[^>]*class=["\'][^"\']*errors[^"\']*["\'][^>]*>([\\s\\S]*?)</p>', 'i'),
  new RegExp('<span[^>]*class=["\'][^"\']*errors[^"\']*["\'][^>]*>([\\s\\S]*?)</span>', 'i')
];

const TAG_RE = new RegExp('<[^>]+>', 'g');

function stripHtml(text: string): string {
  return text.replace(TAG_RE, ' ').replace(/\s+/g, ' ').trim();
}

function firstGroup(regex: RegExp, html: string): string {
  const matched = regex.exec(html);
  if (matched === null || matched.length < 2 || matched[1] === undefined) {
    return '';
  }
  return matched[1];
}

/** 解析一个 `<input>` 标签的属性集合。 */
function parseAttributes(attributeText: string): Map<string, string> {
  const values = new Map<string, string>();
  ATTR_RE.lastIndex = 0;
  let matched = ATTR_RE.exec(attributeText);
  while (matched !== null) {
    values.set(matched[1].toLowerCase(), matched[2]);
    matched = ATTR_RE.exec(attributeText);
  }
  if (CHECKED_RE.test(attributeText)) {
    values.set('checked', 'checked');
  }
  return values;
}

/** 表单字段（按插入顺序保留，CAS 对顺序不敏感但保持与原页面一致更稳）。 */
class FormField {
  name: string = '';
  value: string = '';

  constructor(name: string, value: string) {
    this.name = name;
    this.value = value;
  }
}

function encodeForm(fields: FormField[]): string {
  const parts: string[] = [];
  for (let i = 0; i < fields.length; i++) {
    parts.push(encodeURIComponent(fields[i].name) + '=' + encodeURIComponent(fields[i].value));
  }
  return parts.join('&');
}

export class CasParser {
  /** 抠出一次性令牌 `execution`。 */
  static extractExecution(html: string): string {
    const direct = firstGroup(EXECUTION_RE, html);
    if (direct.length > 0) {
      return direct;
    }
    return firstGroup(EXECUTION_REVERSED_RE, html);
  }

  /** 探测登录页是否要求验证码。 */
  static detectCaptcha(html: string, captchaUrlBase: string): CaptchaInfo | null {
    const matched = CAPTCHA_RE.exec(html);
    if (matched === null) {
      return null;
    }
    const id = matched[2];
    return {
      id: id,
      type: matched[1],
      imageUrl: captchaUrlBase + '?captchaId=' + id
    };
  }

  /** 页面级提示（`tip-text` 容器）。 */
  static extractTipText(html: string): string {
    const raw = firstGroup(TIP_RE, html);
    return raw.length > 0 ? stripHtml(raw) : '';
  }

  /** 登录失败文案（含 tip-text 与几种 errors 容器）。 */
  static findLoginError(html: string): string {
    if (html.length === 0) {
      return '';
    }
    const tip = CasParser.extractTipText(html);
    if (tip.length > 0) {
      return tip;
    }
    for (let i = 0; i < ERROR_RES.length; i++) {
      const raw = firstGroup(ERROR_RES[i], html);
      if (raw.length > 0) {
        const text = stripHtml(raw);
        if (text.length > 0) {
          return text;
        }
      }
    }
    return '';
  }

  /**
   * 是否为「密码过期 / 账号风险」这类需要二次确认的中间页。
   *
   * 这类页面不是失败：它带 `execution`，要求提交 `_eventId=ignoreAndContinue`
   * 表示「我知道了，继续」。不处理就会被误判成登录失败。
   */
  static isIgnorablePasswordExpiryPage(html: string): boolean {
    if (html.length === 0 || CasParser.extractExecution(html).length === 0) {
      return false;
    }
    const lower = html.toLowerCase();
    return lower.indexOf('continueform') >= 0 ||
      lower.indexOf('ignoreandcontinue') >= 0 ||
      html.indexOf('账号存在安全风险') >= 0 ||
      html.indexOf('密码过期') >= 0;
  }

  /** 「忽略密码过期提示」表单。 */
  static buildIgnorePasswordExpiryBody(execution: string): string {
    const fields: FormField[] = [
      new FormField('execution', execution),
      new FormField('_eventId', 'ignoreAndContinue')
    ];
    return encodeForm(fields);
  }

  /**
   * 按登录页里的真实字段构造提交表单。
   *
   * 规则与 CAS 页面语义一致：
   * - `submit` / `button` / `image` 类按钮不提交；
   * - `checkbox` 只在带 `checked` 时提交（默认值 `on`）；
   * - 其余 `hidden` 或带值的输入原样带上（`lt`、`_eventId`、`execution` 等）；
   * - `username` / `password` 用用户输入覆盖，不取页面默认值。
   */
  static buildLoginBody(
    html: string,
    username: string,
    password: string,
    execution: string,
    captcha: string
  ): string {
    const fields: FormField[] = [];
    const present = new Set<string>();
    let hasCaptchaInput = false;

    INPUT_RE.lastIndex = 0;
    let matched = INPUT_RE.exec(html);
    while (matched !== null) {
      const attrs = parseAttributes(matched[1]);
      const name = attrs.has('name') ? attrs.get('name')!.trim() : '';
      if (name.length > 0) {
        const type = attrs.has('type') ? attrs.get('type')!.trim().toLowerCase() : '';
        const value = attrs.has('value') ? attrs.get('value')! : '';
        if (name === 'username' || name === 'password') {
          present.add(name);
        } else if (type === 'submit' || type === 'button' || type === 'image') {
          // 按钮类不提交
        } else if (type === 'checkbox') {
          present.add(name);
          if (attrs.has('checked')) {
            fields.push(new FormField(name, value.length > 0 ? value : 'on'));
          }
        } else {
          present.add(name);
          if (name === 'captcha' || name === 'captchaResponse') {
            hasCaptchaInput = true;
          }
          if (type === 'hidden' || value.length > 0) {
            fields.push(new FormField(name, value));
          }
        }
      }
      matched = INPUT_RE.exec(html);
    }

    fields.push(new FormField('username', username));
    fields.push(new FormField('password', password));
    fields.push(new FormField('submit', '登录'));

    if (captcha.length > 0) {
      // 页面里字段名可能是 captcha 或 captchaResponse，两个都带上更保险
      if (hasCaptchaInput) {
        fields.push(new FormField('captcha', captcha));
        fields.push(new FormField('captchaResponse', captcha));
      }
    }

    if (!present.has('_eventId')) {
      fields.push(new FormField('_eventId', 'submit'));
    }
    if (!present.has('execution')) {
      fields.push(new FormField('execution', execution));
    }
    if (!present.has('type')) {
      fields.push(new FormField('type', 'username_password'));
    }
    return encodeForm(fields);
  }

  /**
   * 已确认需要验证码时的精简表单。
   *
   * 此时页面的 `execution` 可能已经随上一次提交轮换过，直接用调用方持有的值，
   * 避免把整页字段（含过期令牌）再发一遍。
   */
  static buildCaptchaLoginBody(
    username: string,
    password: string,
    captcha: string,
    execution: string
  ): string {
    const fields: FormField[] = [
      new FormField('username', username),
      new FormField('password', password),
      new FormField('captcha', captcha),
      new FormField('captchaResponse', captcha),
      new FormField('execution', execution),
      new FormField('_eventId', 'submit'),
      new FormField('submit', '登录'),
      new FormField('type', 'username_password')
    ];
    return encodeForm(fields);
  }

  /**
   * 页面是否还停留在登录表单上（说明本次提交被退回，即凭据错误）。
   *
   * 判据是「同时存在 username 与 password 两个输入框」，而不是「存在 execution 输入框」——
   * 登录成功后的成功页 / 退出表单里同样会有 `name="execution"` 的隐藏域，
   * 拿它当判据会把登录成功误判成密码错误。
   */
  static hasLoginForm(html: string): boolean {
    const lower = html.toLowerCase();
    return lower.indexOf('name="username"') >= 0 && lower.indexOf('name="password"') >= 0;
  }

  /** 页面是否像 HTML 文档（用于识别「被登录页接管」）。 */
  static looksLikeHtml(body: string): boolean {
    const head = body.trimStart().toLowerCase();
    return head.startsWith('<!doctype html') || head.startsWith('<html');
  }
}
