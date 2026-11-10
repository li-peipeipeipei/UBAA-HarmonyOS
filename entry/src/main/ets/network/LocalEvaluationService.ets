import { Logger } from '../common/Logger';
import { ApiError } from './ApiError';
import { UpstreamClient, UpstreamResponse } from './UpstreamClient';
import { TokenStore } from './TokenStore';
import {
  EvaluationCourse,
  EvaluationCoursesResponse,
  EvaluationProgress,
  EvaluationResult
} from '../model/ApiTypes';

/**
 * 本地模式下的「自动评教」（客户端直接对接 pjxt 上游）。
 *
 * ## 上游从哪来
 *
 * 全部照抄原 UBAA 的 `shared/.../local/LocalEvaluationService.kt`（接口路径、参数、
 * 表单结构逐字段一致），因此返回给 UI 的对象与原生版完全同构。
 *
 * 流程四步，缺一不可：
 *
 * 1. 打开 `/pjxt/cas` 让 SPOC 的评教子系统认下 CAS 会话（只是握手，不取数据）；
 * 2. 拉「评教任务」→ 每个任务下的「问卷」→ 每份问卷下的「应评课程」；
 * 3. 提交前先 `reviseQuestionnairePattern` 切到该问卷对应的模式（`msid`），
 *    否则 `getQuestionnaireTopic` 取到的题目结构对不上；
 * 4. 取题目 → 组装 `pjjglist`（每题默认第一个选项，随机一题选第二个，避免整卷
 *    答案完全一致）→ `submitSaveEvaluation`。
 *
 * ## 为什么有「已评教」还要列出来
 *
 * 上游同一门课可能既在待评列表、又在已评列表（`ypjcs > 0`）。原版把两者合并、
 * 未评教的排在前面，并允许查看进度；这里保持一致。
 */
const PJXT_BASE: string = 'https://spoc.buaa.edu.cn/pjxt';

/** 评教任务的默认分页大小（原版写死 10）。 */
const TASK_PAGE_SIZE: number = 10;

/** 上游通用信封：`code` 为 200 / 0 / "success" 时表示成功。 */
interface EvalEnvelope<T> {
  code?: string | number | null;
  result?: T | null;
  content?: T | null;
  message?: string | null;
  msg?: string | null;
}

interface EvalPage<T> {
  list?: T[] | null;
  total?: number | null;
}

interface EvalTask {
  rwid?: string;
  rwmc?: string;
}

interface EvalQuestionnaire {
  wjid?: string;
  wjmc?: string;
  rwmc?: string;
  msid?: string | number | null;
}

/** `getRequiredReviewsData` 的一条（字段可能缺省，按需回退）。 */
interface EvalRawCourse {
  kcdm?: string;
  kcmc?: string;
  bpdm?: string;
  bpmc?: string;
  pjrdm?: string;
  pjrmc?: string;
  xnxq?: string;
  zdmc?: string;
  ypjcs?: number | string;
  xypjcs?: number | string;
  sxz?: string;
  rwh?: string;
  xn?: string;
  xq?: string;
  pjlxid?: string;
  sfksqbpj?: string;
  yxsfktjst?: string;
}

/** `getQuestionnaireTopic` 的返回体（只声明用到的部分，其余原样透传）。 */
interface EvalTopic {
  pjxtWjWjbReturnEntity?: EvalPaperEntity;
  pjxtPjjgPjjgckb?: EvalPjjgItem[];
  pjmap?: object;
}

interface EvalPaperEntity {
  wjzblist?: EvalSection[];
}

interface EvalSection {
  tklist?: EvalQuestion[];
}

interface EvalQuestion {
  tmid?: string;
  tmlx?: string;
  tmxxlist?: EvalOption[];
}

interface EvalOption {
  tmxxid?: string;
}

/** `pjjgckb` 的一条：评教对象（课程 / 教师）与若干原样回传字段。 */
interface EvalPjjgItem {
  bprdm?: string | number | null;
  bprmc?: string | number | null;
  kcdm?: string | number | null;
  kcmc?: string | number | null;
  pjfs?: string | number | null;
  pjid?: string | number | null;
  pjlx?: string | number | null;
  pjrdm?: string | number | null;
  pjrjsdm?: string | number | null;
  pjrxm?: string | number | null;
  rwh?: string | number | null;
  wjssrwid?: string | number | null;
  xnxq?: string | number | null;
  sfxxpj?: string | number | null;
}

/** 单题作答（提交结构）。 */
class EvalAnswer {
  sjly: string = '1';
  stlx: string = '1';
  wjid: string = '';
  wjssrwid: string | number | null = null;
  wjstctid: string = '';
  wjstid: string | number | null = null;
  xxdalist: string[] = [];
}

/** 一条评教提交记录（提交结构）。 */
class EvalSubmitItem {
  bprdm: string | number | null = null;
  bprmc: string | number | null = null;
  kcdm: string | number | null = null;
  kcmc: string | number | null = null;
  pjdf: number = 93;
  pjfs: string | number = '1';
  pjid: string | number | null = null;
  pjlx: string | number | null = null;
  pjmap: object | null = null;
  pjrdm: string | number | null = null;
  pjrjsdm: string | number | null = null;
  pjrxm: string | number | null = null;
  pjsx: number = 1;
  pjxxlist: EvalAnswer[] = [];
  rwh: string | number | null = null;
  stzjid: string = 'xx';
  wjid: string = '';
  wjssrwid: string | number | null = null;
  wtjjy: string = '';
  xhgs: string | null = null;
  xnxq: string | number | null = null;
  sfxxpj: string | number = '1';
  sqzt: string | null = null;
  yxfz: string | null = null;
  zsxz: string | number = '';
  sfnm: string = '1';
}

/** 提交请求体。 */
class EvalSubmitBody {
  pjidlist: string[] = [];
  pjjglist: EvalSubmitItem[] = [];
  pjzt: string = '1';
}

function enc(value: string): string {
  return encodeURIComponent(value);
}

/** 上游字段可能是字符串 / 数字 / 布尔，统一成去空白的字符串。 */
function str(value: string | number | boolean | null | undefined): string {
  if (value === undefined || value === null) {
    return '';
  }
  if (typeof value === 'number') {
    return value.toString();
  }
  if (typeof value === 'boolean') {
    return value ? 'true' : 'false';
  }
  return value.trim();
}

function intOf(value: string | number | null | undefined): number {
  const parsed = parseInt(str(value), 10);
  return isNaN(parsed) ? 0 : parsed;
}

export class LocalEvaluationService {
  /** 本次进程是否已打通 /pjxt 的 CAS 会话。 */
  private static activated: boolean = false;

  /* ------------------------------ 对外 ------------------------------ */

  /**
   * 全部评教课程（含已评教），附带进度。
   *
   * @throws ApiError 会话失效 / 上游异常时抛出
   */
  static async fetchCourses(): Promise<EvaluationCoursesResponse> {
    await LocalEvaluationService.ensureActivated();

    const tasks = await LocalEvaluationService.fetchTasks();
    const map = new Map<string, EvaluationCourse>();

    for (let i = 0; i < tasks.length; i++) {
      const task = tasks[i];
      const rwid = str(task.rwid);
      if (rwid.length === 0) {
        continue;
      }
      const questionnaires = await LocalEvaluationService.fetchQuestionnaires(rwid);
      for (let j = 0; j < questionnaires.length; j++) {
        const questionnaire = questionnaires[j];
        const wjid = str(questionnaire.wjid);
        if (wjid.length === 0) {
          continue;
        }
        const msid = str(questionnaire.msid).length > 0 ? str(questionnaire.msid) : '1';
        const raw = await LocalEvaluationService.fetchRawCourses(wjid);
        LocalEvaluationService.merge(map, raw, rwid, wjid, msid);
      }
    }

    const all: EvaluationCourse[] = [];
    map.forEach((value: EvaluationCourse) => {
      all.push(value);
    });
    // 未评教的排前面（与原版 sortedBy { it.isEvaluated } 一致）
    all.sort((a: EvaluationCourse, b: EvaluationCourse): number => {
      if (a.isEvaluated === b.isEvaluated) {
        return 0;
      }
      return a.isEvaluated ? 1 : -1;
    });

    let evaluated = 0;
    for (let i = 0; i < all.length; i++) {
      if (all[i].isEvaluated) {
        evaluated++;
      }
    }
    const progress: EvaluationProgress = {
      totalCourses: all.length,
      evaluatedCourses: evaluated,
      pendingCourses: all.length - evaluated
    };
    Logger.info('评教课程：共 ' + all.length + ' 门，已完成 ' + evaluated + ' 门');
    return { courses: all, progress: progress };
  }

  /**
   * 提交单门课程的评教（**写操作**，不可撤销）。
   *
   * 逐门提交是刻意的：上游一次提交多门时，中间失败无法定位是哪一门；
   * 逐门提交还能让界面显示精确进度。
   */
  static async submitCourse(course: EvaluationCourse): Promise<EvaluationResult> {
    try {
      await LocalEvaluationService.ensureActivated();
      await LocalEvaluationService.revisePattern(course);
      const topic = await LocalEvaluationService.fetchTopic(course);
      if (topic === null) {
        return { success: false, message: '无法获取问卷题目', courseName: course.kcmc };
      }
      const payload = LocalEvaluationService.buildPayload(course, topic);
      if (payload.length === 0) {
        return { success: false, message: '问卷没有题目', courseName: course.kcmc };
      }
      const envelope = await LocalEvaluationService.submitPayload(payload);
      if (envelope !== null && LocalEvaluationService.isSuccess(envelope.code)) {
        return { success: true, message: '评教成功', courseName: course.kcmc };
      }
      const code = envelope === null ? 'no-code' : str(envelope.code);
      let message = '提交失败，可能已评教';
      if (envelope !== null && str(envelope.message).length > 0) {
        message = str(envelope.message);
      } else if (envelope !== null && str(envelope.msg).length > 0) {
        message = str(envelope.msg);
      }
      return {
        success: false,
        message: '提交失败(code=' + (code.length > 0 ? code : 'no-code') + '): ' + message,
        courseName: course.kcmc
      };
    } catch (error) {
      const message = error instanceof ApiError
        ? (error as ApiError).friendlyMessage()
        : '评教提交失败，请稍后重试';
      Logger.error('评教提交失败（' + course.kcmc + '）：' + (error as Error).message);
      return { success: false, message: message, courseName: course.kcmc };
    }
  }

  /** 批量提交（逐门串行，任何一门失败都不影响其余课程）。 */
  static async submitAll(courses: EvaluationCourse[]): Promise<EvaluationResult[]> {
    const results: EvaluationResult[] = [];
    for (let i = 0; i < courses.length; i++) {
      results.push(await LocalEvaluationService.submitCourse(courses[i]));
    }
    return results;
  }

  /* ---------------------------- 会话 ---------------------------- */

  /** 打通 /pjxt 的 CAS 会话（一次性）。 */
  private static async ensureActivated(): Promise<void> {
    if (LocalEvaluationService.activated) {
      return;
    }
    const response = await UpstreamClient.get(PJXT_BASE + '/cas', true);
    if (LocalEvaluationService.sessionExpired(response)) {
      LocalEvaluationService.activated = false;
      throw new ApiError(401, 'invalid_token', '评教服务会话未建立，请重新登录后再试');
    }
    if (!response.isOk()) {
      throw new ApiError(response.status, 'evaluation_error',
        '评教服务暂时不可用（HTTP ' + response.status + '），请稍后重试');
    }
    LocalEvaluationService.activated = true;
  }

  /* ---------------------------- 取数 ---------------------------- */

  private static async fetchTasks(): Promise<EvalTask[]> {
    const session = TokenStore.getLocalSession();
    const yhdm = session === null
      ? ''
      : (session.schoolId.length > 0 ? session.schoolId : session.username);
    const url = PJXT_BASE + '/personnelEvaluation/listObtainPersonnelEvaluationTasks' +
      '?yhdm=' + enc(yhdm) + '&pageNum=1&pageSize=' + TASK_PAGE_SIZE;
    const response = await UpstreamClient.get(url, true);
    const envelope = LocalEvaluationService.decode<EvalPage<EvalTask>>(response, '评教任务加载失败');
    const page = envelope.result;
    if (page === undefined || page === null || page.list === undefined || page.list === null) {
      return [];
    }
    return page.list;
  }

  private static async fetchQuestionnaires(rwid: string): Promise<EvalQuestionnaire[]> {
    const url = PJXT_BASE + '/evaluationMethodSix/getQuestionnaireListToTask?rwid=' + enc(rwid);
    const response = await UpstreamClient.get(url, true);
    const envelope = LocalEvaluationService.decode<EvalQuestionnaire[]>(response, '评教问卷加载失败');
    const list = envelope.result;
    return list === undefined || list === null ? [] : list;
  }

  private static async fetchRawCourses(wjid: string): Promise<EvalRawCourse[]> {
    const url = PJXT_BASE + '/evaluationMethodSix/getRequiredReviewsData?wjid=' + enc(wjid);
    const response = await UpstreamClient.get(url, true);
    const envelope = LocalEvaluationService.decode<EvalRawCourse[]>(response, '待评课程加载失败');
    const list = envelope.result;
    return list === undefined || list === null ? [] : list;
  }

  /** 切问卷模式（失败不阻断：原版同样只记日志）。 */
  private static async revisePattern(course: EvaluationCourse): Promise<void> {
    const body: string = JSON.stringify({
      rwid: course.rwid,
      wjid: course.wjid,
      msid: course.msid
    });
    try {
      await UpstreamClient.postJson(
        PJXT_BASE + '/evaluationMethodSix/reviseQuestionnairePattern', body, true);
    } catch (error) {
      Logger.warn('切换评教问卷模式失败（继续取题）：' + (error as Error).message);
    }
  }

  private static async fetchTopic(course: EvaluationCourse): Promise<EvalTopic | null> {
    const url = PJXT_BASE + '/evaluationMethodSix/getQuestionnaireTopic' +
      '?id=&rwid=' + enc(course.rwid) +
      '&wjid=' + enc(course.wjid) +
      '&zdmc=' + enc(course.zdmc === undefined ? 'STID' : course.zdmc) +
      '&ypjcs=' + (course.ypjcs === undefined ? 0 : course.ypjcs).toString() +
      '&xypjcs=' + (course.xypjcs === undefined ? 1 : course.xypjcs).toString() +
      '&sxz=' + enc(course.sxz === undefined ? '' : course.sxz) +
      '&pjrdm=' + enc(course.pjrdm === undefined ? '' : course.pjrdm) +
      '&pjrmc=' + enc(course.pjrmc === undefined ? '' : course.pjrmc) +
      '&bpdm=' + enc(course.bpdm === undefined ? '' : course.bpdm) +
      '&bpmc=' + enc(course.bpmc) +
      '&kcdm=' + enc(course.kcdm) +
      '&kcmc=' + enc(course.kcmc) +
      '&rwh=' + enc(course.rwh === undefined ? '' : course.rwh) +
      '&xn=' + enc(course.xn === undefined ? '' : course.xn) +
      '&xq=' + enc(course.xq === undefined ? '' : course.xq) +
      '&xnxq=' + enc(course.xnxq === undefined ? '' : course.xnxq) +
      '&pjlxid=' + enc(course.pjlxid === undefined ? '2' : course.pjlxid) +
      '&sfksqbpj=' + enc(course.sfksqbpj === undefined ? '1' : course.sfksqbpj) +
      '&yxsfktjst=' + enc(course.yxsfktjst === undefined ? '' : course.yxsfktjst) +
      '&yxdm=';
    const response = await UpstreamClient.get(url, true);
    const envelope = LocalEvaluationService.decode<EvalTopic[]>(response, '评教题目加载失败');
    const list = envelope.result;
    if (list === undefined || list === null || list.length === 0) {
      return null;
    }
    return list[0];
  }

  /* ---------------------------- 组包 ---------------------------- */

  private static buildPayload(course: EvaluationCourse, topic: EvalTopic): EvalSubmitItem[] {
    const entity = topic.pjxtWjWjbReturnEntity;
    const sections = entity === undefined || entity === null || entity.wjzblist === undefined ||
      entity.wjzblist === null ? [] : entity.wjzblist;
    const questions: EvalQuestion[] = [];
    for (let i = 0; i < sections.length; i++) {
      const section = sections[i];
      if (section === undefined || section === null || section.tklist === undefined ||
        section.tklist === null) {
        continue;
      }
      for (let j = 0; j < section.tklist.length; j++) {
        questions.push(section.tklist[j]);
      }
    }
    if (questions.length === 0) {
      return [];
    }

    // 整卷答案全一样会被上游判为「无效问卷」，随机挑一题选第二个选项
    const randomIndex: number = Math.floor(Math.random() * questions.length);
    const items = topic.pjxtPjjgPjjgckb;
    if (items === undefined || items === null || items.length === 0) {
      return [];
    }

    const payload: EvalSubmitItem[] = [];
    for (let i = 0; i < items.length; i++) {
      const item = items[i];
      if (item === undefined || item === null) {
        continue;
      }
      const record = new EvalSubmitItem();
      record.bprdm = LocalEvaluationService.valueOrNull(item.bprdm);
      record.bprmc = LocalEvaluationService.valueOrNull(item.bprmc);
      record.kcdm = LocalEvaluationService.valueOrNull(item.kcdm);
      record.kcmc = LocalEvaluationService.valueOrNull(item.kcmc);
      record.pjfs = item.pjfs === undefined || item.pjfs === null ? '1' : item.pjfs;
      record.pjid = LocalEvaluationService.valueOrNull(item.pjid);
      record.pjlx = LocalEvaluationService.valueOrNull(item.pjlx);
      record.pjmap = topic.pjmap === undefined ? null : topic.pjmap;
      record.pjrdm = LocalEvaluationService.valueOrNull(item.pjrdm);
      record.pjrjsdm = LocalEvaluationService.valueOrNull(item.pjrjsdm);
      record.pjrxm = LocalEvaluationService.valueOrNull(item.pjrxm);
      record.pjxxlist = LocalEvaluationService.buildAnswers(course, item, questions, randomIndex);
      record.rwh = LocalEvaluationService.valueOrNull(item.rwh);
      record.wjid = course.wjid;
      record.wjssrwid = LocalEvaluationService.valueOrNull(item.wjssrwid);
      record.xnxq = LocalEvaluationService.valueOrNull(item.xnxq);
      record.sfxxpj = item.sfxxpj === undefined || item.sfxxpj === null ? '1' : item.sfxxpj;
      record.zsxz = item.pjrjsdm === undefined || item.pjrjsdm === null ? '' : item.pjrjsdm;
      payload.push(record);
    }
    return payload;
  }

  private static buildAnswers(
    course: EvaluationCourse,
    item: EvalPjjgItem,
    questions: EvalQuestion[],
    randomIndex: number
  ): EvalAnswer[] {
    const answers: EvalAnswer[] = [];
    for (let i = 0; i < questions.length; i++) {
      const question = questions[i];
      const type = str(question.tmlx).length > 0 ? str(question.tmlx) : '1';
      const isChoice = type === '1';
      const options = question.tmxxlist === undefined || question.tmxxlist === null
        ? [] : question.tmxxlist;
      let firstId = '';
      if (options.length > 0 && options[0].tmxxid !== undefined) {
        firstId = str(options[0].tmxxid);
      }
      let selected = '';
      if (isChoice) {
        if (i === randomIndex && options.length > 1 && options[1].tmxxid !== undefined) {
          selected = str(options[1].tmxxid);
        } else {
          selected = firstId;
        }
      }

      const answer = new EvalAnswer();
      answer.stlx = isChoice ? '1' : '6';
      answer.wjid = course.wjid;
      answer.wjssrwid = LocalEvaluationService.valueOrNull(item.wjssrwid);
      answer.wjstctid = isChoice ? '' : firstId;
      answer.wjstid = question.tmid === undefined ? null : str(question.tmid);
      if (selected.length > 0) {
        answer.xxdalist.push(selected);
      }
      answers.push(answer);
    }
    return answers;
  }

  private static valueOrNull(value: string | number | null | undefined): string | number | null {
    return value === undefined ? null : value;
  }

  private static async submitPayload(
    payload: EvalSubmitItem[]
  ): Promise<EvalEnvelope<object> | null> {
    const body = new EvalSubmitBody();
    body.pjjglist = payload;
    const response = await UpstreamClient.postJson(
      PJXT_BASE + '/evaluationMethodSix/submitSaveEvaluation', JSON.stringify(body), true);
    return LocalEvaluationService.decode<EvalEnvelope<object>>(response, '评教提交失败');
  }

  /* ---------------------------- 解析 ---------------------------- */

  /** 合并一条上游课程（同一 key 以「已评教」为准，字段缺省时回退旧值）。 */
  private static merge(
    map: Map<string, EvaluationCourse>,
    courses: EvalRawCourse[],
    rwid: string,
    wjid: string,
    msid: string
  ): void {
    for (let i = 0; i < courses.length; i++) {
      const raw = courses[i];
      const kcdm = str(raw.kcdm);
      if (kcdm.length === 0) {
        continue;
      }
      const bpdm = str(raw.bpdm);
      const key = rwid + '_' + wjid + '_' + kcdm + '_' + bpdm;
      const existing = map.get(key);
      const ypjcs = intOf(raw.ypjcs);
      const evaluated = ypjcs > 0 || (existing !== undefined && existing.isEvaluated);

      const course: EvaluationCourse = {
        id: key,
        kcmc: str(raw.kcmc).length > 0 ? str(raw.kcmc)
          : (existing === undefined ? '未知课程' : existing.kcmc),
        bpmc: str(raw.bpmc).length > 0 ? str(raw.bpmc)
          : (existing === undefined ? '未知教师' : existing.bpmc),
        isEvaluated: evaluated,
        rwid: rwid,
        wjid: wjid,
        kcdm: kcdm,
        bpdm: bpdm,
        pjrdm: str(raw.pjrdm).length > 0 ? str(raw.pjrdm)
          : (existing === undefined ? undefined : existing.pjrdm),
        pjrmc: str(raw.pjrmc).length > 0 ? str(raw.pjrmc)
          : (existing === undefined ? undefined : existing.pjrmc),
        xnxq: str(raw.xnxq).length > 0 ? str(raw.xnxq)
          : (existing === undefined ? undefined : existing.xnxq),
        msid: msid,
        zdmc: str(raw.zdmc).length > 0 ? str(raw.zdmc)
          : (existing === undefined ? 'STID' : existing.zdmc),
        ypjcs: ypjcs,
        xypjcs: intOf(raw.xypjcs),
        sxz: str(raw.sxz),
        rwh: str(raw.rwh),
        xn: str(raw.xn),
        xq: str(raw.xq),
        pjlxid: str(raw.pjlxid).length > 0 ? str(raw.pjlxid) : '2',
        sfksqbpj: str(raw.sfksqbpj).length > 0 ? str(raw.sfksqbpj) : '1',
        yxsfktjst: str(raw.yxsfktjst)
      };
      map.set(key, course);
    }
  }

  /** 解析信封；会话失效 / 非 JSON / 业务失败都翻译成 ApiError。 */
  private static decode<T>(response: UpstreamResponse, what: string): EvalEnvelope<T> {
    if (LocalEvaluationService.sessionExpired(response)) {
      LocalEvaluationService.activated = false;
      throw new ApiError(401, 'invalid_token', what + '：评教会话已失效，请重新登录');
    }
    if (!response.isOk()) {
      if (response.body.indexOf('<html') >= 0 || response.body.indexOf('<!DOCTYPE') >= 0) {
        throw ApiError.fromHtmlResponse(response.status, response.body, 'spoc.buaa.edu.cn');
      }
      throw new ApiError(response.status, 'evaluation_error',
        what + '：上游返回 HTTP ' + response.status);
    }
    const trimmed = response.body.trimStart();
    if (!trimmed.startsWith('{')) {
      throw new ApiError(502, 'evaluation_error', what + '：上游返回的是网页而不是数据');
    }
    let envelope: EvalEnvelope<T>;
    try {
      envelope = JSON.parse(trimmed) as EvalEnvelope<T>;
    } catch (error) {
      throw new ApiError(502, 'evaluation_error', what + '：上游返回的数据无法解析');
    }
    if (!LocalEvaluationService.isSuccess(envelope.code)) {
      const message = str(envelope.message).length > 0 ? str(envelope.message) : str(envelope.msg);
      throw new ApiError(502, 'evaluation_error',
        what + '：' + (message.length > 0 ? message : '评教服务暂时不可用'));
    }
    return envelope;
  }

  private static isSuccess(code: string | number | null | undefined): boolean {
    const value = str(code).toLowerCase();
    return value === '200' || value === '0' || value === 'success';
  }

  /** 会话是否已经掉到统一身份认证。 */
  private static sessionExpired(response: UpstreamResponse): boolean {
    if (response.status === 401) {
      return true;
    }
    if (response.url.indexOf('sso.buaa.edu.cn') >= 0) {
      return true;
    }
    const body = response.body;
    if (body.trimStart().startsWith('<')) {
      return body.indexOf('name="execution"') >= 0 || body.indexOf('统一身份认证') >= 0;
    }
    return false;
  }
}
