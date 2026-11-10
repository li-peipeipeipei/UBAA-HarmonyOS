import { AppConfig } from '../common/AppConfig';
import { Logger } from '../common/Logger';
import { ApiError } from './ApiError';
import { resolveLocation, UpstreamClient, UpstreamResponse } from './UpstreamClient';
import { LocalWebVpn } from './LocalWebVpn';
import {
  IhomeAppeal,
  IhomeCategory,
  IhomeConfig,
  IhomeEntry,
  IhomeEvaluation,
  IhomeFilter,
  IhomeHistory,
  IhomeNotice,
  IhomePage,
  IhomeReaction,
  IhomeReactionResult,
  IhomeReply,
  IhomeScope
} from '../model/ApiTypes';

/**
 * 本地模式下的 iHome（北航「接诉即办」平台，客户端直接对接 i.buaa.edu.cn）。
 *
 * ## 会话从哪来
 *
 * iHome 不认 CAS 的 Cookie，它自己发 Bearer token。换 token 的过程是一条纯跳转链：
 *
 *   GET sso.buaa.edu.cn/login?service=http://i.buaa.edu.cn/api/authLogin
 *     → …（CAS 内部若干跳）…
 *     → 302 http://i.buaa.edu.cn/web/#/?type=0&token=xxxx
 *
 * token 藏在**最后一跳 Location 的 fragment** 里，所以必须「关掉自动重定向、逐跳读
 * Location」。注意 CAS 的 service 参数固定是 http（不是 https），而真正请求时要按
 * HSTS 升到 https（见 LocalWebVpn.secureCasTransportUrl）。
 *
 * ## 本期能力（与原版一致）
 *
 * - 五个视图：诉求广场 / 我的发起 / 我的关注 / 我的评价 / 公告；
 * - 详情：正文、官方回复、处理进度、评价；
 * - 关注 / 支持：**目标状态语义** —— 先读当前状态，只有不同才发一次写请求，再回查；
 * - 公告：列表 + 详情（正文转纯文本）。
 *
 * 写操作结果不明时不重发（上游是切换接口，重发会反向切回去），只在详情刷新后恢复按钮。
 */
const IHOME_BASE: string = 'https://i.buaa.edu.cn/api';

/** CAS → iHome 的登录入口（service 必须是 http，见文件头注释）。 */
const IHOME_LOGIN_URL: string = 'https://' + AppConfig.UPSTREAM_SSO_HOST + '/login?service=' +
  encodeURIComponent('http://i.buaa.edu.cn/api/authLogin');

const IHOME_PAGE_SIZE: number = 15;

/* ------------------------------ 上游原始结构 ------------------------------ */

interface IhomeEnvelope<T> {
  code?: number;
  success?: boolean;
  data?: T;
}

interface IhomeDepartmentRaw {
  name?: string;
}

interface IhomeSqlbRaw {
  type_name?: string;
}

interface IhomeTypeRaw {
  id?: number | string;
  type_name?: string;
}

interface IhomeReplyRaw {
  content?: string;
  department?: IhomeDepartmentRaw;
  created_at?: string;
}

interface IhomeEvaluationRaw {
  id?: number | string;
  department?: IhomeDepartmentRaw;
  speed?: number | string;
  satisfaction?: number | string;
  degree?: number | string;
  content?: string;
  created_at?: string;
}

interface IhomeHistoryRaw {
  contents?: string;
  created_at?: string;
  restart?: number | string;
}

interface IhomeAppealRaw {
  id?: number | string;
  content?: string;
  publish_status_text?: string;
  sqlb?: IhomeSqlbRaw;
  publish_date?: string;
  created_at?: string;
  departments?: IhomeDepartmentRaw[];
  is_user?: number | string;
  is_follow?: number | string;
  is_praise?: number | string;
  follow_count?: number | string;
  praise_count?: number | string;
  appeal_reply?: IhomeReplyRaw[];
  appraise?: IhomeEvaluationRaw[];
  change_history?: IhomeHistoryRaw[];
  is_restart?: number | string;
}

interface IhomeRowRaw extends IhomeAppealRaw {
  appeal?: IhomeAppealRaw;
  id?: number | string;
  content?: string;
  publish_status_text?: string;
  sqlb?: IhomeSqlbRaw;
  publish_date?: string;
  created_at?: string;
  departments?: IhomeDepartmentRaw[];
  is_user?: number | string;
  is_follow?: number | string;
  is_praise?: number | string;
  follow_count?: number | string;
  praise_count?: number | string;
  appeal_reply?: IhomeReplyRaw[];
  appraise?: IhomeEvaluationRaw[];
  change_history?: IhomeHistoryRaw[];
  is_restart?: number | string;
  speed?: number | string;
  satisfaction?: number | string;
  degree?: number | string;
  department?: IhomeDepartmentRaw;
}

interface IhomePageRaw {
  data?: IhomeRowRaw[];
  current_page?: number | string;
  last_page?: number | string;
  total?: number | string;
}

interface IhomeSettingRaw {
  key?: string;
  value?: string;
}

interface IhomeTypesRaw {
  SQLB?: IhomeTypeRaw[];
}

interface IhomeNoticeRaw {
  id?: number | string;
  title?: string;
  content?: string;
  date?: string;
}

/* ------------------------------ 工具 ------------------------------ */

function intOf(value: number | string | undefined): number {
  if (value === undefined || value === null) {
    return 0;
  }
  if (typeof value === 'number') {
    return isNaN(value) ? 0 : value;
  }
  const parsed = parseInt(value, 10);
  return isNaN(parsed) ? 0 : parsed;
}

function intOrUndefined(value: number | string | undefined): number | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }
  if (typeof value === 'number') {
    return isNaN(value) ? undefined : value;
  }
  const parsed = parseInt(value, 10);
  return isNaN(parsed) ? undefined : parsed;
}

function textOf(value: string | undefined): string {
  return value === undefined || value === null ? '' : value.trim();
}

/** 富文本 → 纯文本（去标签、解实体、压缩空白）。 */
function plainText(value: string): string {
  if (value.length === 0) {
    return '';
  }
  let out = value
    .replace(/<script\b[\s\S]*?<\/script>/gi, ' ')
    .replace(/<style\b[\s\S]*?<\/style>/gi, ' ')
    .replace(/<br\s*\/?>/gi, ' ')
    .replace(/<[^>]+>/g, ' ')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'");
  out = out.replace(/\s+/g, ' ').trim();
  return out;
}

/** 取 URL 的 fragment 里的 token（形如 /web/#/?type=0&token=xxx）。 */
function tokenFromUrl(url: string): string {
  const hash = url.indexOf('#');
  if (hash < 0) {
    return '';
  }
  const fragment = url.substring(hash + 1);
  const query = fragment.indexOf('?');
  if (query < 0) {
    return '';
  }
  const pairs = fragment.substring(query + 1).split('&');
  let type = '';
  let token = '';
  for (let i = 0; i < pairs.length; i++) {
    const eq = pairs[i].indexOf('=');
    if (eq < 0) {
      continue;
    }
    const key = pairs[i].substring(0, eq);
    const value = pairs[i].substring(eq + 1);
    if (key === 'type') {
      type = value;
    } else if (key === 'token') {
      token = decodeURIComponent(value);
    }
  }
  return type === '0' ? token : '';
}

export class LocalIhomeService {
  /** 当前 iHome Bearer token（空串 = 还没换过，或已失效）。 */
  private static token: string = '';
  /** 正在进行的 token 换取（并发调用共享同一个 Promise，不重复走跳转链）。 */
  private static authPromise: Promise<string> | null = null;

  /* ------------------------------ 五个视图 ------------------------------ */

  /**
   * 列表分页。
   *
   * @param scope 广场 / 我的发起 / 我的关注 / 我的评价
   * @param keyword 仅广场支持（上游在服务端搜索正文与官方回复）
   * @param filter 排序 / 回复状态筛选
   * @param categoryId 广场的分类字典 id
   */
  static async fetchPage(
    scope: IhomeScope,
    page: number,
    keyword: string,
    filter: IhomeFilter,
    categoryId: number
  ): Promise<IhomePage> {
    let path = '/appeal';
    if (scope === IhomeScope.MINE) {
      path = '/appeal/my_appreal';
    } else if (scope === IhomeScope.FOLLOWED) {
      path = '/appeal/my_follow';
    } else if (scope === IhomeScope.APPRAISED) {
      path = '/appraise/my_appraise';
    }

    let query = '?limit=' + IHOME_PAGE_SIZE + '&page=' + page;
    if (scope === IhomeScope.PUBLIC && keyword.trim().length > 0) {
      query += '&keyword=' + encodeURIComponent(keyword.trim());
    }
    if (scope === IhomeScope.PUBLIC && categoryId > 0) {
      query += '&sqlb_id=' + categoryId;
    }
    if (scope === IhomeScope.PUBLIC || scope === IhomeScope.MINE) {
      if (filter === IhomeFilter.NEWEST) {
        query += '&publish_time=1';
      } else if (filter === IhomeFilter.OLDEST && scope === IhomeScope.PUBLIC) {
        query += '&publish_time=0';
      } else if (filter === IhomeFilter.REPLY_TIME && scope === IhomeScope.MINE) {
        query += '&reply_time=0';
      } else if (filter === IhomeFilter.REPLIED || filter === IhomeFilter.UNREPLIED) {
        const key = scope === IhomeScope.MINE ? 'is_reply' : 'reply';
        query += '&' + key + '=' + (filter === IhomeFilter.REPLIED ? '1' : '0');
      }
    }

    const data = await LocalIhomeService.readEnvelope<IhomePageRaw>(path + query);
    return LocalIhomeService.parsePage(data, scope);
  }

  /** 诉求详情。mine 为真时走「我的发起」详情接口（本人视角，字段更全）。 */
  static async fetchDetail(id: number, mine: boolean): Promise<IhomeAppeal> {
    const path = mine ? '/appeal/my_appreal/' + id : '/appeal/' + id;
    const data = await LocalIhomeService.readEnvelope<IhomeAppealRaw>(path);
    return LocalIhomeService.parseAppeal(data);
  }

  /** 支持开关是否开放 + 分类字典（广场筛选用）。 */
  static async fetchConfig(): Promise<IhomeConfig> {
    const settingsData =
      await LocalIhomeService.readEnvelope<IhomeSettingRaw[]>(
        '/general_set_more?key%5B%5D=fabulous&key%5B%5D=fabulous_show');
    const typesData = await LocalIhomeService.readEnvelope<IhomeTypesRaw>(
      '/mobile/types?type_mark=SQLB');

    let supportEnabled = false;
    let supportLabel = '支持';
    if (settingsData !== undefined && settingsData !== null) {
      for (let i = 0; i < settingsData.length; i++) {
        const key = textOf(settingsData[i].key);
        const value = textOf(settingsData[i].value);
        if (key === 'fabulous') {
          supportEnabled = value === '1';
        } else if (key === 'fabulous_show' && value.length > 0) {
          supportLabel = value;
        }
      }
    }

    const categories: IhomeCategory[] = [];
    if (typesData !== undefined && typesData !== null && typesData.SQLB !== undefined &&
      typesData.SQLB !== null) {
      for (let i = 0; i < typesData.SQLB.length; i++) {
        const raw = typesData.SQLB[i];
        const id = intOrUndefined(raw.id);
        if (id === undefined) {
          continue;
        }
        categories.push({ id: id, name: textOf(raw.type_name) });
      }
    }
    return { supportEnabled: supportEnabled, supportLabel: supportLabel, categories: categories };
  }

  static async fetchNotices(): Promise<IhomeNotice[]> {
    const data = await LocalIhomeService.readEnvelope<IhomeNoticeRaw[]>('/notice');
    const out: IhomeNotice[] = [];
    if (data === undefined || data === null) {
      return out;
    }
    for (let i = 0; i < data.length; i++) {
      out.push(LocalIhomeService.parseNotice(data[i]));
    }
    return out;
  }

  /**
   * 关注 / 支持。
   *
   * 上游接口是**切换**语义，所以这里按目标状态处理：读当前状态 → 相同就直接返回 →
   * 不同才发一次 → 回查确认。写失败或结果不明都**不重发**。
   */
  static async setReaction(
    id: number,
    reaction: IhomeReaction,
    enabled: boolean
  ): Promise<IhomeReactionResult> {
    const before = await LocalIhomeService.fetchDetail(id, false);
    const current = reaction === IhomeReaction.FOLLOW ? before.isFollowed : before.isSupported;
    if (current === enabled) {
      return { appeal: before, confirmed: true, message: '' };
    }
    if (reaction === IhomeReaction.SUPPORT) {
      const config = await LocalIhomeService.fetchConfig();
      if (!config.supportEnabled) {
        throw new ApiError(503, 'ihome_disabled', '平台当前未开放支持功能');
      }
    }
    if (current === undefined) {
      throw new ApiError(502, 'ihome_protocol', '无法确认当前操作状态，请刷新后重试');
    }

    let rejected = false;
    try {
      const token = await LocalIhomeService.ensureToken();
      const headers: Record<string, string> = {};
      headers['authorization'] = 'Bearer ' + token;
      const path = reaction === IhomeReaction.FOLLOW
        ? IHOME_BASE + '/appeal_follow/' + id
        : IHOME_BASE + '/appeal/appeal_praise/' + id;
      let response: UpstreamResponse;
      if (reaction === IhomeReaction.FOLLOW) {
        response = await UpstreamClient.postJson(path, '{}', true, headers);
      } else {
        response = await UpstreamClient.postForm(path, '', true, headers);
      }
      if (response.status === 401) {
        LocalIhomeService.token = '';
      }
      if (response.status < 200 || response.status >= 300) {
        rejected = true;
      } else {
        LocalIhomeService.parseEnvelope<object>(response.body);
      }
    } catch (error) {
      Logger.warn('iHome 写操作结果不明（' + reaction + '）：' + (error as Error).message);
    }

    let after: IhomeAppeal | undefined = undefined;
    try {
      after = await LocalIhomeService.fetchDetail(id, false);
    } catch (error) {
      Logger.warn('iHome 写操作回查失败：' + (error as Error).message);
    }
    const confirmed = after !== undefined &&
      (reaction === IhomeReaction.FOLLOW ? after.isFollowed : after.isSupported) === enabled;
    let message = '操作结果未确认，请刷新后再操作';
    if (confirmed) {
      message = '';
    } else if (rejected) {
      message = '操作未完成，请刷新确认当前状态';
    }
    return { appeal: after, confirmed: confirmed, message: message };
  }

  /* ------------------------------ 会话 ------------------------------ */

  private static async ensureToken(): Promise<string> {
    if (LocalIhomeService.token.length > 0) {
      return LocalIhomeService.token;
    }
    // 首屏会并发发起「配置 + 列表」两个请求，这里共享同一次换取，不能直接抛错
    if (LocalIhomeService.authPromise !== null) {
      return await LocalIhomeService.authPromise;
    }
    const pending = LocalIhomeService.obtainToken();
    LocalIhomeService.authPromise = pending;
    try {
      return await pending;
    } finally {
      LocalIhomeService.authPromise = null;
    }
  }

  private static async obtainToken(): Promise<string> {
    try {
      let next = IHOME_LOGIN_URL;
      for (let hop = 0; hop < 12; hop++) {
        const token = tokenFromUrl(next);
        if (token.length > 0) {
          LocalIhomeService.token = token;
          Logger.info('iHome token 已获取（第 ' + (hop + 1) + ' 跳）');
          return token;
        }
        const response = await UpstreamClient.get(next, false);
        if (response.status >= 500) {
          throw new ApiError(502, 'ihome_upstream', 'iHome 登录服务暂时不可用，请稍后重试');
        }
        if (!response.isRedirect()) {
          throw new ApiError(401, 'ihome_auth', '无法复用统一认证登录，请重新登录 UBAA');
        }
        const resolved = resolveLocation(response.url, response.location);
        const unwrapped = await LocalWebVpn.fromWebVpnUrl(resolved);
        next = LocalWebVpn.secureCasTransportUrl(unwrapped);
      }
      throw new ApiError(401, 'ihome_auth', 'iHome 登录跳转次数过多');
    } catch (error) {
      LocalIhomeService.token = '';
      throw error as Error;
    }
  }

  /** 带 Bearer 的 GET；401 时清 token 重试一次。 */
  private static async read(pathAndQuery: string, retry: boolean): Promise<string> {
    const token = await LocalIhomeService.ensureToken();
    const headers: Record<string, string> = {};
    headers['authorization'] = 'Bearer ' + token;
    const response = await UpstreamClient.get(IHOME_BASE + pathAndQuery, true, headers);
    if (response.status === 401) {
      if (retry) {
        LocalIhomeService.token = '';
        return await LocalIhomeService.read(pathAndQuery, false);
      }
      throw new ApiError(401, 'ihome_auth', 'iHome 登录已失效，请重新登录');
    }
    if (!response.isOk()) {
      throw new ApiError(502, 'ihome_upstream', 'iHome 暂时不可用，请稍后重试');
    }
    return response.body;
  }

  private static async readEnvelope<T>(pathAndQuery: string): Promise<T> {
    const body = await LocalIhomeService.read(pathAndQuery, true);
    return LocalIhomeService.parseEnvelope<T>(body);
  }

  private static parseEnvelope<T>(body: string): T {
    let envelope: IhomeEnvelope<T>;
    try {
      envelope = JSON.parse(body) as IhomeEnvelope<T>;
    } catch (error) {
      throw new ApiError(502, 'ihome_protocol', 'iHome 返回了无法识别的数据');
    }
    if (envelope.code !== 20000 || envelope.success !== true || envelope.data === undefined) {
      throw new ApiError(502, 'ihome_business', 'iHome 暂时无法完成此操作，请刷新后重试');
    }
    return envelope.data;
  }

  /* ------------------------------ 解析 ------------------------------ */

  private static parsePage(data: IhomePageRaw, scope: IhomeScope): IhomePage {
    const entries: IhomeEntry[] = [];
    const rows = data.data === undefined || data.data === null ? [] : data.data;
    for (let i = 0; i < rows.length; i++) {
      const row = rows[i];
      if (scope === IhomeScope.APPRAISED) {
        const appealRaw = row.appeal;
        const appeal = appealRaw === undefined ? LocalIhomeService.emptyAppeal()
          : LocalIhomeService.parseAppeal(appealRaw);
        entries.push({
          appeal: appeal,
          evaluation: LocalIhomeService.buildEvaluation(
            intOf(row.id),
            row.department === undefined ? '' : textOf(row.department.name),
            intOf(row.speed), intOf(row.satisfaction), intOf(row.degree),
            plainText(textOf(row.content)), textOf(row.created_at))
        });
      } else {
        entries.push({ appeal: LocalIhomeService.parseAppeal(row) });
      }
    }
    return {
      entries: entries,
      page: intOf(data.current_page),
      lastPage: intOf(data.last_page),
      total: intOf(data.total)
    };
  }

  private static emptyAppeal(): IhomeAppeal {
    return {
      id: 0,
      content: '',
      status: '',
      category: '',
      publishedAt: '',
      departments: [],
      isMine: false,
      replies: [],
      evaluations: [],
      history: []
    };
  }

  private static parseAppeal(raw: IhomeAppealRaw): IhomeAppeal {
    const restart = intOf(raw.is_restart);
    const departments: string[] = [];
    if (raw.departments !== undefined && raw.departments !== null) {
      for (let i = 0; i < raw.departments.length; i++) {
        const name = textOf(raw.departments[i].name);
        if (name.length > 0) {
          departments.push(name);
        }
      }
    }

    const replies: IhomeReply[] = [];
    if (raw.appeal_reply !== undefined && raw.appeal_reply !== null) {
      for (let i = 0; i < raw.appeal_reply.length; i++) {
        const item = raw.appeal_reply[i];
        replies.push({
          content: plainText(textOf(item.content)),
          department: item.department === undefined ? '' : textOf(item.department.name),
          createdAt: textOf(item.created_at)
        });
      }
    }

    const evaluations: IhomeEvaluation[] = [];
    if (raw.appraise !== undefined && raw.appraise !== null) {
      for (let i = 0; i < raw.appraise.length; i++) {
        evaluations.push(LocalIhomeService.parseEvaluation(raw.appraise[i]));
      }
    }

    const history: IhomeHistory[] = [];
    if (raw.change_history !== undefined && raw.change_history !== null) {
      for (let i = 0; i < raw.change_history.length; i++) {
        const item = raw.change_history[i];
        if (intOf(item.restart) !== restart) {
          continue;
        }
        history.push({
          content: plainText(textOf(item.contents)),
          createdAt: textOf(item.created_at)
        });
      }
    }

    const follow = intOrUndefined(raw.is_follow);
    const support = intOrUndefined(raw.is_praise);
    const publishedAt = textOf(raw.publish_date).length > 0
      ? textOf(raw.publish_date) : textOf(raw.created_at);

    return {
      id: intOf(raw.id),
      content: plainText(textOf(raw.content)),
      status: textOf(raw.publish_status_text),
      category: raw.sqlb === undefined ? '' : textOf(raw.sqlb.type_name),
      publishedAt: publishedAt,
      departments: departments,
      isMine: intOf(raw.is_user) === 1,
      isFollowed: follow === undefined ? undefined : follow === 1,
      isSupported: support === undefined ? undefined : support === 1,
      followCount: intOrUndefined(raw.follow_count),
      supportCount: intOrUndefined(raw.praise_count),
      replies: replies,
      evaluations: evaluations,
      history: history
    };
  }

  private static parseEvaluation(raw: IhomeEvaluationRaw): IhomeEvaluation {
    return LocalIhomeService.buildEvaluation(
      intOf(raw.id),
      raw.department === undefined ? '' : textOf(raw.department.name),
      intOf(raw.speed), intOf(raw.satisfaction), intOf(raw.degree),
      plainText(textOf(raw.content)), textOf(raw.created_at));
  }

  private static buildEvaluation(
    id: number,
    department: string,
    speed: number,
    satisfaction: number,
    degree: number,
    content: string,
    createdAt: string
  ): IhomeEvaluation {
    return {
      id: id,
      department: department,
      speed: speed,
      satisfaction: satisfaction,
      degree: degree,
      content: content,
      createdAt: createdAt
    };
  }

  private static parseNotice(raw: IhomeNoticeRaw): IhomeNotice {
    return {
      id: intOf(raw.id),
      title: textOf(raw.title),
      content: plainText(textOf(raw.content)),
      date: textOf(raw.date)
    };
  }
}
