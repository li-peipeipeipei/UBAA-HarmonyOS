import { AppConfig } from '../common/AppConfig';
import { Logger } from '../common/Logger';
import { ApiError } from './ApiError';
import { UpstreamClient, UpstreamResponse } from './UpstreamClient';
import {
  JudgeAssignmentDetail,
  JudgeAssignmentSummary,
  JudgeAssignmentsResponse,
  JudgeProblem,
  JudgeStatus
} from '../model/ApiTypes';

/**
 * 本地模式下的「希冀作业」（客户端直接抓 judge.buaa.edu.cn 的网页）。
 *
 * ## 上游契约
 *
 * 照抄原 UBAA 的 shared/.../local/LocalJudgeApi.kt：希冀没有 JSON 接口，只有服务端
 * 渲染的 HTML 表格，所以整个模块的价值都在「解析」上。四类页面：
 *
 * | 页面 | 地址 | 用途 |
 * | --- | --- | --- |
 * | 课程列表 | /courselist.jsp?courseID=0 | 抓 courseID 与课程名 |
 * | 选课 | /courselist.jsp?courseID=<id> | 把会话切到某门课（后续页面依赖这个状态） |
 * | 作业列表 | /assignment/index.jsp | 抓 assignID 与作业名 |
 * | 作业详情 | /assignment/index.jsp?assignID=<id> | 时间 / 满分 / 题目与提交状态 |
 *
 * ## 为什么要先「选课」
 *
 * 希冀把「当前课程」存在服务端会话里，作业列表与详情页都只认这个状态，URL 里
 * 不带课程 id。所以每门课都要先打一次 courselist.jsp?courseID= 才能读到它的作业。
 * 也正因为状态在服务端，本模块只能串行请求（并发会互相把课程切走）。
 *
 * ## 六个月的「历史作业」规则
 *
 * 原版用「作业开始时间早于六个月」判断课程是否已经结课：默认模式下遇到第一条历史
 * 作业就停止，避免为几百门结课课程白跑请求；includeExpired 打开后不再截断。
 */
const JUDGE_BASE: string = 'https://judge.buaa.edu.cn';

/** 希冀的 CAS 入口（service 指回希冀首页）。 */
const JUDGE_LOGIN_URL: string = 'https://' + AppConfig.UPSTREAM_SSO_HOST + '/login?service=' +
  encodeURIComponent(JUDGE_BASE + '/');

const JUDGE_ACCEPT: string =
  'text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,*/*;q=0.8';

/** 课程（希冀内部 id + 名称）。 */
interface JudgeCourseRaw {
  courseId: string;
  courseName: string;
}

/** 作业（列表页抓到的原始条目）。 */
interface JudgeAssignmentRaw {
  assignmentId: string;
  courseId: string;
  courseName: string;
  title: string;
}

/** 详情解析的中间结果（题目 + 该题得分）。 */
class ParsedProblem {
  problem: JudgeProblem;
  earnedScore: number | null = null;

  constructor(problem: JudgeProblem) {
    this.problem = problem;
  }
}

/* ------------------------------ 文本工具 ------------------------------ */

const TAG_REGEX: RegExp = /<[^>]+>/g;
const WHITESPACE_REGEX: RegExp = /\s+/g;

function decodeEntities(value: string): string {
  return value
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')
    .replace(/&lt;/g, '<')
    .replace(/&gt;/g, '>')
    .replace(/&quot;/g, '"')
    .replace(/&#39;/g, "'");
}

function stripTags(value: string): string {
  return value.replace(TAG_REGEX, ' ');
}

function cleanText(value: string): string {
  return decodeEntities(value).replace(/\u00a0/g, ' ').replace(WHITESPACE_REGEX, ' ').trim();
}

/** 收集一个正则的全部匹配（避免不同引擎对 matchAll 的支持差异）。 */
function findAll(regex: RegExp, text: string): RegExpExecArray[] {
  const out: RegExpExecArray[] = [];
  regex.lastIndex = 0;
  let matched = regex.exec(text);
  while (matched !== null) {
    out.push(matched);
    if (matched.index === regex.lastIndex) {
      regex.lastIndex++;
    }
    matched = regex.exec(text);
  }
  return out;
}

function normalizeDateTime(value: string): string {
  let colons = 0;
  for (let i = 0; i < value.length; i++) {
    if (value.charAt(i) === ':') {
      colons++;
    }
  }
  return colons === 1 ? value + ':00' : value;
}

function formatScore(value: number): string {
  return value === Math.floor(value) ? Math.floor(value).toString() : value.toString();
}

/** 从「得分：8」里取分数。 */
function parseEarnedScore(value: string): number | null {
  const matched = /得分[：:]\s*([\d.]+)/.exec(cleanText(value));
  if (matched === null) {
    return null;
  }
  const parsed = parseFloat(matched[1]);
  return isNaN(parsed) ? null : parsed;
}

function parseScoreNumber(value: string): number | null {
  const text = cleanText(value);
  if (!/^\d+(?:\.\d+)?$/.test(text)) {
    return null;
  }
  const parsed = parseFloat(text);
  return isNaN(parsed) ? null : parsed;
}

/* ------------------------------ 服务 ------------------------------ */

export class LocalJudgeService {
  /** 本次进程是否已打通希冀会话。 */
  private static activated: boolean = false;
  /** 课程列表缓存（同一进程内复用；课程清单不受选课状态影响）。 */
  private static courses: JudgeCourseRaw[] = [];
  /** 详情缓存（课程 id + 作业 id → 详情），详情页复用时不必再抓一次。 */
  private static details: Map<string, JudgeAssignmentDetail> = new Map<string, JudgeAssignmentDetail>();

  /* ------------------------------ 对外 ------------------------------ */

  /**
   * 作业列表。
   *
   * @param includeExpired 是否包含六个月以前的历史作业（默认 false，遇到即停止）
   */
  static async fetchAssignments(includeExpired: boolean): Promise<JudgeAssignmentsResponse> {
    await LocalJudgeService.ensureSession();
    const courses = await LocalJudgeService.fetchCourses();
    const assignments: JudgeAssignmentSummary[] = [];
    const cutoffCourses: string[] = [];

    for (let i = 0; i < courses.length; i++) {
      const course = courses[i];
      await LocalJudgeService.selectCourse(course.courseId);
      const raws = await LocalJudgeService.fetchAssignmentList(course);
      let reachedCutoff = false;
      let courseCount = 0;
      for (let j = 0; j < raws.length; j++) {
        let detail: JudgeAssignmentDetail | null = null;
        try {
          detail = await LocalJudgeService.fetchDetailInternal(course, raws[j]);
        } catch (error) {
          Logger.warn('希冀作业详情解析失败（' + raws[j].title + '）：' + (error as Error).message);
        }
        if (detail === null) {
          continue;
        }
        if (LocalJudgeService.startedBeforeCutoff(detail.startTime)) {
          reachedCutoff = true;
          if (!includeExpired) {
            break;
          }
        }
        assignments.push(LocalJudgeService.toSummary(detail));
        courseCount++;
      }
      if (reachedCutoff && courseCount === 0) {
        cutoffCourses.push(course.courseId);
      }
    }

    assignments.sort((a: JudgeAssignmentSummary, b: JudgeAssignmentSummary): number => {
      const left = a.dueTime === undefined ? '9999-99-99 99:99:99' : a.dueTime;
      const right = b.dueTime === undefined ? '9999-99-99 99:99:99' : b.dueTime;
      if (left !== right) {
        return left < right ? -1 : 1;
      }
      if (a.courseName !== b.courseName) {
        return a.courseName < b.courseName ? -1 : 1;
      }
      if (a.title === b.title) {
        return 0;
      }
      return a.title < b.title ? -1 : 1;
    });

    Logger.info('希冀作业：' + courses.length + ' 门课程，共 ' + assignments.length + ' 条作业');
    return { assignments: assignments, historicalCutoffCourseIds: cutoffCourses };
  }

  /**
   * 单条作业详情（详情页用；命中缓存则不重复请求）。
   *
   * @throws ApiError 会话失效 / 作业不存在 / 上游异常
   */
  static async fetchDetail(courseId: string, assignmentId: string): Promise<JudgeAssignmentDetail> {
    const key = courseId + '|' + assignmentId;
    const cached = LocalJudgeService.details.get(key);
    if (cached !== undefined) {
      return cached;
    }
    await LocalJudgeService.ensureSession();
    const courses = await LocalJudgeService.fetchCourses();
    let course: JudgeCourseRaw | null = null;
    for (let i = 0; i < courses.length; i++) {
      if (courses[i].courseId === courseId) {
        course = courses[i];
        break;
      }
    }
    if (course === null) {
      throw new ApiError(404, 'judge_not_found', '希冀作业不存在或无权限访问，请刷新后重试');
    }
    await LocalJudgeService.selectCourse(courseId);
    const raws = await LocalJudgeService.fetchAssignmentList(course);
    let raw: JudgeAssignmentRaw | null = null;
    for (let i = 0; i < raws.length; i++) {
      if (raws[i].assignmentId === assignmentId) {
        raw = raws[i];
        break;
      }
    }
    if (raw === null) {
      throw new ApiError(404, 'judge_not_found', '希冀作业不存在或无权限访问，请刷新后重试');
    }
    const detail = await LocalJudgeService.fetchDetailInternal(course, raw);
    if (detail === null) {
      throw new ApiError(404, 'judge_not_found', '希冀作业详情为空，请刷新后重试');
    }
    return detail;
  }

  /* ---------------------------- 会话 / 请求 ---------------------------- */

  private static async ensureSession(): Promise<void> {
    if (LocalJudgeService.activated) {
      return;
    }
    const startedAt = Date.now();
    // ⚠️ 必须逐跳跟随（而不是让 RCP 自动重定向）：CAS 在中间某一跳才下发希冀的
    // JSESSIONID，自动重定向只保留最后一跳的响应头，中间那枚 Cookie 会丢，
    // 结果「登录成功」却拿不到课程（courselist.jsp 又被 302 回 main.jsp）。
    const response = await UpstreamClient.follow(JUDGE_LOGIN_URL,
      LocalJudgeService.browserHeaders());
    if (LocalJudgeService.sessionExpired(response)) {
      throw new ApiError(401, 'invalid_token', '希冀登录状态异常，请重新登录后重试');
    }
    if (!response.isOk()) {
      throw new ApiError(response.status, 'judge_error',
        '希冀服务暂时不可用（HTTP ' + response.status + '），请稍后重试');
    }
    LocalJudgeService.activated = true;
    Logger.info('希冀会话就绪（' + (Date.now() - startedAt) + 'ms）');
  }

  /** 抓一页 HTML；会话掉了就重建一次再重试。 */
  private static async fetchHtml(url: string, retry: boolean): Promise<string> {
    const response = await UpstreamClient.get(url, true, LocalJudgeService.browserHeaders());
    const body = response.body;
    if (LocalJudgeService.sessionExpired(response)) {
      if (retry) {
        LocalJudgeService.activated = false;
        await LocalJudgeService.ensureSession();
        return await LocalJudgeService.fetchHtml(url, false);
      }
      throw new ApiError(401, 'invalid_token', '希冀登录状态异常，请重新登录后重试');
    }
    if (!response.isOk()) {
      throw new ApiError(response.status, 'judge_error',
        '希冀服务暂时不可用（HTTP ' + response.status + '），请稍后重试');
    }
    return body;
  }

  /** 希冀要浏览器 UA / Accept，否则可能直接回登录页。 */
  private static browserHeaders(): Record<string, string> {
    const headers: Record<string, string> = {};
    headers['accept'] = JUDGE_ACCEPT;
    headers['accept-language'] = 'zh-CN,zh;q=0.9';
    headers['referer'] = 'https://judge.buaa.edu.cn/';
    return headers;
  }

  private static async selectCourse(courseId: string): Promise<void> {
    await LocalJudgeService.fetchHtml(JUDGE_BASE + '/courselist.jsp?courseID=' + courseId, true);
  }

  private static async fetchCourses(): Promise<JudgeCourseRaw[]> {
    if (LocalJudgeService.courses.length > 0) {
      return LocalJudgeService.courses;
    }
    const html = await LocalJudgeService.fetchHtml(JUDGE_BASE + '/courselist.jsp?courseID=0', true);
    const courses = LocalJudgeService.parseCourses(html);
    if (courses.length === 0) {
      // 2026-10-26 真机实测：judge 已改成 SPA，courselist.jsp 会被 302 到 main.jsp，
      // 旧 HTML 解析拿不到课程。这里明确报错，避免界面把「读不到」伪装成「没有作业」。
      throw new ApiError(502, 'judge_error',
        '未能读取希冀课程列表（希冀页面已改版或登录态异常），请稍后重试');
    }
    LocalJudgeService.courses = courses;
    return courses;
  }

  private static async fetchAssignmentList(course: JudgeCourseRaw): Promise<JudgeAssignmentRaw[]> {
    const html = await LocalJudgeService.fetchHtml(JUDGE_BASE + '/assignment/index.jsp', true);
    return LocalJudgeService.parseAssignments(html, course);
  }

  private static async fetchDetailInternal(
    course: JudgeCourseRaw,
    raw: JudgeAssignmentRaw
  ): Promise<JudgeAssignmentDetail | null> {
    const key = course.courseId + '|' + raw.assignmentId;
    const cached = LocalJudgeService.details.get(key);
    if (cached !== undefined) {
      return cached;
    }
    const html = await LocalJudgeService.fetchHtml(
      JUDGE_BASE + '/assignment/index.jsp?assignID=' + raw.assignmentId, true);
    if (LocalJudgeService.isNativeLoginPage(html)) {
      LocalJudgeService.activated = false;
      throw new ApiError(401, 'invalid_token', '希冀登录状态异常，请重新登录后重试');
    }
    const detail = LocalJudgeService.parseAssignmentDetail(
      html, course.courseId, course.courseName, raw.assignmentId, raw.title);
    LocalJudgeService.details.set(key, detail);
    return detail;
  }

  /* ---------------------------- 解析：列表 ---------------------------- */

  private static parseCourses(html: string): JudgeCourseRaw[] {
    const regex =
      /<a\b[^>]*href\s*=\s*["']([^"']*courselist\.jsp\?courseID=(\d+)[^"']*)["'][^>]*>([\s\S]*?)<\/a>/gi;
    const matches = findAll(regex, html);
    const out: JudgeCourseRaw[] = [];
    const seen: string[] = [];
    for (let i = 0; i < matches.length; i++) {
      const courseId = matches[i][2];
      if (courseId === '0' || seen.indexOf(courseId) >= 0) {
        continue;
      }
      const courseName = cleanText(stripTags(matches[i][3]));
      if (courseName.length === 0) {
        continue;
      }
      seen.push(courseId);
      out.push({ courseId: courseId, courseName: courseName });
    }
    return out;
  }

  private static parseAssignments(html: string, course: JudgeCourseRaw): JudgeAssignmentRaw[] {
    const regex =
      /<a\b[^>]*href\s*=\s*["']([^"']*assignID=(\d+)[^"']*)["'][^>]*>([\s\S]*?)<\/a>/gi;
    const matches = findAll(regex, html);
    const out: JudgeAssignmentRaw[] = [];
    const seen: string[] = [];
    for (let i = 0; i < matches.length; i++) {
      const href = matches[i][1];
      const assignmentId = matches[i][2];
      if (href.indexOf('problemContent') >= 0 || href.indexOf('judgeDetails') >= 0) {
        continue;
      }
      if (seen.indexOf(assignmentId) >= 0) {
        continue;
      }
      const title = cleanText(stripTags(matches[i][3]));
      if (title.length === 0) {
        continue;
      }
      seen.push(assignmentId);
      out.push({
        assignmentId: assignmentId,
        courseId: course.courseId,
        courseName: course.courseName,
        title: title
      });
    }
    return out;
  }

  /* ---------------------------- 解析：详情 ---------------------------- */

  private static parseAssignmentDetail(
    html: string,
    courseId: string,
    courseName: string,
    assignmentId: string,
    title: string
  ): JudgeAssignmentDetail {
    const plainText = LocalJudgeService.htmlToText(html);
    const timeMatched =
      /作业时间[：:]\s*(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}(?::\d{2})?)\s*至\s*(\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}(?::\d{2})?)/.exec(plainText);
    const maxMatched = /作业满分[：:]\s*([\d.]+)/.exec(plainText);
    const totalMatched = /共\s*(\d+)\s*道/.exec(plainText);
    const scoreMatched = /总分[：:]\s*([\d.]+)/.exec(plainText);

    const parsedProblems = LocalJudgeService.parseProblems(html);
    const earnedScores: number[] = [];
    for (let i = 0; i < parsedProblems.length; i++) {
      if (parsedProblems[i].earnedScore !== null) {
        earnedScores.push(parsedProblems[i].earnedScore as number);
      }
    }
    const problems: JudgeProblem[] = [];
    let submittedCount = 0;
    for (let i = 0; i < parsedProblems.length; i++) {
      problems.push(parsedProblems[i].problem);
      if (parsedProblems[i].problem.status !== JudgeStatus.UNSUBMITTED) {
        submittedCount++;
      }
    }

    let totalProblems = totalMatched === null ? 0 : parseInt(totalMatched[1], 10);
    if (isNaN(totalProblems)) {
      totalProblems = 0;
    }
    if (totalProblems === 0 && problems.length > 0) {
      totalProblems = problems.length;
    }
    if (problems.length === 0) {
      submittedCount = LocalJudgeService.estimateSubmittedCount(plainText);
    }

    let myScore: string | undefined = undefined;
    if (scoreMatched !== null) {
      myScore = scoreMatched[1];
    } else if (earnedScores.length > 0) {
      let sum = 0;
      for (let i = 0; i < earnedScores.length; i++) {
        sum += earnedScores[i];
      }
      myScore = formatScore(sum);
    }

    const status = LocalJudgeService.resolveStatus(totalProblems, submittedCount);
    const detail: JudgeAssignmentDetail = {
      courseId: courseId,
      courseName: courseName,
      assignmentId: assignmentId,
      title: title,
      startTime: timeMatched === null ? undefined : normalizeDateTime(timeMatched[1]),
      dueTime: timeMatched === null ? undefined : normalizeDateTime(timeMatched[2]),
      maxScore: maxMatched === null ? undefined : LocalJudgeService.formatScoreText(maxMatched[1]),
      myScore: myScore === undefined ? undefined : LocalJudgeService.formatScoreText(myScore),
      totalProblems: totalProblems,
      submittedCount: submittedCount,
      submissionStatus: status,
      submissionStatusText: LocalJudgeService.submissionText(
        status, submittedCount, totalProblems, myScore,
        maxMatched === null ? undefined : maxMatched[1]),
      problems: problems,
      contentPlainText: plainText.length > 0 ? plainText : undefined
    };
    return detail;
  }

  private static formatScoreText(value: string): string {
    const parsed = parseFloat(value);
    return isNaN(parsed) ? value : formatScore(parsed);
  }

  private static parseProblems(html: string): ParsedProblem[] {
    const tables = LocalJudgeService.extractTopLevelTables(html);
    const out: ParsedProblem[] = [];
    for (let i = 0; i < tables.length; i++) {
      const rows = findAll(/<tr\b[^>]*>([\s\S]*?)<\/tr>/gi,
        LocalJudgeService.removeNestedTables(tables[i]));
      for (let j = 0; j < rows.length; j++) {
        const cells: string[] = [];
        const cellMatches = findAll(/<(?:th|td)\b[^>]*>([\s\S]*?)<\/(?:th|td)>/gi, rows[j][1]);
        for (let k = 0; k < cellMatches.length; k++) {
          cells.push(cleanText(stripTags(cellMatches[k][1])));
        }
        const parsed = LocalJudgeService.parseProblemFromCells(cells);
        if (parsed !== null) {
          out.push(parsed);
        }
      }
    }
    return out;
  }

  private static parseProblemFromCells(cells: string[]): ParsedProblem | null {
    if (cells.length >= 4) {
      const maxScore = parseScoreNumber(cells[2]);
      if (maxScore === null) {
        return null;
      }
      let statusText = '';
      for (let i = 3; i < cells.length; i++) {
        statusText += (statusText.length > 0 ? ' ' : '') + cells[i];
      }
      const status = LocalJudgeService.detectProblemStatus(statusText);
      if (status === null) {
        return null;
      }
      const earned = parseEarnedScore(statusText);
      let score: string | undefined = undefined;
      if (earned !== null) {
        score = formatScore(earned);
      } else if (status === JudgeStatus.SUBMITTED) {
        score = formatScore(maxScore);
      }
      const problem: JudgeProblem = {
        name: cells[1],
        score: score,
        maxScore: formatScore(maxScore),
        status: status,
        statusText: LocalJudgeService.problemText(status)
      };
      const parsed = new ParsedProblem(problem);
      parsed.earnedScore = earned;
      return parsed;
    }

    if (cells.length === 2) {
      const status = LocalJudgeService.detectProblemStatus(cells[1]);
      if (status === null) {
        return null;
      }
      const earned = parseEarnedScore(cells[1]);
      let index = cells[0].trim();
      while (index.endsWith('.')) {
        index = index.substring(0, index.length - 1).trim();
      }
      const name = index.length === 0 ? '题目' : '第' + index + '题';
      const problem: JudgeProblem = {
        name: name,
        score: earned === null ? undefined : formatScore(earned),
        maxScore: earned === null ? undefined : formatScore(earned),
        status: status,
        statusText: LocalJudgeService.problemText(status)
      };
      const parsed = new ParsedProblem(problem);
      parsed.earnedScore = earned;
      return parsed;
    }
    return null;
  }

  /** 逐个扫描 table 标签，取出最外层表格（含嵌套内容）。 */
  private static extractTopLevelTables(html: string): string[] {
    const tables: string[] = [];
    const matches = findAll(/<\/?table\b[^>]*>/gi, html);
    let depth = 0;
    let start = -1;
    for (let i = 0; i < matches.length; i++) {
      const matched = matches[i];
      const opening = !matched[0].startsWith('</');
      const end = matched.index + matched[0].length;
      if (opening) {
        if (depth === 0) {
          start = matched.index;
        }
        depth++;
      } else if (depth > 0) {
        depth--;
        if (depth === 0 && start >= 0) {
          tables.push(html.substring(start, end));
          start = -1;
        }
      }
    }
    return tables;
  }

  /** 去掉表格里的嵌套表格，只留下最外层自己的行。 */
  private static removeNestedTables(tableHtml: string): string {
    let output = '';
    let depth = 0;
    let lastIndex = 0;
    const matches = findAll(/<\/?table\b[^>]*>/gi, tableHtml);
    for (let i = 0; i < matches.length; i++) {
      const matched = matches[i];
      const opening = !matched[0].startsWith('</');
      const begin = matched.index;
      const end = matched.index + matched[0].length;
      if (opening) {
        if (depth <= 1) {
          output += tableHtml.substring(lastIndex, begin);
        }
        depth++;
        if (depth <= 1) {
          output += matched[0];
        }
      } else {
        if (depth <= 1) {
          output += tableHtml.substring(lastIndex, begin);
          output += matched[0];
        }
        if (depth > 0) {
          depth--;
        }
      }
      lastIndex = end;
    }
    if (depth <= 1 && lastIndex < tableHtml.length) {
      output += tableHtml.substring(lastIndex);
    }
    return output;
  }

  /** 没有题目表格时的兜底：数「得分：x」与提交时间戳出现次数。 */
  private static estimateSubmittedCount(text: string): number {
    let choiceEnd = text.length;
    const sections: string[] = ['填空题', '编程题', '文件上传题'];
    for (let i = 0; i < sections.length; i++) {
      const index = text.indexOf(sections[i]);
      if (index >= 0 && index < choiceEnd) {
        choiceEnd = index;
      }
    }
    const choiceCount = findAll(/得分[：:]\s*[\d.]+/g, text.substring(0, choiceEnd)).length;

    let fillCount = 0;
    const fillStart = text.indexOf('填空题');
    if (fillStart >= 0) {
      let nextSection = text.length;
      for (let i = 0; i < 2; i++) {
        const label = i === 0 ? '编程题' : '文件上传题';
        const index = text.indexOf(label, fillStart + 2);
        if (index >= 0 && index < nextSection) {
          nextSection = index;
        }
      }
      fillCount = findAll(/得分[：:]\s*[\d.]+/g, text.substring(fillStart, nextSection)).length;
    }

    let programmingCount = 0;
    const programmingStart = text.indexOf('编程题');
    if (programmingStart >= 0) {
      programmingCount = findAll(/最后一次提交时间/g, text.substring(programmingStart)).length;
    }

    let fileCount = 0;
    const fileStart = text.indexOf('文件上传题');
    if (fileStart >= 0) {
      fileCount = findAll(/初次提交时间/g, text.substring(fileStart)).length;
    }
    return choiceCount + fillCount + programmingCount + fileCount;
  }

  private static detectProblemStatus(text: string): JudgeStatus | null {
    const normalized = cleanText(text);
    const unsubmitted: string[] = ['还未提交代码', '未提交文件', '未提交答案', '未作答', '未提交'];
    for (let i = 0; i < unsubmitted.length; i++) {
      if (normalized.indexOf(unsubmitted[i]) >= 0) {
        return JudgeStatus.UNSUBMITTED;
      }
    }
    const submitted: string[] = [
      '初次提交时间', '首次提交时间', '最近一次提交时间', '最后一次提交时间',
      '最后一次修改时间', '已提交', '得分', 'Accepted', 'Accept'
    ];
    const lower = normalized.toLowerCase();
    for (let i = 0; i < submitted.length; i++) {
      if (lower.indexOf(submitted[i].toLowerCase()) >= 0) {
        return JudgeStatus.SUBMITTED;
      }
    }
    return null;
  }

  private static resolveStatus(totalProblems: number, submittedCount: number): JudgeStatus {
    if (totalProblems <= 0) {
      return JudgeStatus.UNKNOWN;
    }
    if (submittedCount <= 0) {
      return JudgeStatus.UNSUBMITTED;
    }
    if (submittedCount < totalProblems) {
      return JudgeStatus.PARTIAL;
    }
    return JudgeStatus.SUBMITTED;
  }

  private static submissionText(
    status: JudgeStatus,
    submittedCount: number,
    totalProblems: number,
    myScore: string | undefined,
    maxScore: string | undefined
  ): string {
    if (status === JudgeStatus.SUBMITTED) {
      if (myScore !== undefined && myScore.length > 0 &&
        maxScore !== undefined && maxScore.length > 0) {
        return '已完成 ' + myScore + '/' + maxScore;
      }
      return '已完成';
    }
    if (status === JudgeStatus.PARTIAL) {
      return '进行中(' + submittedCount + '/' + totalProblems + ')';
    }
    if (status === JudgeStatus.UNSUBMITTED) {
      return '未提交';
    }
    return '未知状态';
  }

  private static problemText(status: JudgeStatus): string {
    if (status === JudgeStatus.SUBMITTED) {
      return '已提交';
    }
    if (status === JudgeStatus.UNSUBMITTED) {
      return '未提交';
    }
    if (status === JudgeStatus.PARTIAL) {
      return '部分提交';
    }
    return '未知状态';
  }

  private static htmlToText(html: string): string {
    return cleanText(stripTags(html
      .replace(/<script\b[\s\S]*?<\/script>/gi, ' ')
      .replace(/<style\b[\s\S]*?<\/style>/gi, ' ')));
  }

  /* ---------------------------- 其他 ---------------------------- */

  private static toSummary(detail: JudgeAssignmentDetail): JudgeAssignmentSummary {
    return {
      courseId: detail.courseId,
      courseName: detail.courseName,
      assignmentId: detail.assignmentId,
      title: detail.title,
      startTime: detail.startTime,
      dueTime: detail.dueTime,
      maxScore: detail.maxScore,
      myScore: detail.myScore,
      totalProblems: detail.totalProblems,
      submittedCount: detail.submittedCount,
      submissionStatus: detail.submissionStatus,
      submissionStatusText: detail.submissionStatusText
    };
  }

  /** 作业开始时间是否早于「六个月前」。 */
  private static startedBeforeCutoff(startTime: string | undefined): boolean {
    if (startTime === undefined || startTime.length === 0) {
      return false;
    }
    const started = new Date(startTime.replace(' ', 'T'));
    if (isNaN(started.getTime())) {
      return false;
    }
    const cutoff = new Date();
    cutoff.setMonth(cutoff.getMonth() - 6);
    return started.getTime() < cutoff.getTime();
  }

  /** 希冀自己的登录页（HTTP 200，不是 401，必须按 DOM 特征识别）。 */
  private static isNativeLoginPage(html: string): boolean {
    return /<(?:a|button)\b[^>]*\bid\s*=\s*["']cgstuloginbtn["']/i.test(html);
  }

  private static sessionExpired(response: UpstreamResponse): boolean {
    if (response.status === 401) {
      return true;
    }
    if (response.url.indexOf('sso.buaa.edu.cn') >= 0) {
      return true;
    }
    if (LocalJudgeService.isNativeLoginPage(response.body)) {
      return true;
    }
    const body = response.body;
    const trimmed = body.trimStart();
    if (trimmed.startsWith('<!DOCTYPE html') || trimmed.startsWith('<html')) {
      return body.indexOf('name="execution"') >= 0 || body.indexOf('统一身份认证') >= 0;
    }
    return false;
  }
}
