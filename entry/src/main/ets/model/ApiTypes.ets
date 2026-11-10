/**
 * 服务端数据契约（与 UBAA 后端 /api/v1 一一对应）。
 *
 * 字段名必须与服务端 JSON 完全一致（后端由 kotlinx.serialization 序列化）。
 */

/* ============================ 通用 ============================ */

export interface ErrorDetails {
  code: string;
  message: string;
}

export interface ErrorResponse {
  error: ErrorDetails;
}

/* ============================ 认证 ============================ */

export interface UserData {
  name: string;
  schoolid: string;
}

export interface LoginRequest {
  username: string;
  password: string;
  captcha?: string;
  execution?: string;
  clientId?: string;
}

export interface LoginResponse {
  user: UserData;
  accessToken: string;
  refreshToken: string;
  accessTokenExpiresAt: string;
  refreshTokenExpiresAt: string;
}

export interface CaptchaInfo {
  id: string;
  type: string;
  imageUrl: string;
  base64Image?: string;
}

export interface CaptchaRequiredResponse {
  captcha: CaptchaInfo;
  execution: string;
  message: string;
}

export interface LoginPreloadRequest {
  clientId: string;
}

export interface LoginPreloadResponse {
  captchaRequired: boolean;
  captcha?: CaptchaInfo;
  execution?: string;
  clientId?: string;
  accessToken?: string;
  refreshToken?: string;
  accessTokenExpiresAt?: string;
  refreshTokenExpiresAt?: string;
  userData?: UserData;
}

export interface TokenRefreshRequest {
  refreshToken: string;
}

export interface TokenRefreshResponse {
  accessToken: string;
  refreshToken: string;
  accessTokenExpiresAt: string;
  refreshTokenExpiresAt: string;
}

export interface SessionStatusResponse {
  user: UserData;
  lastActivity: string;
  authenticatedAt: string;
}

/* ============================ 用户信息 ============================ */

export interface UserInfo {
  idCardType?: string;
  idCardTypeName?: string;
  phone?: string;
  schoolid?: string;
  name?: string;
  idCardNumber?: string;
  email?: string;
  username?: string;
}

/* ============================ 课表 ============================ */

export interface Term {
  itemCode: string;
  itemName: string;
  selected: boolean;
  itemIndex: number;
}

export interface Week {
  startDate: string;
  endDate: string;
  term: string;
  curWeek: boolean;
  serialNumber: number;
  name: string;
}

export interface CourseClass {
  courseCode: string;
  courseName: string;
  courseSerialNo?: string;
  credit?: string;
  beginTime?: string;
  endTime?: string;
  beginSection?: number;
  endSection?: number;
  placeName?: string;
  weeksAndTeachers?: string;
  teachingTarget?: string;
  color?: string;
  dayOfWeek?: number;
  /* ---- 课程详情（点击课程块弹出的信息，与课表来自同一份上游响应） ---- */
  /**
   * 上游预置的详情行，形如 `["本研标识：本","课程号：B090031025",…]`。
   *
   * 实测 `getMyScheduleDetail.do` 的课表项自带这个数组，内容与官方 App 的课表详情一致；
   * 我们的固定行之外再把它附在末尾，避免漏掉上游新加的字段。
   */
  titleDetail?: string[];
}

export interface SectionTime {
  section: number;
  start?: string;
  end?: string;
}

export interface WeeklySchedule {
  arrangedList: CourseClass[];
  code: string;
  name: string;
  sectionTimes: SectionTime[];
}

export interface TodayClass {
  bizName: string;
  place?: string;
  time?: string;
  shortName?: string;
}

/* ============================ 考试 ============================ */

export interface Exam {
  courseName: string;
  courseNo?: string;
  examTimeDescription?: string;
  examDate?: string;
  startTime?: string;
  endTime?: string;
  examPlace?: string;
  examSeatNo?: string;
  week?: number;
  examStatus?: number;
  examType?: string;
  taskId?: string;
}

export interface ExamStudentInfo {
  name?: string;
  studentId?: string;
  department?: string;
  major?: string;
  grade?: string;
}

export interface ExamArrangementData {
  stuInfo?: ExamStudentInfo;
  arranged: Exam[];
  notArranged: Exam[];
}

/* ============================ 成绩 ============================ */

export interface Grade {
  WID?: string;
  XNXQDM?: string;
  XNXQDM_DISPLAY?: string;
  KCM?: string;
  KCH?: string;
  TDKCM?: string;
  TDKCH?: string;
  XF?: number;
  XSZCJ?: string;
  JD?: string;
  KCLBDM_DISPLAY?: string;
  XGXKLBDM_DISPLAY?: string;
  KCXZDM_DISPLAY?: string;
  KSLXDM_DISPLAY?: string;
  CXCKDM_DISPLAY?: string;
  SFJG_DISPLAY?: string;
  SFYX_DISPLAY?: string;
  CJRDFSDM_DISPLAY?: string;
}

export interface GradeData {
  termCode: string;
  grades: Grade[];
}

/* ============================ 空闲教室 ============================ */

export interface ClassroomInfo {
  id: string;
  floorid: string;
  name: string;
  /** 空闲节次，逗号分隔，如 "1,2,5,6"。 */
  kxsds: string;
}

export interface ClassroomData {
  list: Record<string, ClassroomInfo[]>;
}

export interface ClassroomQueryResponse {
  e: number;
  m: string;
  d: ClassroomData;
}

/* ============================ 课堂签到 ============================ */

/** 一堂可签到的课（上游 iclass `get_stu_course_sched` 的 result 项）。 */
export interface SigninClass {
  courseId: string;
  courseName: string;
  classBeginTime: string;
  classEndTime: string;
  /** 0 = 未签到，1 = 已签到。 */
  signStatus: number;
}

/** 签到动作的执行结果（对应原 `SigninActionResponse` 的 success / message）。 */
export interface SigninActionResult {
  success: boolean;
  message: string;
}

/* ============================ SPOC 作业 ============================ */

/** SPOC 作业（列表项）。 */
export interface SpocAssignment {
  assignmentId: string;
  courseId: string;
  courseName: string;
  teacherName?: string;
  title: string;
  /** 开始时间，形如 `2026-09-01 08:00:00`。 */
  startTime?: string;
  /** 截止时间。 */
  dueTime?: string;
  /**
   * 作业满分（上游列表接口的 `mf`）。
   *
   * ⚠️ 这不是学生得分 —— 实测已提交与未提交的作业取值相同（都是课程统一设定的满分）。
   * 学生的实际得分在详情接口里（`SpocAssignmentDetail.score` ← `zyfs`）。
   */
  fullScore?: string;
  /** 「已提交 / 未提交 / 未知状态(x)」的展示文案。 */
  submissionStatusText: string;
  /** 是否已提交（列表徽标配色用）。 */
  submitted: boolean;
}

export interface SpocAssignmentsData {
  termCode: string;
  termName: string;
  assignments: SpocAssignment[];
}

/** SPOC 作业详情。 */
export interface SpocAssignmentDetail {
  assignmentId: string;
  courseName: string;
  teacherName?: string;
  title: string;
  startTime?: string;
  dueTime?: string;
  score?: string;
  submissionStatusText: string;
  submitted: boolean;
  submittedAt?: string;
  /** 作业要求正文（已去 HTML 标签的纯文本）。 */
  contentText?: string;
}

/* ============================ 阳光打卡 ============================ */

/** 阳光打卡统计（学期 / 周 / 月 / 日次数与目标）。 */
export interface YgdkSummary {
  termName?: string;
  /** 已有效打卡次数。 */
  termCount: number;
  /** 学期目标次数。 */
  termTarget?: number;
  weekCount?: number;
  weekTarget?: number;
  monthCount?: number;
  monthTarget?: number;
  dayCount?: number;
  /** 有效次数。 */
  goodCount?: number;
}

/** 运动项目。 */
export interface YgdkItem {
  itemId: number;
  name: string;
  type?: number;
  sort?: number;
}

export interface YgdkOverview {
  classifyId: number;
  classifyName: string;
  items: YgdkItem[];
  summary: YgdkSummary;
  /** 自动填写用：默认运动项目（名字含「跑」的，取不到则 `sort` 最小）。 */
  defaultItemId: number;
  defaultItemName: string;
  /** 自动填写用：默认时间段的文案（`yyyy-MM-dd HH:mm-HH:mm`），仅用于展示。 */
  defaultTimeText: string;
}

/** 一条打卡记录。 */
export interface YgdkRecord {
  recordId: number;
  itemId?: number;
  itemName?: string;
  /** `yyyy-MM-dd HH:mm`。 */
  startTime?: string;
  endTime?: string;
  place?: string;
  isOpen: boolean;
  state?: number;
  createdAtLabel?: string;
}

export interface YgdkRecordsData {
  records: YgdkRecord[];
  total: number;
}

/* ---------------------------- 阳光打卡：提交 ---------------------------- */

/**
 * 提交打卡的入参。**全部可留空** —— 留空的字段由 `LocalYgdkService` 自动填写
 * （规则照抄原版 UBAA，见 `submitClockin` 的注释）。
 */
export interface YgdkClockinInput {
  /** 运动项目 id；留空 = 自动挑（名字含「跑」的，取不到则 `sort` 最小）。 */
  itemId?: number;
  /** 地点；留空 = 「操场」。 */
  place?: string;
  /** 是否分享到广场；留空 = 不分享。 */
  share?: boolean;
  /** 开始时间 `yyyy-MM-dd HH:mm`；与 `endTime` 同时留空 = 自动生成 1 小时。 */
  startTime?: string;
  endTime?: string;
}

export interface YgdkClockinResult {
  recordId: number;
  /** 打卡后上游回的最新统计（学期 / 周 / 月次数与目标）。 */
  summary: YgdkSummary;
}

/* ============================ 博雅课程 ============================ */

/**
 * 博雅课程（公选课）列表项。
 *
 * 字段来源：上游 `queryStudentSemesterCourseByPage` 的 `content[]`。
 * `statusText` 不是上游给的，是**本地按报名 / 上课时间算出来的**（与原版同一套规则）。
 */
export interface BykcCourse {
  id: number;
  courseName: string;
  teacher?: string;
  position?: string;
  /** 上课开始 / 结束时间（`yyyy-MM-dd HH:mm`，可能只到日期）。 */
  startDate?: string;
  endDate?: string;
  /** 报名窗口 / 退选截止。 */
  selectStartDate?: string;
  selectEndDate?: string;
  cancelEndDate?: string;
  maxCount: number;
  currentCount?: number;
  /** 大类（如「博雅课程」）。 */
  category?: string;
  /** 小类（德育/ 美育 / 劳动教育 / 安全健康 / 其他方面）—— **筛选按这个走**。 */
  subCategory?: string;
  /** 受众校区；`未指定校区` 表示不限。 */
  campuses: string[];
  /** 状态文案：可选 / 已选 / 预告 / 人数已满 / 选课结束 / 已过期。 */
  statusText: string;
  /**
   * 状态**枚举名**（`AVAILABLE` / `SELECTED` / `PREVIEW` / `FULL` / `ENDED` / `EXPIRED`）。
   *
   * 筛选按枚举做（`statusText` 是展示用的中文，逻辑上不可靠）。
   */
  status: string;
  selected: boolean;
  /** 该课程是否需要签到（配置里有签到点）。 */
  hasSignPoints: boolean;
}

export interface BykcCoursesData {
  courses: BykcCourse[];
  total: number;
  totalPages: number;
  page: number;
  pageSize: number;
}

/** 课程详情：列表项 + 联系方式 / 简介 / 受众 + 已选时的考勤。 */
export interface BykcCourseDetail {
  course: BykcCourse;
  /** 课程简介（**已去掉 HTML 标签**，上游给的是富文本）。 */
  description?: string;
  contact?: string;
  contactMobile?: string;
  organizer?: string;
  /** 受众（校区 / 学院 / 年级等，多个用「、」拼好）。 */
  audiences?: string;
  /** 已选时的考勤：签到次数与考核是否通过。 */
  checkin?: number;
  pass?: number;
  canSign: boolean;
  canSignOut: boolean;
  /** 签到 / 签退时间窗文案，形如 `09-01 08:00 ~ 09-01 09:00`。 */
  signWindow?: string;
}

/** 已选课程（`queryChosenCourse`）。 */
export interface BykcChosenCourse {
  /** 选课记录 id（退选用它，不是 courseId）。 */
  chosenId: number;
  courseId: number;
  courseName: string;
  teacher?: string;
  position?: string;
  category?: string;
  subCategory?: string;
  startDate?: string;
  endDate?: string;
  selectDate?: string;
  cancelEndDate?: string;
  checkin: number;
  score?: number;
  pass?: number;
  canSign: boolean;
  canSignOut: boolean;
  homework?: string;
}

/** 分类统计的一行（大类 + 小类 + 应修 / 已通过）。 */
export interface BykcCategoryStat {
  categoryName: string;
  subCategoryName: string;
  required: number;
  passed: number;
}

export interface BykcStatistics {
  /** 有效门数（上游 `validCount`）。 */
  validCount: number;
  categories: BykcCategoryStat[];
}

/* ========================== 图书馆座位 ========================== */

/** 楼馆。 */
export interface BykcLibBookLibrary {
  id: string;
  name: string;
  /** 剩余座位数（上游直接给，不做累加）。 */
  freeNum: number;
  totalNum: number;
  /** 楼层（嵌在楼馆里，**不需要单独请求**）。 */
  storeys: BykcLibBookStorey[];
}

/** 楼层。 */
export interface BykcLibBookStorey {
  id: string;
  name: string;
  freeNum: number;
  totalNum: number;
}

/** 分区（如「301南阅览区」）。 */
export interface BykcLibBookArea {
  id: string;
  /** 分区全名（UI 用这个）。 */
  name: string;
  /** 校区名（如「学院路」）。 */
  areaName: string;
  premisesId: string;
  storeyId: string;
  freeNum: number;
  totalNum: number;
}

/** 座位。 */
export interface BykcLibBookSeat {
  id: string;
  /** 座位全称。 */
  name: string;
  /** 座位号（UI 首选）。 */
  no: string;
  /** 状态码：`1`=可预约，`2`=已占用，`3`=临时离开。 */
  status: string;
  /** 上游给的中文状态文案。 */
  statusName: string;
  /** 是否可预约（`status === '1'`）。 */
  isAvailable: boolean;
}

/** 预约记录。 */
export interface BykcLibBookBooking {
  id: string;
  /** 合并名（如「一层 / 101」）。 */
  nameMerge: string;
  /** 分区名。 */
  areaName: string;
  /** 座位号。 */
  seatNo: string;
  /** 日期。 */
  day: string;
  beginTime: string;
  endTime: string;
  /** 状态码：`1`=已预约，`6`=用户取消，`8`=已结束。 */
  status: string;
  /** 上游给的中文状态文案。 */
  statusName: string;
}

/* ============================ 自动评教 ============================ */

/**
 * 待评教课程。
 *
 * 字段与上游 `getRequiredReviewsData` 的条目一一对应：UI 只展示 `kcmc`（课程名）/
 * `bpmc`（教师）与 `isEvaluated`，其余字段是**提交时必须原样回传**的上游参数。
 */
export interface EvaluationCourse {
  /** 本地合成的主键：`rwid_wjid_kcdm_bpdm`。 */
  id: string;
  kcmc: string;
  bpmc: string;
  /** 是否已评教（由上游 `ypjcs > 0` 推出）。 */
  isEvaluated: boolean;
  rwid: string;
  wjid: string;
  kcdm: string;
  bpdm?: string;
  pjrdm?: string;
  pjrmc?: string;
  xnxq?: string;
  /** 问卷模式 id，提交前要用它切一次问卷模式。 */
  msid: string;
  zdmc?: string;
  ypjcs?: number;
  xypjcs?: number;
  sxz?: string;
  rwh?: string;
  xn?: string;
  xq?: string;
  pjlxid?: string;
  sfksqbpj?: string;
  yxsfktjst?: string;
}

/** 评教进度（已评教 / 待评教 / 总数）。 */
export interface EvaluationProgress {
  totalCourses: number;
  evaluatedCourses: number;
  pendingCourses: number;
}

export interface EvaluationCoursesResponse {
  courses: EvaluationCourse[];
  progress: EvaluationProgress;
}

/** 单门课程的提交结果。 */
export interface EvaluationResult {
  success: boolean;
  message: string;
  courseName: string;
}

/* ============================ 希冀作业 ============================ */

/** 希冀作业 / 题目的提交状态（与上游 `JudgeSubmissionStatus` 一致）。 */
export enum JudgeStatus {
  SUBMITTED = 'SUBMITTED',
  PARTIAL = 'PARTIAL',
  UNSUBMITTED = 'UNSUBMITTED',
  UNKNOWN = 'UNKNOWN'
}

export interface JudgeProblem {
  /** 题名（上游表格里的第二个单元格；两列表格时是「第 N 题」）。 */
  name: string;
  score?: string;
  maxScore?: string;
  status: JudgeStatus;
  statusText: string;
}

/** 作业摘要（列表项）。 */
export interface JudgeAssignmentSummary {
  courseId: string;
  courseName: string;
  assignmentId: string;
  title: string;
  startTime?: string;
  dueTime?: string;
  maxScore?: string;
  myScore?: string;
  totalProblems: number;
  submittedCount: number;
  submissionStatus: JudgeStatus;
  submissionStatusText: string;
}

export interface JudgeAssignmentsResponse {
  assignments: JudgeAssignmentSummary[];
  /** 六个月内没有作业的课程（原版用于记录「冷课程」，这里只做展示/排查）。 */
  historicalCutoffCourseIds: string[];
}

export interface JudgeAssignmentDetail extends JudgeAssignmentSummary {
  problems: JudgeProblem[];
  /** 作业正文的纯文本（HTML 去标签后），拿不到时为空。 */
  contentPlainText?: string;
}

/* ============================== iHome ============================== */

/** iHome 的五个视图。 */
export enum IhomeScope {
  PUBLIC = 'PUBLIC',
  MINE = 'MINE',
  FOLLOWED = 'FOLLOWED',
  APPRAISED = 'APPRAISED',
  NOTICE = 'NOTICE'
}

/** 列表筛选（与上游同名参数一一对应）。 */
export enum IhomeFilter {
  ALL = 'ALL',
  NEWEST = 'NEWEST',
  OLDEST = 'OLDEST',
  REPLIED = 'REPLIED',
  UNREPLIED = 'UNREPLIED',
  REPLY_TIME = 'REPLY_TIME'
}

export interface IhomeReply {
  content: string;
  department: string;
  createdAt: string;
}

export interface IhomeHistory {
  content: string;
  createdAt: string;
}

/** 评价（三个维度 + 内容）。 */
export interface IhomeEvaluation {
  id: number;
  department: string;
  speed: number;
  satisfaction: number;
  degree: number;
  content: string;
  createdAt: string;
}

export interface IhomeAppeal {
  id: number;
  content: string;
  status: string;
  category: string;
  publishedAt: string;
  departments: string[];
  isMine: boolean;
  isFollowed?: boolean;
  isSupported?: boolean;
  followCount?: number;
  supportCount?: number;
  replies: IhomeReply[];
  evaluations: IhomeEvaluation[];
  history: IhomeHistory[];
}

/** 列表项：「我的评价」视图会带 evaluation。 */
export interface IhomeEntry {
  appeal: IhomeAppeal;
  evaluation?: IhomeEvaluation;
}

export interface IhomePage {
  entries: IhomeEntry[];
  page: number;
  lastPage: number;
  total: number;
}

export interface IhomeCategory {
  id: number;
  name: string;
}

export interface IhomeConfig {
  supportEnabled: boolean;
  supportLabel: string;
  categories: IhomeCategory[];
}

export interface IhomeNotice {
  id: number;
  title: string;
  content: string;
  date: string;
}

/** 关注 / 支持的目标状态（不是「切换」）。 */
export enum IhomeReaction {
  FOLLOW = 'FOLLOW',
  SUPPORT = 'SUPPORT'
}

export interface IhomeReactionResult {
  appeal?: IhomeAppeal;
  confirmed: boolean;
  message: string;
}

/* ============================ 版本 / 公告 ============================ */
export interface AppVersionInfo {
  hasUpdate?: boolean;
  latestVersion?: string;
  downloadUrl?: string;
  releaseNotes?: string;
  forceUpdate?: boolean;
}

export interface AnnouncementInfo {
  id?: string;
  title?: string;
  content?: string;
  publishedAt?: string;
}
