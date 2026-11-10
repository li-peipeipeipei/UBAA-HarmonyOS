import { AppConfig } from '../common/AppConfig';
import { DateUtil } from '../common/DateUtil';
import { Logger } from '../common/Logger';
import { ApiError } from './ApiError';
import { LocalWebVpn } from './LocalWebVpn';
import { TokenStore } from './TokenStore';
import { UpstreamClient, UpstreamResponse } from './UpstreamClient';
import {
  ClassroomQueryResponse,
  CourseClass,
  Exam,
  ExamArrangementData,
  Grade,
  GradeData,
  SectionTime,
  Term,
  TodayClass,
  Week,
  WeeklySchedule
} from '../model/ApiTypes';

/**
 * 本地模式下的教务 / 成绩 / 教室取数（客户端直接对接校内上游）。
 *
 * ## 为什么要有这个文件
 *
 * 原生 UBAA 的业务数据是「服务端代抓 + 转 JSON」：客户端只认 `/api/v1/*`，
 * 由 Ktor 服务端去爬教务系统再回吐。SERVER_RELAY 服务端停用后，`/api/v1/*`
 * 变成 nginx 的 502，主页和课表全部加载不出来。
 *
 * 这里把这层代理搬到客户端 —— 接口地址、请求头、响应契约全部照抄原服务端
 * 各 `*Service.kt`（本文件每个方法的注释都标注了出处），因此返回给 UI 的对象
 * 与原来完全同构，页面代码不需要改。
 *
 * ## 会话是怎么来的（最容易踩的坑）
 *
 * CAS 的 SSO 会话 ≠ 子系统的会话。登录只解决了 `sso` 与 `uc` 两个域；教务
 * （byxt）、成绩/教室（app.buaa.edu.cn）各自需要「带着 service 参数访问一次」，
 * 由 SSO 下发 ticket 再换成本域的 Cookie。这一步不必显式构造 service 参数：
 * 直接打子系统的接口，CAS 过滤器会 302 到 SSO，SSO 拿着 TGT 换 ticket 再 302
 * 回来 —— 只要逐跳跟随并逐跳带 Cookie，会话就自动建好了（见 `UpstreamClient.follow`）。
 *
 * 换取结果按「本进程内」缓存（`byxtReady` 等），进程重启后重置，代价仅一次探测。
 */

/* ============================== 上游地址 ============================== */

/** 教务系统（byxt）—— 课表 / 考试。 */
const BYXT_BASE: string = 'https://' + AppConfig.UPSTREAM_BYXT_HOST;
/** 学籍门户会话探测（原 `ByxtService.probeUndergradPortal`）。 */
const BYXT_CURRENT_USER_URL: string = BYXT_BASE + '/jwapp/sys/homeapp/api/home/currentUser.do';
/** 学期列表（原 `ScheduleService.getTerms`）。 */
const BYXT_TERMS_URL: string =
  BYXT_BASE + '/jwapp/sys/homeapp/api/home/student/schoolCalendars.do';
/** 周次划分（原 `ScheduleService.getWeeks`）。 */
const BYXT_WEEKS_URL: string = BYXT_BASE + '/jwapp/sys/homeapp/api/home/getTermWeeks.do';
/** 周课表（原 `ScheduleService.getWeeklySchedule`）。 */
const BYXT_WEEK_SCHEDULE_URL: string =
  BYXT_BASE + '/jwapp/sys/homeapp/api/home/student/getMyScheduleDetail.do';
/** 今日课程（原 `ScheduleService.getTodaySchedule`）。 */
const BYXT_TODAY_URL: string =
  BYXT_BASE + '/jwapp/sys/homeapp/api/home/teachingSchedule/detail.do';
/** 考试安排（原 `ExamService.getExams`）。 */
const BYXT_EXAMS_URL: string = BYXT_BASE + '/jwapp/sys/homeapp/api/home/student/exams.do';

/** 统一身份认证入口（用于显式换取子系统会话）。 */
const CAS_LOGIN_URL: string = 'https://' + AppConfig.UPSTREAM_SSO_HOST + '/login';

/** 移动端应用门户（成绩 / 空闲教室）。 */
const APP_BASE: string = 'https://app.buaa.edu.cn';
/** 成绩页（原 `GradeService.BUAA_SCORE_URL`）。 */
const APP_SCORE_URL: string = APP_BASE + '/buaascore/wap/default/index';
/** 空闲教室查询页（Referer 用）。 */
const APP_CLASSROOM_ENTRY: string = APP_BASE + '/site/classRoomQuery/index';
/** 空闲教室查询接口（原 `ClassroomClient.queryUrl`）。 */
const APP_CLASSROOM_URL: string = APP_BASE + '/buaafreeclass/wap/default/search1';
/** 空闲教室的 SSO 换取入口（原 `ClassroomClient.loginUrl`，整串照抄）。 */
const APP_CLASSROOM_SSO_URL: string =
  'https://sso.buaa.edu.cn/login?service=https%3A%2F%2Fapp.buaa.edu.cn%2Fa_buaa%2Fapi%2Fcas' +
  '%2Findex%3Fredirect%3Dhttps%253A%252F%252Fapp.buaa.edu.cn%252Fsite%252FclassRoomQuery' +
  '%252Findex%26from%3Dwap%26login_from%3D&noAutoRedirect=1';

/**
 * 空闲教室要求的移动端 UA（含企业微信标识）。
 *
 * 教务侧的接口不吃这个，只有 app.buaa.edu.cn 的 wap 页会对桌面端 UA 返回不同页面，
 * 所以照抄原实现，仅用于这一个接口。
 */
const MOBILE_UA: string =
  'Mozilla/5.0 (Linux; Android 16; 24031PN0DC Build/BP2A.250605.031.A3; wv) ' +
  'AppleWebKit/537.36 (KHTML, like Gecko) Version/4.0 Chrome/138.0.7204.180 ' +
  'Mobile Safari/537.36 XWEB/1380275 MMWEBSDK/20230806 MMWEBID/4102 wxworklocal/3.2.200 ' +
  'wwlocal/3.2.200 wxwork/4.0.0 appname/wxworklocal-customized ' +
  'wxworklocal-device-code/195ef5586d7d3c2808fcbea32d77c0d4 MicroMessenger/7.0.1 ' +
  'appScheme/wxworklocalcustomized Language/zh_CN ColorScheme/Light ' +
  'WXWorklocalClientType/Android Brand/xiaomi';

/* ============================ 响应信封 ============================ */

/** byxt 的通用信封：{ code, msg, datas }，成功时 code === '0'。 */
interface ByxtEnvelope<T> {
  code?: string;
  msg?: string;
  datas?: T;
}

/** app.buaa.edu.cn 的通用信封：{ e, m, d }，成功时 e === 0。 */
interface AppScoreEnvelope {
  e?: number;
  m?: string;
  d?: Record<string, BuaaScoreCourse>;
}

/** 北航成绩应用里的单门课程（字段名极短，是上游定义的）。 */
interface BuaaScoreCourse {
  kcmc?: string;
  kch?: string;
  xf?: number | string;
  kccj?: number | string;
  fslx?: string;
  kclx?: string;
}

/* ============================== 工具 ============================== */

function enc(value: string): string {
  return encodeURIComponent(value);
}

/** 把可能是字符串也可能是数字的上游字段统一成去空白的字符串。 */
function textOf(value: number | string | undefined): string {
  if (value === undefined || value === null) {
    return '';
  }
  if (typeof value === 'number') {
    return value.toString();
  }
  return (value as string).trim();
}

function numberOf(value: number | string | undefined): number | undefined {
  if (value === undefined || value === null) {
    return undefined;
  }
  if (typeof value === 'number') {
    return value;
  }
  const parsed = parseFloat((value as string).trim());
  return isNaN(parsed) ? undefined : parsed;
}

/** Map 取值并把 undefined 折成空串（ArkTS 里 `undefined` 不能直接赋给 string）。 */
function mapGet(map: Map<number, string>, key: number): string {
  const value = map.get(key);
  return value === undefined ? '' : value;
}

/**
 * 归一化字符串数组：非数组折成空数组，元素统一成去空白字符串并丢掉空项。
 *
 * 上游的 `titleDetail` 是可选的，缺省时不能把 `undefined` 透给 UI（同 sectionTimes 的教训）。
 */
function stringArrayOf(value: string[] | undefined): string[] {
  const out: string[] = [];
  if (value === undefined || value === null || !Array.isArray(value)) {
    return out;
  }
  for (let i = 0; i < value.length; i++) {
    const text = textOf(value[i]);
    if (text.length > 0) {
      out.push(text);
    }
  }
  return out;
}

/* ============================== 服务 ============================== */

export class LocalAcademicService {
  /** 本进程内是否已确认对应子系统会话就绪。 */
  private static byxtReady: boolean = false;
  private static appReady: boolean = false;
  private static classroomReady: boolean = false;

  /* ------------------------------ 课表 ------------------------------ */

  /** 可选学期列表。 */
  static async fetchTerms(): Promise<Term[]> {
    await LocalAcademicService.ensureByxt();
    const response = await LocalAcademicService.byxtCall(
      'GET', BYXT_TERMS_URL, await LocalAcademicService.byxtReferer(BYXT_BASE +
        '/jwapp/sys/homeapp/index.html'), '');
    const envelope = LocalAcademicService.parseByxt<Term[]>(response, '获取学期列表失败');
    return LocalAcademicService.normalizeTerms(envelope.datas);
  }

  /** 指定学期的周次划分。 */
  static async fetchWeeks(termCode: string): Promise<Week[]> {
    await LocalAcademicService.ensureByxt();
    const url = BYXT_WEEKS_URL + '?termCode=' + enc(termCode);
    const response = await LocalAcademicService.byxtCall(
      'GET', url, await LocalAcademicService.byxtReferer(BYXT_BASE +
        '/jwapp/sys/homeapp/index.html'), '');
    const envelope = LocalAcademicService.parseByxt<Week[]>(response, '获取周次失败');
    return LocalAcademicService.normalizeWeeks(envelope.datas);
  }

  /** 指定学期某周的课表。上游要求 POST 表单（原 `getWeeklySchedule` 同样是 POST）。 */
  static async fetchWeeklySchedule(termCode: string, week: number): Promise<WeeklySchedule> {
    await LocalAcademicService.ensureByxt();
    const body = 'termCode=' + enc(termCode) + '&type=week&week=' + week.toString();
    const response = await LocalAcademicService.byxtCall(
      'POST', BYXT_WEEK_SCHEDULE_URL, await LocalAcademicService.byxtReferer(BYXT_BASE +
        '/jwapp/sys/homeapp/index.html'), body);
    const envelope = LocalAcademicService.parseByxt<WeeklySchedule>(response, '获取课表失败');
    const schedule = LocalAcademicService.normalizeSchedule(envelope.datas);
    Logger.info('周课表 ' + termCode + ' 第 ' + week + ' 周：' + schedule.arrangedList.length +
      ' 门课 / ' + schedule.sectionTimes.length + ' 节');
    return schedule;
  }

  /** 今日课程摘要。 */
  static async fetchTodayClasses(): Promise<TodayClass[]> {
    await LocalAcademicService.ensureByxt();
    const url = BYXT_TODAY_URL + '?rq=' + DateUtil.today() + '&lxdm=student';
    const response = await LocalAcademicService.byxtCall(
      'GET', url, await LocalAcademicService.byxtReferer(BYXT_BASE +
        '/jwapp/sys/homeapp/index.html'), '');
    const envelope = LocalAcademicService.parseByxt<TodayClass[]>(response, '获取今日课程失败');
    const classes = LocalAcademicService.normalizeTodayClasses(envelope.datas);
    Logger.info('今日课程（' + DateUtil.today() + '）：' + classes.length + ' 条');
    return classes;
  }

  /* ------------------------------ 考试 ------------------------------ */

  /** 指定学期的考试安排。上游的「未安排」列表没有对应接口，按原服务端一样留空。 */
  static async fetchExams(termCode: string): Promise<ExamArrangementData> {
    await LocalAcademicService.ensureByxt();
    const url = BYXT_EXAMS_URL + '?termCode=' + enc(termCode);
    const response = await LocalAcademicService.byxtCall(
      'GET', url, await LocalAcademicService.byxtReferer(BYXT_BASE +
        '/jwapp/sys/homeapp/home/index.html'), '');
    const envelope = LocalAcademicService.parseByxt<Exam[]>(response, '获取考试安排失败');
    return { arranged: LocalAcademicService.normalizeExams(envelope.datas), notArranged: [] };
  }

  /* ------------------------------ 成绩 ------------------------------ */

  /**
   * 指定学期的成绩。
   *
   * 学期编码形如 `2024-2025-1`，上游要拆成 `year=2024-2025` 与 `xq=1` 两个表单字段
   * （原 `parseBuaaScoreTermCode`）。
   */
  static async fetchGrades(termCode: string): Promise<GradeData> {
    const parsed = LocalAcademicService.parseTermCode(termCode);
    await LocalAcademicService.ensureApp();

    const body = 'xq=' + parsed.semester + '&year=' + enc(parsed.year);
    const headers: Record<string, string> = {};
    headers['accept'] = 'application/json, text/javascript, */*; q=0.01';
    headers['x-requested-with'] = 'XMLHttpRequest';
    headers['referer'] = await LocalAcademicService.rewrite(APP_SCORE_URL);

    const response = await UpstreamClient.postForm(APP_SCORE_URL, body, false, headers);
    if (LocalAcademicService.looksLoggedOut(response)) {
      Logger.warn('成绩系统会话已失效，重新换取后重试');
      LocalAcademicService.appReady = false;
      await LocalAcademicService.ensureApp();
      const retry = await UpstreamClient.postForm(APP_SCORE_URL, body, false, headers);
      return LocalAcademicService.decodeGrades(retry, termCode);
    }
    return LocalAcademicService.decodeGrades(response, termCode);
  }

  /* ---------------------------- 空闲教室 ---------------------------- */

  /** 查询某校区某天的空闲教室。 */
  static async queryClassroom(xqid: number, date: string): Promise<ClassroomQueryResponse> {
    await LocalAcademicService.ensureClassroom();

    const url = APP_CLASSROOM_URL + '?xqid=' + xqid.toString() + '&floorid=&date=' + enc(date);
    const headers = await LocalAcademicService.classroomHeaders();
    const response = await UpstreamClient.get(url, false, headers);

    if (LocalAcademicService.looksLoggedOut(response)) {
      Logger.warn('空闲教室会话已失效，重新换取后重试');
      LocalAcademicService.classroomReady = false;
      await LocalAcademicService.ensureClassroom();
      const retry = await UpstreamClient.get(url, false, headers);
      return LocalAcademicService.decodeClassroom(retry);
    }
    return LocalAcademicService.decodeClassroom(response);
  }

  /* ---------------------------- 上游数据归一化 ---------------------------- */

  /*
   * 为什么要专门做一层归一化
   *
   * 原服务端是 kotlinx.serialization：DTO 里 `List<T>` 字段缺了会抛异常、可空字段缺了
   * 会得到 null，`WeeklySchedule.sectionTimes` 还带一个 `= emptyList()` 的默认值。
   * 客户端换成 `JSON.parse` 之后这些保护全没了 —— 上游少给一个键，页面拿到的就是
   * `undefined`，紧接着一句 `data.sectionTimes.length` 直接把整页打成「加载失败」
   * （真机日志：`周课表加载失败：Cannot read property length of undefined`）。
   *
   * 所以每个上游数组都在这里过一遍：该是数组的保证是数组，该是字符串的折成空串，
   * 真正决定版面的字段（节次数）自己推导，不指望上游给。
   */

  /**
   * 归一化周课表。
   *
   * `sectionTimes` 上游并不保证返回（原服务端 DTO 里它是默认空列表），
   * 缺省时按课程自身的起止节次推导。
   */
  private static normalizeSchedule(raw: WeeklySchedule | undefined): WeeklySchedule {
    const courses = LocalAcademicService.normalizeCourses(
      raw === undefined || raw === null ? undefined : raw.arrangedList);
    const explicit = LocalAcademicService.normalizeSectionTimes(
      raw === undefined || raw === null ? undefined : raw.sectionTimes);
    const code = raw === undefined || raw === null ? '' : textOf(raw.code);
    const name = raw === undefined || raw === null ? '' : textOf(raw.name);
    return {
      arrangedList: courses,
      code: code,
      name: name,
      sectionTimes: explicit.length > 0 ? explicit : LocalAcademicService.deriveSectionTimes(courses)
    };
  }

  private static normalizeCourses(list: CourseClass[] | undefined): CourseClass[] {
    const out: CourseClass[] = [];
    if (list === undefined || list === null) {
      return out;
    }
    for (let i = 0; i < list.length; i++) {
      const item = list[i];
      if (item === undefined || item === null) {
        continue;
      }
      const courseCode = textOf(item.courseCode);
      const courseName = textOf(item.courseName);
      // 课程名是课程块的唯一展示内容，缺了就没有渲染意义
      if (courseName.length === 0 && courseCode.length === 0) {
        continue;
      }
      out.push({
        courseCode: courseCode,
        courseName: courseName,
        courseSerialNo: textOf(item.courseSerialNo),
        credit: textOf(item.credit),
        beginTime: textOf(item.beginTime),
        endTime: textOf(item.endTime),
        beginSection: numberOf(item.beginSection),
        endSection: numberOf(item.endSection),
        placeName: textOf(item.placeName),
        weeksAndTeachers: textOf(item.weeksAndTeachers),
        teachingTarget: textOf(item.teachingTarget),
        color: textOf(item.color),
        dayOfWeek: numberOf(item.dayOfWeek),
        // 上游预置的详情行（`本研标识：本` 这种），点击课程块时附在详情末尾
        titleDetail: stringArrayOf(item.titleDetail)
      });
    }
    return out;
  }

  private static normalizeSectionTimes(list: SectionTime[] | undefined): SectionTime[] {
    const out: SectionTime[] = [];
    if (list === undefined || list === null) {
      return out;
    }
    for (let i = 0; i < list.length; i++) {
      const item = list[i];
      if (item === undefined || item === null) {
        continue;
      }
      const section = numberOf(item.section);
      if (section === undefined || section <= 0) {
        continue;
      }
      out.push({
        section: section,
        start: textOf(item.start),
        end: textOf(item.end)
      });
    }
    return out;
  }

  /**
   * 由课程起止节次推导作息表。
   *
   * 课表网格只靠它拿到「这一周一共排到第几节」（`sectionTimes.length` 与最大
   * `section`），时间点仅在个别节次有课的时候才知道 —— 不知道的节次留空，
   * 页面本来也不展示单节时间。下限取 12 节，与原服务端 `scheduleSectionTimes`
   * 的 `maxOf(12, ...)` 一致，避免课少的周网格缩水。
   */
  private static deriveSectionTimes(courses: CourseClass[]): SectionTime[] {
    const starts = new Map<number, string>();
    const ends = new Map<number, string>();
    let maxSection = 12;

    for (let i = 0; i < courses.length; i++) {
      const course = courses[i];
      const begin = course.beginSection;
      if (begin !== undefined && begin > 0) {
        if (begin > maxSection) {
          maxSection = begin;
        }
        const startTime = course.beginTime;
        if (startTime !== undefined && startTime.length > 0 && !starts.has(begin)) {
          starts.set(begin, startTime);
        }
      }
      const end = course.endSection;
      if (end !== undefined && end > 0) {
        if (end > maxSection) {
          maxSection = end;
        }
        const endTime = course.endTime;
        if (endTime !== undefined && endTime.length > 0 && !ends.has(end)) {
          ends.set(end, endTime);
        }
      }
    }

    const times: SectionTime[] = [];
    for (let section = 1; section <= maxSection; section++) {
      times.push({
        section: section,
        start: mapGet(starts, section),
        end: mapGet(ends, section)
      });
    }
    return times;
  }

  private static normalizeTerms(list: Term[] | undefined): Term[] {
    const out: Term[] = [];
    if (list === undefined || list === null) {
      return out;
    }
    for (let i = 0; i < list.length; i++) {
      const item = list[i];
      if (item === undefined || item === null) {
        continue;
      }
      const code = textOf(item.itemCode);
      if (code.length === 0) {
        continue;
      }
      const index = numberOf(item.itemIndex);
      out.push({
        itemCode: code,
        itemName: textOf(item.itemName),
        selected: item.selected === true,
        itemIndex: index === undefined ? i : index
      });
    }
    return out;
  }

  private static normalizeWeeks(list: Week[] | undefined): Week[] {
    const out: Week[] = [];
    if (list === undefined || list === null) {
      return out;
    }
    for (let i = 0; i < list.length; i++) {
      const item = list[i];
      if (item === undefined || item === null) {
        continue;
      }
      const serial = numberOf(item.serialNumber);
      out.push({
        startDate: textOf(item.startDate),
        endDate: textOf(item.endDate),
        term: textOf(item.term),
        curWeek: item.curWeek === true,
        serialNumber: serial === undefined ? i + 1 : serial,
        name: textOf(item.name)
      });
    }
    return out;
  }

  private static normalizeTodayClasses(list: TodayClass[] | undefined): TodayClass[] {
    const out: TodayClass[] = [];
    if (list === undefined || list === null) {
      return out;
    }
    for (let i = 0; i < list.length; i++) {
      const item = list[i];
      if (item === undefined || item === null) {
        continue;
      }
      const bizName = textOf(item.bizName);
      if (bizName.length === 0) {
        continue;
      }
      out.push({
        bizName: bizName,
        place: textOf(item.place),
        time: textOf(item.time),
        shortName: textOf(item.shortName)
      });
    }
    return out;
  }

  private static normalizeExams(list: Exam[] | undefined): Exam[] {
    const out: Exam[] = [];
    if (list === undefined || list === null) {
      return out;
    }
    for (let i = 0; i < list.length; i++) {
      const item = list[i];
      if (item === undefined || item === null) {
        continue;
      }
      const courseName = textOf(item.courseName);
      if (courseName.length === 0) {
        continue;
      }
      out.push({
        courseName: courseName,
        courseNo: textOf(item.courseNo),
        examTimeDescription: textOf(item.examTimeDescription),
        examDate: textOf(item.examDate),
        startTime: textOf(item.startTime),
        endTime: textOf(item.endTime),
        examPlace: textOf(item.examPlace),
        examSeatNo: textOf(item.examSeatNo),
        week: numberOf(item.week),
        examStatus: numberOf(item.examStatus),
        examType: textOf(item.examType),
        taskId: textOf(item.taskId)
      });
    }
    return out;
  }

  /* ---------------------------- 会话准备 ---------------------------- */

  /**
   * 确保教务（byxt）会话可用。
   *
   * 先直接打教务接口让 CAS 自己跳；个别 CAS 过滤器不返回 302 而是直接吐登录页，
   * 这种情况再显式走一次 `sso/login?service=` 兜底。
   */
  private static async ensureByxt(): Promise<void> {
    if (LocalAcademicService.byxtReady) {
      return;
    }
    let response = await UpstreamClient.follow(BYXT_CURRENT_USER_URL);
    if (!LocalAcademicService.isJson(response)) {
      Logger.warn('教务会话未就绪，显式走一次统一认证换取');
      response = await UpstreamClient.follow(
        LocalAcademicService.casServiceUrl(BYXT_CURRENT_USER_URL));
    }
    if (!LocalAcademicService.isJson(response)) {
      throw new ApiError(401, 'upstream_session_expired',
        '教务系统会话未建立，请返回设置页重新登录后重试');
    }
    LocalAcademicService.byxtReady = true;
    Logger.info('教务系统会话就绪（' + BYXT_BASE + '）');
  }

  /** 确保移动端应用门户（成绩）会话可用。 */
  private static async ensureApp(): Promise<void> {
    if (LocalAcademicService.appReady) {
      return;
    }
    const headers: Record<string, string> = {};
    headers['accept'] = 'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8';
    let response = await UpstreamClient.follow(APP_SCORE_URL, headers);
    if (LocalAcademicService.isSsoPage(response)) {
      response = await UpstreamClient.follow(
        LocalAcademicService.casServiceUrl(APP_SCORE_URL), headers);
    }
    if (LocalAcademicService.isSsoPage(response)) {
      throw new ApiError(401, 'upstream_session_expired',
        '成绩系统会话未建立，请返回设置页重新登录后重试');
    }
    LocalAcademicService.appReady = true;
    Logger.info('成绩系统会话就绪（' + APP_BASE + '）');
  }

  /**
   * 确保空闲教室会话可用。
   *
   * 教室查询走的是 app.buaa.edu.cn 的另一条 CAS 入口（`/a_buaa/api/cas/index`），
   * 与成绩页不是同一个 service，必须单独换取一次。
   */
  private static async ensureClassroom(): Promise<void> {
    if (LocalAcademicService.classroomReady) {
      return;
    }
    const response = await UpstreamClient.follow(APP_CLASSROOM_SSO_URL, {});
    if (LocalAcademicService.isSsoPage(response)) {
      throw new ApiError(401, 'upstream_session_expired',
        '空闲教室会话未建立，请返回设置页重新登录后重试');
    }
    LocalAcademicService.classroomReady = true;
    Logger.info('空闲教室会话就绪（' + APP_BASE + '）');
  }

  /* ------------------------------ 内部 ------------------------------ */

  /**
   * 发起一次 byxt 数据请求；若中途会话过期则重新换取一次再试。
   *
   * 头一次拿不到数据基本只有一个原因：会话在两次调用之间被服务端回收了。
   * 直接报错会把「重新登录一次就好」的小问题放大成功能不可用，所以自动补一次。
   */
  private static async byxtCall(
    method: string,
    url: string,
    headers: Record<string, string>,
    body: string
  ): Promise<UpstreamResponse> {
    let response = await LocalAcademicService.sendByxt(method, url, headers, body);
    if (LocalAcademicService.looksLoggedOut(response)) {
      Logger.warn('byxt 会话已失效，重新换取后重试：' + url);
      LocalAcademicService.byxtReady = false;
      await LocalAcademicService.ensureByxt();
      response = await LocalAcademicService.sendByxt(method, url, headers, body);
    }
    return response;
  }

  /**
   * 响应是否意味着「本域会话没了」。
   *
   * 不能只看 3xx。实测 byxt 对已失效的会话会直接回 **401 + 登录页 HTML**（不跳转），
   * 一旦只判 `isRedirect()`，重试逻辑就空转，401 被原样抛到页面 —— 页面再据此清掉
   * 整个本地登录态，用户毫无征兆地被踢回登录页（真机日志：
   * `teachingSchedule/detail.do -> 401` → `主页数据加载失败` → 转 `/api/v1/*` → 502）。
   *
   * 换个判据：**只要拿到的不是 JSON 就当作会话失效**，重换一次即可自愈。
   * 真遇到上游故障也只是多一次往返，代价可接受。
   */
  private static looksLoggedOut(response: UpstreamResponse): boolean {
    return response.isRedirect() || !LocalAcademicService.isJson(response);
  }

  private static async sendByxt(
    method: string,
    url: string,
    headers: Record<string, string>,
    body: string
  ): Promise<UpstreamResponse> {
    if (method === 'POST') {
      return await UpstreamClient.postForm(url, body, false, headers);
    }
    return await UpstreamClient.get(url, false, headers);
  }

  /**
   * 教务接口要求的请求头（原 `ScheduleService.applyScheduleHeaders` /
   * `ExamService.applyExamHeaders`）。
   *
   * Referer 必须是**当前模式下的实际地址**：WebVPN 模式下校方网关会校验来源，
   * 送出未经改写的校内地址会被判成跨站。
   */
  private static async byxtReferer(referer: string): Promise<Record<string, string>> {
    const headers: Record<string, string> = {};
    headers['x-requested-with'] = 'XMLHttpRequest';
    headers['referer'] = await LocalAcademicService.rewrite(referer);
    return headers;
  }

  private static async classroomHeaders(): Promise<Record<string, string>> {
    const headers: Record<string, string> = {};
    headers['user-agent'] = MOBILE_UA;
    headers['accept'] = 'application/json, text/javascript, */*; q=0.01';
    headers['x-requested-with'] = 'XMLHttpRequest';
    headers['referer'] = await LocalAcademicService.rewrite(APP_CLASSROOM_ENTRY);
    return headers;
  }

  private static async rewrite(raw: string): Promise<string> {
    return await LocalWebVpn.rewrite(raw, TokenStore.getConnectionMode());
  }

  private static casServiceUrl(target: string): string {
    return CAS_LOGIN_URL + '?service=' + enc(target);
  }

  /** 拆解学期编码 `2024-2025-1`（原 `parseBuaaScoreTermCode`）。 */
  private static parseTermCode(termCode: string): BuaaScoreTerm {
    const parts = termCode.trim().split('-');
    if (parts.length !== 3 || parts[0].length !== 4 || parts[1].length !== 4) {
      throw new ApiError(500, 'grade_error',
        '学期编码格式不支持：' + termCode + '（应为 2024-2025-1）');
    }
    const semester = parseInt(parts[2], 10);
    if (isNaN(semester)) {
      throw new ApiError(500, 'grade_error', '学期编码格式不支持：' + termCode);
    }
    return { year: parts[0] + '-' + parts[1], semester: semester };
  }

  /** 校验 byxt 信封并取出 datas。 */
  private static parseByxt<T>(response: UpstreamResponse, what: string): ByxtEnvelope<T> {
    const envelope = LocalAcademicService.decodeJson<ByxtEnvelope<T>>(response, what);
    const code = envelope.code === undefined ? '' : envelope.code;
    if (code !== '0') {
      const msg = envelope.msg === undefined || envelope.msg.length === 0 ? '上游返回异常' : envelope.msg;
      throw new ApiError(502, 'schedule_error', what + '：' + msg);
    }
    return envelope;
  }

  private static decodeGrades(response: UpstreamResponse, termCode: string): GradeData {
    const envelope = LocalAcademicService.decodeJson<AppScoreEnvelope>(response, '获取成绩失败');
    const code = envelope.e === undefined ? -1 : envelope.e;
    if (code !== 0) {
      const msg = envelope.m === undefined || envelope.m.length === 0 ? '上游返回异常' : envelope.m;
      throw new ApiError(502, 'grade_error', '获取成绩失败：' + msg);
    }
    const map = envelope.d;
    const grades: Grade[] = [];
    if (map !== undefined && map !== null) {
      const keys = Object.keys(map);
      for (let i = 0; i < keys.length; i++) {
        grades.push(LocalAcademicService.toGrade(map[keys[i]], termCode));
      }
    }
    return { termCode: termCode, grades: grades };
  }

  /** 把上游短字段映射成 UI 契约里的成绩字段（原 `BuaaScoreCourse.toGrade`）。 */
  private static toGrade(course: BuaaScoreCourse, termCode: string): Grade {
    return {
      XNXQDM: termCode,
      XNXQDM_DISPLAY: termCode,
      KCM: textOf(course.kcmc),
      KCH: textOf(course.kch),
      XF: numberOf(course.xf),
      XSZCJ: textOf(course.kccj),
      KCXZDM_DISPLAY: textOf(course.kclx),
      CJRDFSDM_DISPLAY: textOf(course.fslx)
    };
  }

  private static decodeClassroom(response: UpstreamResponse): ClassroomQueryResponse {
    const envelope = LocalAcademicService.decodeJson<ClassroomQueryResponse>(response, '查询空闲教室失败');
    const code = envelope.e === undefined ? -1 : envelope.e;
    if (code !== 0) {
      const msg = envelope.m === undefined || envelope.m.length === 0 ? '上游返回异常' : envelope.m;
      throw new ApiError(502, 'classroom_error', '查询空闲教室失败：' + msg);
    }
    return envelope;
  }

  /** 解析 JSON 响应；状态、内容类型不对时抛出可读错误。 */
  private static decodeJson<T>(response: UpstreamResponse, what: string): T {
    if (response.isRedirect()) {
      throw new ApiError(401, 'upstream_session_expired', what + '：上游会话已失效，请重新登录');
    }
    if (!response.isOk()) {
      if (response.body.indexOf('<html') >= 0 || response.body.indexOf('<!DOCTYPE') >= 0) {
        throw ApiError.fromHtmlResponse(response.status, response.body, AppConfig.hostOf(response.url));
      }
      throw new ApiError(response.status, 'upstream_down', what + '：上游返回 HTTP ' + response.status);
    }
    if (!LocalAcademicService.isJson(response)) {
      if (LocalAcademicService.isSsoPage(response)) {
        throw new ApiError(401, 'upstream_session_expired', what + '：上游会话已失效，请重新登录');
      }
      throw new ApiError(502, 'upstream_down',
        what + '：上游返回的是网页而不是数据，校方系统可能正在维护');
    }
    try {
      return JSON.parse(response.body) as T;
    } catch (error) {
      throw new ApiError(502, 'upstream_down', what + '：上游返回的数据无法解析');
    }
  }

  private static isJson(response: UpstreamResponse): boolean {
    if (!response.isOk()) {
      return false;
    }
    const trimmed = response.body.trimStart();
    return trimmed.startsWith('{') || trimmed.startsWith('[');
  }

  /** 是否停在统一身份认证页（会话没换成）。 */
  private static isSsoPage(response: UpstreamResponse): boolean {
    if (response.isRedirect()) {
      return true;
    }
    if (response.url.indexOf(AppConfig.UPSTREAM_SSO_HOST) >= 0) {
      return true;
    }
    const body = response.body;
    return body.indexOf('name="execution"') >= 0 || body.indexOf('统一身份认证') >= 0;
  }
}

/** 成绩接口需要的学期拆解结果。 */
interface BuaaScoreTerm {
  year: string;
  semester: number;
}
