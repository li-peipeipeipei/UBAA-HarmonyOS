import { http } from '@kit.NetworkKit';
import { AppConfig } from '../common/AppConfig';
import { Logger } from '../common/Logger';
import { ApiError } from './ApiError';
import { HttpEngine } from './HttpEngine';
import { LocalAcademicService } from './LocalAcademicService';
import { LocalAuthService } from './LocalAuthService';
import { LocalSigninService } from './LocalSigninService';
import { LocalSpocService } from './LocalSpocService';
import { LocalBykcService } from './LocalBykcService';
import { LocalYgdkService } from './LocalYgdkService';
import { LocalEvaluationService } from './LocalEvaluationService';
import { LocalJudgeService } from './LocalJudgeService';
import { LocalIhomeService } from './LocalIhomeService';
import { MockData } from './MockData';
import { StoredSession, TokenStore } from './TokenStore';
import {
  BykcChosenCourse,
  BykcCourseDetail,
  BykcCoursesData,
  BykcStatistics,
  ClassroomQueryResponse,
  EvaluationCourse,
  EvaluationCoursesResponse,
  EvaluationResult,
  JudgeAssignmentDetail,
  JudgeAssignmentsResponse,
  IhomeAppeal,
  IhomeConfig,
  IhomeFilter,
  IhomeNotice,
  IhomePage,
  IhomeReaction,
  IhomeReactionResult,
  IhomeScope,
  ExamArrangementData,
  GradeData,
  LoginPreloadResponse,
  LoginResponse,
  SessionStatusResponse,
  SigninActionResult,
  SigninClass,
  SpocAssignmentDetail,
  SpocAssignmentsData,
  Term,
  TodayClass,
  UserData,
  UserInfo,
  Week,
  WeeklySchedule,
  YgdkClockinInput,
  YgdkClockinResult,
  YgdkOverview,
  YgdkRecordsData
} from '../model/ApiTypes';

/**
 * 业务 API 门面。
 *
 * ## 认证（preload / login / status / logout）
 *
 * 全部走**本地模式**（`LocalAuthService`）：客户端自己完成校内统一认证，
 * 登录态是上游 Cookie。原因见 LocalAuthService 头部注释 —— 原 SERVER_RELAY
 * 的 `/api/v1/auth/*` 服务端已停止部署。
 *
 * ## 业务数据（课表 / 成绩 / 考试 …）
 *
 * 同样走**本地模式**（`LocalAcademicService`）：客户端直接对接
 * 教务系统（byxt）与移动端门户（app.buaa.edu.cn）。
 *
 * 历史遗留的 `/api/v1/*` 分支保留着（服务端万一恢复时可用），但只在没有本地
 * 登录态（即中转模式的 JWT）时才会走到 —— 服务端下线期间那条路必然 502。
 */
export class ApiService {
  private static apiPath(suffix: string): string {
    return AppConfig.API_PREFIX + suffix;
  }

  /**
   * 是否处于本地模式。
   *
   * 判据是「有没有上游 Cookie 登录态」，与连接模式（DIRECT / WEBVPN）无关 ——
   * 两种连接模式都是本地上游取数，区别只在地址是否经 WebVPN 改写。
   */
  private static localMode(): boolean {
    return TokenStore.hasLocalSession();
  }

  private static singleQuery(key: string, value: string): Map<string, string> {
    const query = new Map<string, string>();
    query.set(key, value);
    return query;
  }

  /* ========================= 认证 ========================= */

  /**
   * 登录预加载：拉取统一认证登录页，取出一次性令牌并探测是否需要验证码。
   *
   * `clientId` 是中转模式的历史参数，本地模式不需要（保留签名避免调用方改动）。
   */
  static async preload(clientId: string): Promise<LoginPreloadResponse> {
    if (TokenStore.getDemoMode()) {
      await MockData.pause();
      return MockData.preload();
    }
    Logger.info('登录预加载（本地模式），clientId=' + clientId);
    return await LocalAuthService.preload();
  }

  /**
   * 登录。
   *
   * 本地模式：客户端自己走 CAS（取登录页 → 提交凭据 → 换 UC 会话 → 校验）。
   *
   * @throws CaptchaRequiredError 需要验证码时抛出，携带图片与新的 execution
   * @throws ApiError 凭据错误 / 上游不可用 / 网络异常
   */
  static async login(
    username: string,
    password: string,
    clientId: string,
    captcha?: string,
    execution?: string
  ): Promise<LoginResponse> {
    if (TokenStore.getDemoMode()) {
      await MockData.pause();
      return MockData.login(username);
    }
    return await LocalAuthService.login(
      username,
      password,
      captcha === undefined ? '' : captcha,
      execution === undefined ? '' : execution
    );
  }

  /** 查询当前会话状态（本地模式会实时打上游校验，不只是读本地）。 */
  static async status(): Promise<SessionStatusResponse> {
    if (TokenStore.getDemoMode()) {
      await MockData.pause();
      return MockData.status(TokenStore.getSession().schoolId);
    }
    return await LocalAuthService.status();
  }

  /** 注销并清理本地会话（含上游 Cookie）。 */
  static async logout(): Promise<void> {
    if (TokenStore.getDemoMode()) {
      TokenStore.clear();
      TokenStore.clearAllLocalSessions();
      return;
    }
    await LocalAuthService.logout();
    TokenStore.clear();
  }

  /** 验证码图片地址（本地模式直接指向统一认证的验证码接口）。 */
  static captchaImageUrl(captchaId: string): string {
    return LocalAuthService.captchaUrl(captchaId);
  }

  /* ========================= 用户 ========================= */

  static async fetchUserInfo(): Promise<UserInfo> {
    if (TokenStore.getDemoMode()) {
      await MockData.pause();
      const session = TokenStore.getSession();
      return MockData.userInfo(session.schoolId, session.username);
    }
    // 本地模式下个人信息来自校内用户中心（uc.buaa.edu.cn），与登录共用同一套 Cookie
    if (TokenStore.hasLocalSession()) {
      return await LocalAuthService.fetchUserInfo();
    }
    const result = await HttpEngine.request(http.RequestMethod.GET, ApiService.apiPath('/user/info'));
    return HttpEngine.decode<UserInfo>(result.body, {});
  }

  /* ========================= 课表 ========================= */

  /** 学期列表。 */
  static async fetchTerms(): Promise<Term[]> {
    if (TokenStore.getDemoMode()) {
      await MockData.pause();
      return MockData.terms();
    }
    if (ApiService.localMode()) {
      return await LocalAcademicService.fetchTerms();
    }
    const result = await HttpEngine.request(
      http.RequestMethod.GET,
      ApiService.apiPath('/schedule/terms')
    );
    return HttpEngine.decode<Term[]>(result.body, []);
  }

  /** 指定学期的教学周列表。 */
  static async fetchWeeks(termCode: string): Promise<Week[]> {
    if (TokenStore.getDemoMode()) {
      await MockData.pause();
      return MockData.weeks();
    }
    if (ApiService.localMode()) {
      return await LocalAcademicService.fetchWeeks(termCode);
    }
    const result = await HttpEngine.request(
      http.RequestMethod.GET,
      ApiService.apiPath('/schedule/weeks'),
      undefined,
      true,
      ApiService.singleQuery('termCode', termCode)
    );
    return HttpEngine.decode<Week[]>(result.body, []);
  }

  /** 指定学期的某周课表。 */
  static async fetchWeeklySchedule(termCode: string, week: number): Promise<WeeklySchedule> {
    if (TokenStore.getDemoMode()) {
      return MockData.weeklySchedule();
    }
    if (ApiService.localMode()) {
      return await LocalAcademicService.fetchWeeklySchedule(termCode, week);
    }
    const query = new Map<string, string>();
    query.set('termCode', termCode);
    query.set('week', week.toString());
    const result = await HttpEngine.request(
      http.RequestMethod.GET,
      ApiService.apiPath('/schedule/week'),
      undefined,
      true,
      query
    );
    return HttpEngine.decode<WeeklySchedule>(result.body, {
      arrangedList: [],
      code: '',
      name: '',
      sectionTimes: []
    });
  }

  /** 今日课程摘要。 */
  static async fetchTodayClasses(): Promise<TodayClass[]> {
    if (TokenStore.getDemoMode()) {
      await MockData.pause();
      return MockData.todayClasses();
    }
    if (ApiService.localMode()) {
      return await LocalAcademicService.fetchTodayClasses();
    }
    const result = await HttpEngine.request(
      http.RequestMethod.GET,
      ApiService.apiPath('/schedule/today')
    );
    return HttpEngine.decode<TodayClass[]>(result.body, []);
  }

  /* ========================= 考试 ========================= */

  static async fetchExams(termCode: string): Promise<ExamArrangementData> {
    if (TokenStore.getDemoMode()) {
      await MockData.pause();
      return MockData.exams(termCode);
    }
    if (ApiService.localMode()) {
      return await LocalAcademicService.fetchExams(termCode);
    }
    const result = await HttpEngine.request(
      http.RequestMethod.GET,
      ApiService.apiPath('/exam/list'),
      undefined,
      true,
      ApiService.singleQuery('termCode', termCode)
    );
    return HttpEngine.decode<ExamArrangementData>(result.body, { arranged: [], notArranged: [] });
  }

  /* ========================= 成绩 ========================= */

  static async fetchGrades(termCode: string): Promise<GradeData> {
    if (TokenStore.getDemoMode()) {
      await MockData.pause();
      return MockData.grades(termCode);
    }
    if (ApiService.localMode()) {
      return await LocalAcademicService.fetchGrades(termCode);
    }
    const result = await HttpEngine.request(
      http.RequestMethod.GET,
      ApiService.apiPath('/grade/list'),
      undefined,
      true,
      ApiService.singleQuery('termCode', termCode)
    );
    return HttpEngine.decode<GradeData>(result.body, { termCode: termCode, grades: [] });
  }

  /* ========================= 空闲教室 ========================= */

  static async queryClassroom(xqid: number, date: string): Promise<ClassroomQueryResponse> {
    if (TokenStore.getDemoMode()) {
      await MockData.pause();
      return MockData.classroom(xqid);
    }
    if (ApiService.localMode()) {
      return await LocalAcademicService.queryClassroom(xqid, date);
    }
    const query = new Map<string, string>();
    query.set('xqid', xqid.toString());
    query.set('date', date);
    const result = await HttpEngine.request(
      http.RequestMethod.GET,
      ApiService.apiPath('/classroom/query'),
      undefined,
      true,
      query
    );
    return HttpEngine.decode<ClassroomQueryResponse>(result.body, {
      e: 0,
      m: '',
      d: { list: {} }
    });
  }

  /* ========================= 课堂签到 ========================= */

  /**
   * 今日可签到的课堂列表。
   *
   * 走 iclass（一体化课堂）：它自成一套会话（`userId` + `sessionId`），即使 SSO
   * 正常也要先用跳转链换一次（见 LocalSigninService 头部注释）。
   */
  static async fetchSigninClasses(): Promise<SigninClass[]> {
    if (TokenStore.getDemoMode()) {
      await MockData.pause();
      // 演示模式不编造签到数据 —— 签到是不可撤销的真实动作，假的会误导
      return [];
    }
    if (ApiService.localMode()) {
      return await LocalSigninService.fetchTodayClasses();
    }
    const result = await HttpEngine.request(
      http.RequestMethod.GET,
      ApiService.apiPath('/signin/today')
    );
    return HttpEngine.decode<SigninClass[]>(result.body, []);
  }

  /** 对指定课程签到（不可撤销，只应由用户点击触发）。 */
  static async performSignin(courseId: string): Promise<SigninActionResult> {
    if (TokenStore.getDemoMode()) {
      await MockData.pause();
      return { success: false, message: '演示模式不支持签到' };
    }
    if (ApiService.localMode()) {
      return await LocalSigninService.signIn(courseId);
    }
    const result = await HttpEngine.request(
      http.RequestMethod.POST,
      ApiService.apiPath('/signin/do'),
      undefined,
      true,
      ApiService.singleQuery('courseId', courseId)
    );
    return HttpEngine.decode<SigninActionResult>(result.body,
      { success: false, message: '签到失败' });
  }

  /* ========================= SPOC ========================= */

  /**
   * SPOC 作业列表（含当前学期与全部分页）。
   *
   * SPOC 有自己一套 token 体系（见 LocalSpocService 头部注释），且没有对应的
   * `/api/v1/*` 旧接口，所以只支持本地模式。
   */
  static async fetchSpocAssignments(): Promise<SpocAssignmentsData> {
    if (TokenStore.getDemoMode()) {
      await MockData.pause();
      return { termCode: '', termName: '', assignments: [] };
    }
    if (ApiService.localMode()) {
      return await LocalSpocService.fetchAssignments();
    }
    throw new ApiError(503, 'upstream_down', 'SPOC 仅支持本地（校内直连 / WebVPN）模式');
  }

  /** SPOC 作业详情。 */
  static async fetchSpocAssignmentDetail(assignmentId: string): Promise<SpocAssignmentDetail> {
    if (TokenStore.getDemoMode()) {
      await MockData.pause();
      throw new ApiError(503, 'upstream_down', '演示模式不支持 SPOC');
    }
    if (ApiService.localMode()) {
      return await LocalSpocService.fetchAssignmentDetail(assignmentId);
    }
    throw new ApiError(503, 'upstream_down', 'SPOC 仅支持本地（校内直连 / WebVPN）模式');
  }

  /* ========================= 阳光打卡 ========================= */

  /**
   * 阳光打卡概览（分类 / 运动项目 / 学期统计）。
   *
   * 与 SPOC 一样自成一套 uid+token 会话（见 LocalYgdkService 头部注释），
   * 没有对应的 `/api/v1/*` 旧接口，所以只支持本地模式。
   */
  static async fetchYgdkOverview(): Promise<YgdkOverview> {
    if (TokenStore.getDemoMode()) {
      await MockData.pause();
      throw new ApiError(503, 'upstream_down', '演示模式不支持阳光打卡');
    }
    if (ApiService.localMode()) {
      return await LocalYgdkService.fetchOverview();
    }
    throw new ApiError(503, 'upstream_down', '阳光打卡仅支持本地（校内直连 / WebVPN）模式');
  }

  /** 阳光打卡记录（分页）。 */
  static async fetchYgdkRecords(page: number, size: number): Promise<YgdkRecordsData> {
    if (TokenStore.getDemoMode()) {
      await MockData.pause();
      throw new ApiError(503, 'upstream_down', '演示模式不支持阳光打卡');
    }
    if (ApiService.localMode()) {
      return await LocalYgdkService.fetchRecords(page, size);
    }
    throw new ApiError(503, 'upstream_down', '阳光打卡仅支持本地（校内直连 / WebVPN）模式');
  }

  /**
   * 提交阳光打卡。**入参可以全空** —— 空字段由 `LocalYgdkService` 自动填写
   * （默认项目 / 自动 1 小时时间段 / 默认照片 / 默认地点），这就是界面上的「一键打卡」。
   */
  static async submitYgdkClockin(input: YgdkClockinInput): Promise<YgdkClockinResult> {
    if (TokenStore.getDemoMode()) {
      await MockData.pause();
      throw new ApiError(503, 'upstream_down', '演示模式不支持阳光打卡');
    }
    if (ApiService.localMode()) {
      return await LocalYgdkService.submitClockin(input);
    }
    throw new ApiError(503, 'upstream_down', '阳光打卡仅支持本地（校内直连 / WebVPN）模式');
  }

  /* ========================= 博雅课程 ========================= */

  /**
   * 博雅课程列表。
   *
   * 与 SPOC / 阳光打卡一样自成一套加密网关（见 `LocalBykcService`），
   * 没有对应的 `/api/v1/*` 旧接口，所以只支持本地模式。
   */
  static async fetchBykcCourses(page: number, size: number,
    all: boolean = false): Promise<BykcCoursesData> {
    if (TokenStore.getDemoMode()) {
      await MockData.pause();
      throw new ApiError(503, 'upstream_down', '演示模式不支持博雅课程');
    }
    if (ApiService.localMode()) {
      return await LocalBykcService.fetchCourses(page, size, all);
    }
    throw new ApiError(503, 'upstream_down', '博雅课程仅支持本地（校内直连 / WebVPN）模式');
  }

  /** 博雅课程详情。 */
  static async fetchBykcCourseDetail(courseId: number): Promise<BykcCourseDetail> {
    if (TokenStore.getDemoMode()) {
      await MockData.pause();
      throw new ApiError(503, 'upstream_down', '演示模式不支持博雅课程');
    }
    if (ApiService.localMode()) {
      return await LocalBykcService.fetchCourseDetail(courseId);
    }
    throw new ApiError(503, 'upstream_down', '博雅课程仅支持本地（校内直连 / WebVPN）模式');
  }

  /** 博雅已选课程。 */
  static async fetchBykcChosen(): Promise<BykcChosenCourse[]> {
    if (TokenStore.getDemoMode()) {
      await MockData.pause();
      throw new ApiError(503, 'upstream_down', '演示模式不支持博雅课程');
    }
    if (ApiService.localMode()) {
      return await LocalBykcService.fetchChosenCourses();
    }
    throw new ApiError(503, 'upstream_down', '博雅课程仅支持本地（校内直连 / WebVPN）模式');
  }

  /** 博雅分类统计。 */
  static async fetchBykcStatistics(): Promise<BykcStatistics> {    if (TokenStore.getDemoMode()) {
      await MockData.pause();
      throw new ApiError(503, 'upstream_down', '演示模式不支持博雅课程');
    }
    if (ApiService.localMode()) {
      return await LocalBykcService.fetchStatistics();
    }
    throw new ApiError(503, 'upstream_down', '博雅课程仅支持本地（校内直连 / WebVPN）模式');
  }

  /** 博雅选课（**写操作**，界面上要二次确认）。 */
  static async chooseBykcCourse(courseId: number): Promise<string> {
    ApiService.requireLocal('博雅课程');
    return await LocalBykcService.chooseCourse(courseId);
  }

  /** 博雅退选（**写操作**）——传课程 id。 */
  static async dropBykcCourse(courseId: number): Promise<string> {
    ApiService.requireLocal('博雅课程');
    return await LocalBykcService.dropCourse(courseId);
  }

  /** 博雅签到 / 签退（**写操作**，`signType`：1 签、2 退）。 */
  static async signBykcCourse(courseId: number, signType: number): Promise<string> {
    ApiService.requireLocal('博雅课程');
    return await LocalBykcService.signCourse(courseId, signType);
  }

  /** 写操作的统一前置检查：演示模式与「旧服务端」模式都不支持本地直连的写接口。 */
  private static requireLocal(feature: string): void {
    if (TokenStore.getDemoMode()) {
      throw new ApiError(503, 'upstream_down', '演示模式不支持' + feature);
    }
    if (!ApiService.localMode()) {
      throw new ApiError(503, 'upstream_down', feature + '仅支持本地（校内直连 / WebVPN）模式');
    }
  }

  /* ============================== iHome ============================== */

  /**
   * iHome 列表（广场 / 我的发起 / 我的关注 / 我的评价）。
   *
   * iHome 是独立域名（i.buaa.edu.cn）+ 自己的 Bearer token，没有 /api/v1 接口，
   * 只支持本地模式。
   */
  static async fetchIhomePage(scope: IhomeScope, page: number, keyword: string,
    filter: IhomeFilter, categoryId: number): Promise<IhomePage> {
    if (TokenStore.getDemoMode()) {
      throw new ApiError(503, 'upstream_down', '演示模式不支持 iHome');
    }
    ApiService.requireLocal('iHome');
    return await LocalIhomeService.fetchPage(scope, page, keyword, filter, categoryId);
  }

  /** 诉求详情。mine 为真时走「我的发起」详情接口。 */
  static async fetchIhomeDetail(id: number, mine: boolean): Promise<IhomeAppeal> {
    ApiService.requireLocal('iHome');
    return await LocalIhomeService.fetchDetail(id, mine);
  }

  /** 平台配置（支持开关 + 分类字典）。 */
  static async fetchIhomeConfig(): Promise<IhomeConfig> {
    ApiService.requireLocal('iHome');
    return await LocalIhomeService.fetchConfig();
  }

  /** 公告列表。 */
  static async fetchIhomeNotices(): Promise<IhomeNotice[]> {
    ApiService.requireLocal('iHome');
    return await LocalIhomeService.fetchNotices();
  }

  /** 关注 / 支持（**写操作**；按目标状态提交，相同则不写）。 */
  static async setIhomeReaction(id: number, reaction: IhomeReaction,
    enabled: boolean): Promise<IhomeReactionResult> {
    ApiService.requireLocal('iHome');
    return await LocalIhomeService.setReaction(id, reaction, enabled);
  }

  /* ========================= 希冀作业 ========================= */

  /**
   * 希冀作业列表。
   *
   * 希冀是纯网页系统（judge.buaa.edu.cn），没有 /api/v1 接口，只能本地模式抓页面
   * 再解析，所以这里与 SPOC / 阳光打卡一样只支持本地模式。
   *
   * @param includeExpired 是否包含六个月以前的历史作业
   */
  static async fetchJudgeAssignments(includeExpired: boolean): Promise<JudgeAssignmentsResponse> {
    if (TokenStore.getDemoMode()) {
      throw new ApiError(503, 'upstream_down', '演示模式不支持希冀作业');
    }
    ApiService.requireLocal('希冀作业');
    return await LocalJudgeService.fetchAssignments(includeExpired);
  }

  /** 单条希冀作业详情（题目 / 得分 / 提交状态）。 */
  static async fetchJudgeDetail(courseId: string,
    assignmentId: string): Promise<JudgeAssignmentDetail> {
    ApiService.requireLocal('希冀作业');
    return await LocalJudgeService.fetchDetail(courseId, assignmentId);
  }

  /* ========================= 自动评教 ========================= */

  /**
   * 评教课程列表（含已评教与进度）。
   *
   * 评教子系统自成一套 CAS 会话（`/pjxt/cas` 换一次），没有对应的 `/api/v1/*`
   * 旧接口，所以只支持本地模式。
   */
  static async fetchEvaluations(): Promise<EvaluationCoursesResponse> {
    if (TokenStore.getDemoMode()) {
      throw new ApiError(503, 'upstream_down', '演示模式不支持自动评教');
    }
    ApiService.requireLocal('自动评教');
    return await LocalEvaluationService.fetchCourses();
  }

  /** 逐门提交评教（**写操作**，不可撤销，只由用户点击触发）。 */
  static async submitEvaluation(course: EvaluationCourse): Promise<EvaluationResult> {
    ApiService.requireLocal('自动评教');
    return await LocalEvaluationService.submitCourse(course);
  }

  /** 批量提交评教（逐门串行，分门返回结果）。 */
  static async submitEvaluations(courses: EvaluationCourse[]): Promise<EvaluationResult[]> {
    ApiService.requireLocal('自动评教');
    return await LocalEvaluationService.submitAll(courses);
  }

  /* ========================= 版本 / 公告 ========================= */

  static async checkVersion(): Promise<string> {
    if (TokenStore.getDemoMode()) {
      await MockData.pause();
      return MockData.version();
    }
    if (ApiService.localMode()) {
      // 版本清单由 SERVER_RELAY 服务端托管（已停止部署），校内上游没有对应的接口；
      // 与其打一个必然 502 的地址，不如如实说明当前不可用。
      throw new ApiError(503, 'upstream_down', '更新检查由已停止部署的 UBAA 服务端提供，本地模式暂不支持');
    }
    const result = await HttpEngine.request(
      http.RequestMethod.GET,
      ApiService.apiPath('/app/version'),
      undefined,
      false,
      ApiService.singleQuery('clientVersion', AppConfig.APP_VERSION)
    );
    return result.body;
  }

  /** 把登录响应落盘为本地会话。 */
  static persistLogin(response: LoginResponse, username: string): void {
    const session = new StoredSession();
    session.accessToken = response.accessToken;
    session.refreshToken = response.refreshToken;
    session.accessTokenExpiresAt = response.accessTokenExpiresAt;
    session.refreshTokenExpiresAt = response.refreshTokenExpiresAt;
    session.userName = response.user.name;
    session.schoolId = response.user.schoolid;
    session.username = username;
    TokenStore.saveSession(session);
  }

  /** 用 UserData 更新本地缓存的用户信息。 */
  static persistUser(user: UserData): void {
    const session = TokenStore.getSession();
    session.userName = user.name;
    session.schoolId = user.schoolid;
    TokenStore.saveSession(session);
  }
}
