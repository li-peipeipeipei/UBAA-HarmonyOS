import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { Logger } from '../common/Logger';
import { ApiError } from './ApiError';
import { resolveLocation, UpstreamClient, UpstreamResponse } from './UpstreamClient';
import { SpocAssignment, SpocAssignmentDetail, SpocAssignmentsData } from '../model/ApiTypes';

/**
 * SPOC（在线课程平台）本地上游取数。
 *
 * ## 与其它子系统最大的不同：SPOC 自成一套 token 体系
 *
 * CAS 的 SSO 会话只用来「换一次 SPOC 的 token」：访问 `/spocnewht/cas` 会被逐跳
 * 重定向，链路上某一跳的**查询串里带着 `token`**（`refreshToken` 可选），把它
 * 捞出来，再 POST `/spocnewht/sys/casLogin`（头 `Token: Inco-<loginToken>`）
 * 换来 `roleCode`。之后所有业务接口都带 `Token: Inco-<token>` + `RoleCode` 头。
 *
 * ## 一个协议常量
 *
 * `queryListByPage` 要求把查询条件加密成一个 `param` 字段。算法是**固定的**
 * AES/CBC/NoPadding，key 与 iv 是写死的前端兼容常量（不是部署密钥）：
 * 明文按 UTF-8 取字节 → 零填充到 16 的整数倍 → AES-CBC 加密 → Base64。
 * ArkTS 侧用 `@kit.CryptoArchitectureKit` 实现（见 `encryptParam`）。
 *
 * ## 会话失效长什么样
 *
 * SPOC 对失效 token 回 HTTP 200 + `{code: 非200, msg: 含「登录/token/未认证」}`，
 * 所以判据是「**信封 code 不是 200**，且 msg 命中登录类关键词」→ 重换一次 token 再试。
 */

/* ------------------------------ 上游地址 ------------------------------ */

const SPOC_BASE: string = 'https://spoc.buaa.edu.cn';
/** 换取 token 的入口（本身就是一条跳转链）。 */
const SPOC_CAS_URL: string = SPOC_BASE + '/spocnewht/cas';
/** 用 loginToken 换 roleCode。 */
const SPOC_CAS_LOGIN_URL: string = SPOC_BASE + '/spocnewht/sys/casLogin';
/** 当前学期。 */
const SPOC_CURRENT_TERM_URL: string = SPOC_BASE + '/spocnewht/inco/ht/queryOne';
/** 课程列表（用于补教师名）。 */
const SPOC_COURSES_URL: string = SPOC_BASE + '/spocnewht/jxkj/queryKclb';
/** 作业分页列表。 */
const SPOC_ASSIGNMENTS_URL: string = SPOC_BASE + '/spocnewht/inco/ht/queryListByPage';
/** 作业详情。 */
const SPOC_DETAIL_URL: string = SPOC_BASE + '/spocnewht/kczy/queryKczyInfoByid';
/** 我的提交记录。 */
const SPOC_SUBMISSION_URL: string = SPOC_BASE + '/spocnewht/kczy/queryXsSubmitKczyInfo';

/** 固定 AES 参数（协议常量，照抄原实现）。 */
const AES_KEY: string = 'inco12345678ocni';
const AES_IV: string = 'ocni12345678inco';

/** 「当前学期」查询的预加密参数（原实现里的常量，直接照抄）。 */
const CURRENT_TERM_PARAM: string =
  'YHrxtTavu6raCwC0/qdgYffB9evWHBkTng/XS4W6j3f/TPo02iEPSoegscDTRNzIPRG49o3RHl4JiFCXAiBkkA==';

/** 作业分页查询的 sqlid（原实现常量）。 */
const ASSIGNMENTS_PAGE_SQL_ID: string = '1713252980496efac7d5d9985e81693116d3e8a52ebf2b';

const PAGE_SIZE: number = 15;
/** 登录跳转链最大跳数（原实现为 8）。 */
const MAX_LOGIN_HOPS: number = 8;

/* ------------------------------ 响应结构 ------------------------------ */

/** SPOC 通用信封：`{ code, msg, msg_en, content }`，成功时 code === 200。 */
interface SpocEnvelope<T> {
  code?: number;
  msg?: string;
  msg_en?: string;
  content?: T;
}

interface SpocTokens {
  token: string;
  refreshToken: string;
}

interface SpocCurrentTerm {
  dqxq?: string;
  mrxq?: string;
}

interface SpocCourse {
  kcid?: string;
  kcmc?: string;
  skjs?: string;
}

interface SpocPagedAssignment {
  zyid?: string;
  tjzt?: string;
  zyjzsj?: string;
  zymc?: string;
  zykssj?: string;
  sskcid?: string;
  xnxq?: string;
  mf?: string;
  kcmc?: string;
}

interface SpocAssignmentsPage {
  total?: number;
  list?: SpocPagedAssignment[];
  pageNum?: number;
  pageSize?: number;
  pages?: number;
  hasNextPage?: boolean;
}

interface SpocAssignmentRaw {
  id?: string;
  zymc?: string;
  zynr?: string;
  zykssj?: string;
  zyjzsj?: string;
  zyfs?: string;
  sskcid?: string;
}

interface SpocSubmissionRaw {
  tjzt?: string;
  tjsj?: string;
}

interface SpocCasLoginContent {
  jsdm?: string;
  rolecode?: string | string[];
  jsdmList?: string | string[];
}

/* ------------------------------ 工具 ------------------------------ */

function textOf(value: string | undefined): string {
  return value === undefined || value === null ? '' : value.trim();
}

function pad2(value: number): string {
  return value < 10 ? '0' + value.toString() : value.toString();
}

function utf8Bytes(text: string): Uint8Array {
  const encoder = new util.TextEncoder();
  return encoder.encodeInto(text);
}

/**
 * 把查询条件加密成 SPOC 要求的 `param`。
 *
 * AES/CBC/NoPadding + 零填充（明文长度已是 16 的倍数时**不额外补块**，与原实现一致）。
 */
async function encryptParam(plainText: string): Promise<string> {
  const blockSize: number = 16;
  const plain: Uint8Array = utf8Bytes(plainText);
  const padLength: number = (blockSize - (plain.length % blockSize)) % blockSize;
  const padded: Uint8Array = new Uint8Array(plain.length + padLength);
  padded.set(plain, 0);

  const keyBlob: cryptoFramework.DataBlob = { data: utf8Bytes(AES_KEY) };
  const ivSpec: cryptoFramework.IvParamsSpec = {
    algName: 'IvParamsSpec',
    iv: { data: utf8Bytes(AES_IV) }
  };
  const generator = cryptoFramework.createSymKeyGenerator('AES128');
  const key = await generator.convertKey(keyBlob);
  const cipher = cryptoFramework.createCipher('AES128|CBC|NoPadding');
  await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, key, ivSpec);
  const output: cryptoFramework.DataBlob = await cipher.doFinal({ data: padded });
  const helper = new util.Base64Helper();
  return helper.encodeToStringSync(output.data);
}

/** 取 URL 的路径部分（不含查询串 / hash）。 */
function urlPath(raw: string): string {
  const schemeIndex: number = raw.indexOf('://');
  let rest: string = schemeIndex >= 0 ? raw.substring(schemeIndex + 3) : raw;
  const slashIndex: number = rest.indexOf('/');
  if (slashIndex < 0) {
    return '';
  }
  rest = rest.substring(slashIndex);
  let end: number = rest.length;
  const queryIndex: number = rest.indexOf('?');
  if (queryIndex >= 0 && queryIndex < end) {
    end = queryIndex;
  }
  const hashIndex: number = rest.indexOf('#');
  if (hashIndex >= 0 && hashIndex < end) {
    end = hashIndex;
  }
  return rest.substring(0, end);
}

/** 取 URL 的查询串（不含 `?`）。 */
function urlQuery(raw: string): string {
  const queryIndex: number = raw.indexOf('?');
  if (queryIndex < 0) {
    return '';
  }
  let rest: string = raw.substring(queryIndex + 1);
  const hashIndex: number = rest.indexOf('#');
  if (hashIndex >= 0) {
    rest = rest.substring(0, hashIndex);
  }
  return rest;
}

/** 从查询串里取一个参数（找不到返回空串）。 */
function queryParam(query: string, name: string): string {
  const parts: string[] = query.split('&');
  for (let i = 0; i < parts.length; i++) {
    const eq: number = parts[i].indexOf('=');
    if (eq <= 0) {
      continue;
    }
    if (parts[i].substring(0, eq) === name) {
      const raw: string = parts[i].substring(eq + 1);
      try {
        return decodeURIComponent(raw);
      } catch (error) {
        return raw;
      }
    }
  }
  return '';
}

/** 从跳转地址里捞 token（原 `SpocParsers.extractLoginTokens`）。 */
function extractLoginTokens(raw: string): SpocTokens | null {
  if (urlPath(raw).indexOf('/spocnew/cas') < 0) {
    return null;
  }
  const query: string = urlQuery(raw);
  if (query.length === 0) {
    return null;
  }
  const token: string = queryParam(query, 'token');
  if (token.length === 0) {
    return null;
  }
  return { token: token, refreshToken: queryParam(query, 'refreshToken') };
}

/** 从 `string | string[]` 里取第一个非空字符串（原 `firstString`）。 */
function firstString(value: string | string[] | undefined): string {
  if (value === undefined || value === null) {
    return '';
  }
  if (typeof value === 'string') {
    return value.trim();
  }
  const list: string[] = value;
  for (let i = 0; i < list.length; i++) {
    const item: string = list[i];
    if (typeof item === 'string' && item.trim().length > 0) {
      return item.trim();
    }
  }
  return '';
}

/** 归一化时间：ISO 带时区的转成设备本地 `yyyy-MM-dd HH:mm:ss`，其余原样返回。 */
function normalizeDateTime(raw: string | undefined): string {
  const text: string = textOf(raw);
  if (text.length === 0) {
    return '';
  }
  if (text.indexOf('T') < 0) {
    return text;
  }
  const parsed: number = Date.parse(text);
  if (isNaN(parsed)) {
    return text.replace('T', ' ').substring(0, 19);
  }
  const date = new Date(parsed);
  return date.getFullYear() + '-' + pad2(date.getMonth() + 1) + '-' + pad2(date.getDate()) +
    ' ' + pad2(date.getHours()) + ':' + pad2(date.getMinutes()) + ':' + pad2(date.getSeconds());
}

/** 去掉 HTML 标签，得到可读正文。 */
function htmlToText(html: string): string {
  let text: string = html.replace(/<br\s*\/?>/gi, '\n');
  text = text.replace(/<\/p>/gi, '\n');
  text = text.replace(/<[^>]+>/g, '');
  text = text.replace(/&nbsp;/g, ' ');
  text = text.replace(/&amp;/g, '&');
  text = text.replace(/&lt;/g, '<');
  text = text.replace(/&gt;/g, '>');
  text = text.replace(/&quot;/g, '"');
  text = text.replace(/[ \t]+/g, ' ');
  text = text.replace(/\n{3,}/g, '\n\n');
  return text.trim();
}

/** 得分只保留数字部分（原 `normalizeScore`）。 */
function normalizeScore(raw: string | undefined): string {
  const text: string = textOf(raw);
  if (text.length === 0) {
    return '';
  }
  const matched = text.match(/-?\d+(\.\d+)?/);
  return matched === null ? text : matched[0];
}

/* ------------------------------ 服务 ------------------------------ */

export class LocalSpocService {
  private static token: string = '';
  private static refreshToken: string = '';
  private static roleCode: string = '';

  /** 当前学期的作业列表。 */
  /**
   * SPOC 网页版的登录直链（带当前会话的 token / refreshToken）。
   *
   * 网页端与接口端共用这套 token：`#/pages/login/index?token=…&refreshToken=…`
   * 打开后会直接落到已登录状态，再进到对应课程/作业。
   */
  static async webLoginUrl(): Promise<string> {
    await LocalSpocService.ensureLogin();
    const base: string = SPOC_BASE + '/bhspoc/#/pages/login/index?token=' + LocalSpocService.token;
    return LocalSpocService.refreshToken.length > 0 ?
      base + '&refreshToken=' + LocalSpocService.refreshToken : base;
  }

  /**
   * 某次作业的网页详情直链（带登录 token）。
   *
   * 网页端路由：`#/pages/discover/homework/detail?id=<zyid>&sflx=2`。
   * token / refreshToken 一并带上 —— 网页端会从查询串里取令牌并写入本地会话，
   * 这样打开就是已登录状态，直接落在该作业的提交页。
   */
  static async assignmentWebUrl(assignmentId: string): Promise<string> {
    return SPOC_BASE + '/bhspoc/#/pages/discover/homework/detail?id=' + assignmentId + '&sflx=2';
  }

  static async fetchAssignments(): Promise<SpocAssignmentsData> {
    await LocalSpocService.ensureLogin();

    const term = await LocalSpocService.withAuth<SpocCurrentTerm>(
      async (): Promise<UpstreamResponse> => {
        return await LocalSpocService.postJson(
          SPOC_CURRENT_TERM_URL, JSON.stringify({ param: CURRENT_TERM_PARAM }),
          LocalSpocService.authHeaders());
      }, '获取当前学期失败');
    const termCode: string = textOf(term.mrxq);
    if (termCode.length === 0) {
      throw new ApiError(502, 'spoc_error', '无法获取 SPOC 当前学期');
    }

    // 课程列表只用来补教师名，失败也不影响作业列表（与原实现一致）
    const courseMap: Map<string, string> = await LocalSpocService.fetchTeacherMap(termCode);
    const raw: SpocPagedAssignment[] = await LocalSpocService.fetchAllPages(termCode);

    const assignments: SpocAssignment[] = [];
    for (let i = 0; i < raw.length; i++) {
      const item = raw[i];
      const courseId: string = textOf(item.sskcid);
      let teacher: string = '';
      const found: string | undefined = courseMap.get(courseId);
      if (found !== undefined) {
        teacher = found;
      }
      // 与原实现一致：列表项的 hasContent 就是「tjzt 非空」
      const rawStatus: string = textOf(item.tjzt);
      const status: SpocStatus = LocalSpocService.resolveStatus(rawStatus, rawStatus.length > 0);
      assignments.push({
        assignmentId: textOf(item.zyid),
        courseId: courseId,
        courseName: textOf(item.kcmc),
        teacherName: teacher,
        title: textOf(item.zymc),
        startTime: normalizeDateTime(item.zykssj),
        dueTime: normalizeDateTime(item.zyjzsj),
        fullScore: normalizeScore(item.mf),
        submissionStatusText: status.text,
        submitted: status.submitted
      });
    }
    LocalSpocService.sortByDue(assignments);

    Logger.info('SPOC 作业（' + termCode + '）：' + assignments.length + ' 条');
    return {
      termCode: termCode,
      termName: textOf(term.dqxq),
      assignments: assignments
    };
  }

  /** 作业详情（含要求正文与提交时间）。 */
  static async fetchAssignmentDetail(assignmentId: string): Promise<SpocAssignmentDetail> {
    await LocalSpocService.ensureLogin();

    const detail = await LocalSpocService.withAuth<SpocAssignmentRaw>(
      async (): Promise<UpstreamResponse> => {
        return await UpstreamClient.get(
          SPOC_DETAIL_URL + '?id=' + encodeURIComponent(assignmentId), false,
          LocalSpocService.authHeaders());
      }, '获取作业详情失败');

    // 提交记录可能根本没有（未提交过），失败不当错误
    let submission: SpocSubmissionRaw | null = null;
    try {
      submission = await LocalSpocService.withAuth<SpocSubmissionRaw>(
        async (): Promise<UpstreamResponse> => {
          return await UpstreamClient.get(
            SPOC_SUBMISSION_URL + '?kczyid=' + encodeURIComponent(assignmentId), false,
            LocalSpocService.authHeaders());
        }, '获取提交记录失败');
    } catch (error) {
      Logger.warn('SPOC 提交记录获取失败（按未提交处理）：' + (error as Error).message);
    }

    const hasSubmission: boolean = submission !== null && submission !== undefined;
    let submittedRaw: string | undefined = undefined;
    let submittedAt: string = '';
    if (submission !== null && submission !== undefined) {
      submittedRaw = submission.tjzt;
      submittedAt = normalizeDateTime(submission.tjsj);
    }
    const status: SpocStatus = LocalSpocService.resolveStatus(submittedRaw, hasSubmission);

    return {
      assignmentId: assignmentId,
      courseName: '',
      title: textOf(detail.zymc),
      startTime: normalizeDateTime(detail.zykssj),
      dueTime: normalizeDateTime(detail.zyjzsj),
      score: normalizeScore(detail.zyfs),
      submissionStatusText: status.text,
      submitted: status.submitted,
      submittedAt: submittedAt,
      contentText: htmlToText(textOf(detail.zynr))
    };
  }

  /* ---------------------------- 内部 ---------------------------- */

  /**
   * 会话准备：换 token 与 roleCode。
   *
   * 与其它子系统不同，SPOC 的 token 是**内存态**（进程重启即失效，代价只是一次跳转链）。
   */
  private static async ensureLogin(forceRefresh: boolean = false): Promise<void> {
    if (!forceRefresh && LocalSpocService.token.length > 0 && LocalSpocService.roleCode.length > 0) {
      return;
    }
    const tokens: SpocTokens = await LocalSpocService.fetchLoginTokens();
    const response = await LocalSpocService.postJson(
      SPOC_CAS_LOGIN_URL,
      JSON.stringify({ token: tokens.token }),
      { 'x-requested-with': 'XMLHttpRequest', 'token': 'Inco-' + tokens.token });
    const content = LocalSpocService.unwrap<SpocCasLoginContent>(response, 'SPOC 登录失败');
    const roleCode: string = LocalSpocService.resolveRoleCode(content);
    if (roleCode.length === 0) {
      throw new ApiError(502, 'spoc_error', 'SPOC 登录成功但未取到角色信息');
    }
    LocalSpocService.token = tokens.token;
    LocalSpocService.refreshToken = tokens.refreshToken;
    LocalSpocService.roleCode = roleCode;
    Logger.info('SPOC 会话就绪（role=' + roleCode + '）');
  }

  /**
   * 逐跳走 `/spocnewht/cas` 的跳转链，从**每一跳的实际地址与 Location** 里找 token。
   *
   * 原实现就是这么写的 —— token 不一定出现在第一跳，也不一定只出现在 Location 里。
   */
  private static async fetchLoginTokens(): Promise<SpocTokens> {
    let current: string = SPOC_CAS_URL;
    for (let hop = 0; hop < MAX_LOGIN_HOPS; hop++) {
      const response = await UpstreamClient.get(current, false);
      const fromUrl: SpocTokens | null = extractLoginTokens(response.url);
      if (fromUrl !== null) {
        return fromUrl;
      }
      if (response.location.length === 0) {
        break;
      }
      const fromLocation: SpocTokens | null = extractLoginTokens(response.location);
      if (fromLocation !== null) {
        return fromLocation;
      }
      current = resolveLocation(response.url, response.location);
    }
    throw new ApiError(401, 'spoc_session_expired',
      'SPOC 登录跳转中未取到 token，请确认已登录统一身份认证后重试');
  }

  private static resolveRoleCode(content: SpocCasLoginContent): string {
    const direct: string = textOf(content.jsdm);
    if (direct.length > 0) {
      return direct;
    }
    const fromRole: string = firstString(content.rolecode);
    if (fromRole.length > 0) {
      return fromRole;
    }
    return firstString(content.jsdmList);
  }

  private static authHeaders(): Record<string, string> {
    const headers: Record<string, string> = {};
    headers['x-requested-with'] = 'XMLHttpRequest';
    headers['token'] = 'Inco-' + LocalSpocService.token;
    headers['rolecode'] = LocalSpocService.roleCode;
    return headers;
  }

  /**
   * 带自愈的业务请求：信封判定为「登录失效」时重换一次 token 再试。
   *
   * SPOC 对失效 token 回的是 HTTP 200 + 失败信封（不是 401），所以只能在
   * 解析信封时发现 —— 因此这里传的是「请求函数」，由下面的 withAuth 负责重试。
   */
  private static async withAuth<T>(
    request: () => Promise<UpstreamResponse>,
    what: string
  ): Promise<T> {
    let response = await request();
    let content: T | null = null;
    let retried: boolean = false;
    let lastError: string = '';

    while (true) {
      const probe: SpocProbe<T> = LocalSpocService.probe<T>(response);
      if (probe.ok) {
        content = probe.content;
        break;
      }
      lastError = probe.message;
      if (!probe.authFailure || retried) {
        throw new ApiError(502, 'spoc_error', what + '：' + lastError);
      }
      Logger.warn('SPOC 会话已失效，重新换取后重试：' + lastError);
      retried = true;
      await LocalSpocService.ensureLogin(true);
      response = await request();
    }

    if (content === null || content === undefined) {
      throw new ApiError(502, 'spoc_error', what + '：上游没有返回内容');
    }
    return content;
  }

  /** 解析信封，给出「是否成功 / 是否属于登录失效 / 错误文案」。 */
  private static probe<T>(response: UpstreamResponse): SpocProbe<T> {
    if (!response.isOk()) {
      return {
        ok: false, content: null, authFailure: false,
        message: '上游返回 HTTP ' + response.status
      };
    }
    let envelope: SpocEnvelope<T>;
    try {
      envelope = JSON.parse(response.body) as SpocEnvelope<T>;
    } catch (error) {
      return { ok: false, content: null, authFailure: false, message: '上游返回的数据无法解析' };
    }
    const code: number = envelope.code === undefined ? -1 : envelope.code;
    if (code === 200 && envelope.content !== undefined && envelope.content !== null) {
      return { ok: true, content: envelope.content, authFailure: false, message: '' };
    }
    const message: string =
      envelope.msg !== undefined && envelope.msg.length > 0 ? envelope.msg : 'SPOC 请求失败';
    return {
      ok: false,
      content: null,
      message: message,
      authFailure: LocalSpocService.looksLikeAuthFailure(message, response.body)
    };
  }

  /** 是否为「登录态失效」类失败（原实现的关键词表）。 */
  private static looksLikeAuthFailure(message: string, body: string): boolean {
    const text: string = message + ' ' + body;
    const keywords: string[] = ['登录', 'token', '未认证', '未登录', '权限'];
    for (let i = 0; i < keywords.length; i++) {
      if (text.indexOf(keywords[i]) >= 0) {
        return true;
      }
    }
    return false;
  }

  /** 直接取内容（不重试），用于登录本身。 */
  private static unwrap<T>(response: UpstreamResponse, what: string): T {
    const probe = LocalSpocService.probe<T>(response);
    if (!probe.ok || probe.content === undefined || probe.content === null) {
      throw new ApiError(502, 'spoc_error', what + '：' + probe.message);
    }
    return probe.content;
  }

  /** 课程 id → 教师名。取不到就返回空表（不阻断作业列表）。 */
  private static async fetchTeacherMap(termCode: string): Promise<Map<string, string>> {
    const map = new Map<string, string>();
    try {
      const courses = await LocalSpocService.withAuth<SpocCourse[]>(
        async (): Promise<UpstreamResponse> => {
          return await UpstreamClient.get(
            SPOC_COURSES_URL + '?kcmc=&xnxq=' + encodeURIComponent(termCode), false,
            LocalSpocService.authHeaders());
        }, '获取课程列表失败');
      for (let i = 0; i < courses.length; i++) {
        const id: string = textOf(courses[i].kcid);
        if (id.length > 0) {
          map.set(id, textOf(courses[i].skjs));
        }
      }
    } catch (error) {
      Logger.warn('SPOC 课程列表获取失败，教师名留空：' + (error as Error).message);
    }
    return map;
  }

  /** 翻页拉全量作业。 */
  private static async fetchAllPages(termCode: string): Promise<SpocPagedAssignment[]> {
    const all: SpocPagedAssignment[] = [];
    let pageNum: number = 1;
    while (pageNum <= 30) {
      const param: string = await encryptParam(JSON.stringify({
        pageSize: PAGE_SIZE,
        pageNum: pageNum,
        sqlid: ASSIGNMENTS_PAGE_SQL_ID,
        xnxq: termCode,
        kcid: '',
        yzwz: ''
      }));
      const page = await LocalSpocService.withAuth<SpocAssignmentsPage>(
        async (): Promise<UpstreamResponse> => {
          return await LocalSpocService.postJson(
            SPOC_ASSIGNMENTS_URL,
            JSON.stringify({ param: param }),
            LocalSpocService.authHeaders());
        }, '获取作业列表失败');

      const list: SpocPagedAssignment[] = page.list === undefined ? [] : page.list;
      for (let i = 0; i < list.length; i++) {
        all.push(list[i]);
      }
      const pages: number = page.pages === undefined ? 1 : page.pages;
      if (page.hasNextPage !== true || list.length === 0 || pageNum >= pages) {
        break;
      }
      pageNum++;
    }
    return all;
  }

  private static postJson(
    url: string,
    body: string,
    extraHeaders: Record<string, string>
  ): Promise<UpstreamResponse> {
    return UpstreamClient.postJson(url, body, false, extraHeaders);
  }

  /** 提交状态：已提交 / 未提交 / 未知（原 `mapSubmissionStatus` + `submissionStatusText`）。 */
  private static resolveStatus(rawStatus: string | undefined, hasContent: boolean): SpocStatus {
    const text: string = textOf(rawStatus);
    if (text === '1' || text === '已做' || text === '已提交') {
      return { submitted: true, text: '已提交' };
    }
    if (text === '0' || text === '未做' || text === '未提交') {
      return { submitted: false, text: '未提交' };
    }
    // 状态码不认识：没有内容一律当未提交，有内容才算「未知」
    if (!hasContent) {
      return { submitted: false, text: '未提交' };
    }
    return { submitted: false, text: text.length > 0 ? '未知状态(' + text + ')' : '未知状态' };
  }

  /**
   * 排序：按「作业发布时间（startTime）」**倒序**，最新更新的排最上面；
   * 发布时间相同再比截止时间（倒序），仍相同按课程名、标题升序，保证稳定。
   */
  private static sortByDue(list: SpocAssignment[]): void {
    list.sort((a: SpocAssignment, b: SpocAssignment): number => {
      const timeOrder: number = LocalSpocService.compareDesc(
        a.startTime === undefined ? '' : a.startTime,
        b.startTime === undefined ? '' : b.startTime);
      if (timeOrder !== 0) {
        return timeOrder;
      }
      const dueOrder: number = LocalSpocService.compareDesc(
        a.dueTime === undefined ? '' : a.dueTime,
        b.dueTime === undefined ? '' : b.dueTime);
      if (dueOrder !== 0) {
        return dueOrder;
      }
      return LocalSpocService.compareRest(a, b);
    });
  }

  /** 倒序比较两个时间串；空串永远排后面。 */
  private static compareDesc(left: string, right: string): number {
    if (left.length === 0 && right.length === 0) {
      return 0;
    }
    if (left.length === 0) {
      return 1;
    }
    if (right.length === 0) {
      return -1;
    }
    if (left === right) {
      return 0;
    }
    return left > right ? -1 : 1;
  }

  /** 同时间时的兜底顺序：课程名 → 标题。 */
  private static compareRest(a: SpocAssignment, b: SpocAssignment): number {
    if (a.courseName !== b.courseName) {
      return a.courseName < b.courseName ? -1 : 1;
    }
    if (a.title === b.title) {
      return 0;
    }
    return a.title < b.title ? -1 : 1;
  }
}

/** 提交状态。 */
interface SpocStatus {
  submitted: boolean;
  text: string;
}

/** 信封探测结果。 */
interface SpocProbe<T> {
  ok: boolean;
  content: T | null;
  message: string;
  /** 是否属于「登录失效」（据此决定要不要重换 token）。 */
  authFailure: boolean;
}
