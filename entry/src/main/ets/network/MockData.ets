import { DateUtil } from '../common/DateUtil';
import {
  ClassroomInfo,
  ClassroomQueryResponse,
  CourseClass,
  Exam,
  ExamArrangementData,
  Grade,
  GradeData,
  LoginPreloadResponse,
  LoginResponse,
  SectionTime,
  SessionStatusResponse,
  Term,
  TodayClass,
  UserInfo,
  Week,
  WeeklySchedule
} from '../model/ApiTypes';

/**
 * 演示数据。
 *
 * 用途：服务端不可达（如 UBAA 网关 502）时，仍然能把客户端所有页面跑通，
 * 用于 UI 验收、截图、交互走查。真实联调时关掉「演示模式」即可完全走网络。
 *
 * 所有日期都相对「今天」动态推导，避免写死后倒计时失效。
 */

/** 模拟网络延迟，让加载态可见（毫秒）。 */
const DEMO_LATENCY: number = 420;

const DEMO_TERM_CODE: string = '2026-2027-1';
const DEMO_TERM_NAME: string = '2026-2027学年秋季学期';

/** 演示课表覆盖的教学周数。 */
const DEMO_WEEK_COUNT: number = 20;

/** 令「本周」对应第几周，由此反推开学日期。 */
const DEMO_CURRENT_WEEK: number = 3;

/** 期末考试所在周（第 18 周）。 */
const DEMO_EXAM_WEEK: number = 18;

const DEMO_USER_NAME: string = '演示用户';

export class MockData {
  /** 统一的假延迟。 */
  static async pause(): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(() => {
        resolve();
      }, DEMO_LATENCY);
    });
  }

  /** 由「本周 = 第 DEMO_CURRENT_WEEK 周」反推开学的那个周一。 */
  private static termStart(): Date {
    const now = new Date();
    const dow: number = now.getDay();
    const offset: number = dow === 0 ? -6 : 1 - dow;
    const monday: Date = DateUtil.addDays(now, offset);
    return DateUtil.addDays(monday, -7 * (DEMO_CURRENT_WEEK - 1));
  }

  private static dateAtWeek(week: number, dayOffset: number): string {
    const start: Date = MockData.termStart();
    return DateUtil.format(DateUtil.addDays(start, 7 * (week - 1) + dayOffset));
  }

  /* ============================ 认证 ============================ */

  static preload(): LoginPreloadResponse {
    return { captchaRequired: false };
  }

  static login(username: string): LoginResponse {
    const schoolId: string = username.length > 0 ? username : '2025000000';
    return {
      user: { name: DEMO_USER_NAME, schoolid: schoolId },
      accessToken: 'demo-access-token',
      refreshToken: 'demo-refresh-token',
      accessTokenExpiresAt: DateUtil.format(DateUtil.addDays(new Date(), 7)),
      refreshTokenExpiresAt: DateUtil.format(DateUtil.addDays(new Date(), 30))
    };
  }

  static status(schoolId: string): SessionStatusResponse {
    return {
      user: { name: DEMO_USER_NAME, schoolid: schoolId.length > 0 ? schoolId : '2025000000' },
      lastActivity: DateUtil.today(),
      authenticatedAt: DateUtil.today()
    };
  }

  static userInfo(schoolId: string, username: string): UserInfo {
    return {
      name: DEMO_USER_NAME,
      schoolid: schoolId,
      username: username.length > 0 ? username : schoolId,
      idCardType: '1',
      idCardTypeName: '居民身份证',
      phone: '138****0000',
      email: schoolId + '@buaa.edu.cn'
    };
  }

  /* ============================ 学期 / 教学周 ============================ */

  static terms(): Term[] {
    const list: Term[] = [];
    list.push({ itemCode: DEMO_TERM_CODE, itemName: DEMO_TERM_NAME, selected: true, itemIndex: 1 });
    list.push({
      itemCode: '2025-2026-2',
      itemName: '2025-2026学年春季学期',
      selected: false,
      itemIndex: 2
    });
    list.push({ itemCode: '2025-2026-3', itemName: '2025-2026学年夏季学期', selected: false, itemIndex: 3 });
    return list;
  }

  static weeks(): Week[] {
    const list: Week[] = [];
    for (let i = 1; i <= DEMO_WEEK_COUNT; i++) {
      const start: string = MockData.dateAtWeek(i, 0);
      const end: string = MockData.dateAtWeek(i, 6);
      list.push({
        startDate: start,
        endDate: end,
        term: DEMO_TERM_CODE,
        curWeek: i === DEMO_CURRENT_WEEK,
        serialNumber: i,
        name: i.toString()
      });
    }
    return list;
  }

  private static sectionTimes(): SectionTime[] {
    const times: string[][] = [
      ['08:00', '08:45'], ['08:55', '09:40'],
      ['10:00', '10:45'], ['10:55', '11:40'],
      ['14:00', '14:45'], ['14:55', '15:40'],
      ['16:00', '16:45'], ['16:55', '17:40'],
      ['19:00', '19:45'], ['19:55', '20:40'],
      ['20:50', '21:35'], ['21:45', '22:30']
    ];
    const list: SectionTime[] = [];
    for (let i = 0; i < times.length; i++) {
      list.push({ section: i + 1, start: times[i][0], end: times[i][1] });
    }
    return list;
  }

  /** 周课表：以「工程力学专业大二上」为蓝本的课程安排。 */
  static weeklySchedule(): WeeklySchedule {
    const palette: string[] = ['#1976D2', '#7B5EA7', '#2E9E6B', '#C77800', '#C2185B', '#00838F'];
    const raw: Array<[string, string, number, number, number, number, string]> = [
      // 课程名, 课程号, 星期, 起节, 止节, 配色, 地点
      ['理论力学A(2)', 'A011310', 1, 1, 2, 0, '沙河 J3-201'],
      ['工科数学分析(2)', 'A060220', 1, 3, 4, 1, '沙河 J4-105'],
      ['数据结构', 'A050311', 1, 7, 8, 3, '沙河 实验楼 A203'],
      ['材料力学', 'A011320', 2, 3, 4, 2, '沙河 J3-305'],
      ['工程图学(2)', 'A020112', 2, 5, 6, 5, '沙河 J3-408'],
      ['大学英语(3)', 'A070231', 2, 7, 8, 4, '沙河 W3-302'],
      ['数据结构', 'A050311', 3, 1, 2, 3, '沙河 J3-207'],
      ['高等代数(下)', 'A060121', 3, 3, 4, 1, '沙河 J4-106'],
      ['形势与政策(3)', 'A090113', 3, 9, 10, 4, '沙河 J3-101'],
      ['理论力学A(2)', 'A011310', 4, 1, 2, 0, '沙河 J3-201'],
      ['体育(3)', 'A100231', 4, 5, 6, 2, '沙河 田径场'],
      ['工科数学分析(2)', 'A060220', 5, 1, 2, 1, '沙河 J4-105'],
      ['大学物理实验', 'A080212', 5, 5, 8, 5, '沙河 物理实验中心'],
      ['高等代数(下)', 'A060121', 5, 3, 4, 1, '沙河 J4-106']
    ];

    const list: CourseClass[] = [];
    for (let i = 0; i < raw.length; i++) {
      const row = raw[i];
      list.push({
        courseCode: row[1],
        courseName: row[0],
        dayOfWeek: row[2],
        beginSection: row[3],
        endSection: row[4],
        placeName: row[6],
        color: palette[row[5]],
        credit: '3.0',
        weeksAndTeachers: '1-16周 · 演示教师'
      });
    }

    return {
      arrangedList: list,
      code: DEMO_TERM_CODE,
      name: DEMO_TERM_NAME,
      sectionTimes: MockData.sectionTimes()
    };
  }

  /** 今日课程：从周课表里挑今天（周日给空，符合真实感受）。 */
  static todayClasses(): TodayClass[] {
    const weekday: number = DateUtil.currentWeekday();
    const schedule: WeeklySchedule = MockData.weeklySchedule();
    const list: TodayClass[] = [];
    for (let i = 0; i < schedule.arrangedList.length; i++) {
      const item: CourseClass = schedule.arrangedList[i];
      if (item.dayOfWeek !== weekday) {
        continue;
      }
      const begin: number = item.beginSection !== undefined ? item.beginSection : 1;
      const end: number = item.endSection !== undefined ? item.endSection : begin;
      const time: SectionTime | null = MockData.sectionAt(begin);
      const endTime: SectionTime | null = MockData.sectionAt(end);
      let timeText: string = DateUtil.sectionRange(begin, end);
      if (time !== null && endTime !== null && time.start !== undefined && endTime.end !== undefined) {
        timeText = time.start + '-' + endTime.end;
      }
      list.push({
        bizName: item.courseName,
        place: item.placeName,
        time: timeText,
        shortName: item.courseName.length > 2 ? item.courseName.substring(0, 2) : item.courseName
      });
    }
    return list;
  }

  private static sectionAt(section: number): SectionTime | null {
    const times: SectionTime[] = MockData.sectionTimes();
    for (let i = 0; i < times.length; i++) {
      if (times[i].section === section) {
        return times[i];
      }
    }
    return null;
  }

  /* ============================ 考试 ============================ */

  static exams(termCode: string): ExamArrangementData {
    const raw: Array<[string, string, number, number, string]> = [
      // 课程名, 课程号, 距考试周首日的天偏移, 节次[起], 地点
      ['数据结构', 'A050311', 0, 1, '沙河 J3-101'],
      ['工科数学分析(2)', 'A060220', 2, 1, '沙河 J4-105'],
      ['理论力学A(2)', 'A011310', 3, 3, '沙河 J3-201'],
      ['高等代数(下)', 'A060121', 4, 1, '沙河 J4-106']
    ];

    const arranged: Exam[] = [];
    for (let i = 0; i < raw.length; i++) {
      const row = raw[i];
      const date: string = MockData.dateAtWeek(DEMO_EXAM_WEEK, row[2]);
      arranged.push({
        courseName: row[0],
        courseNo: row[1],
        examDate: date,
        startTime: '09:00',
        endTime: '11:00',
        examPlace: row[4],
        examSeatNo: (i + 1).toString(),
        examType: '期末考试',
        examStatus: 1
      });
    }

    return {
      stuInfo: {
        name: DEMO_USER_NAME,
        studentId: '2025000000',
        department: '航空科学与工程学院',
        major: '工程力学',
        grade: '2025级'
      },
      arranged: arranged,
      notArranged: [{ courseName: '体育(3)', courseNo: 'A100231', examTimeDescription: '随堂考核' }]
    };
  }

  /* ============================ 成绩 ============================ */

  static grades(termCode: string): GradeData {
    const raw: Array<[string, string, string, number, string, string]> = [
      // 课程名, 课程号, 成绩, 学分, 绩点, 课程类别
      ['工科数学分析(1)', 'A060210', '92', 5, '4.0', '学科基础课'],
      ['高等代数(上)', 'A060110', '88', 4, '3.7', '学科基础课'],
      ['C语言程序设计', 'A050210', '78', 3, '2.7', '学科基础课'],
      ['工程图学基础', 'A020110', '85', 3, '3.3', '学科基础课'],
      ['大学英语(2)', 'A070220', '90', 3, '4.0', '通识必修课'],
      ['思想道德与法治', 'A090110', '87', 3, '3.7', '通识必修课'],
      ['军事理论', 'A090210', '82', 2, '3.0', '通识必修课'],
      ['体育(2)', 'A100220', '95', 1, '4.0', '通识必修课']
    ];

    const list: Grade[] = [];
    for (let i = 0; i < raw.length; i++) {
      const row = raw[i];
      list.push({
        WID: 'demo-' + i.toString(),
        XNXQDM: termCode,
        XNXQDM_DISPLAY: '2025-2026学年春季学期',
        KCM: row[0],
        KCH: row[1],
        XF: row[3],
        XSZCJ: row[2],
        JD: row[4],
        KCLBDM_DISPLAY: row[5],
        KCXZDM_DISPLAY: '必修',
        KSLXDM_DISPLAY: '考试',
        SFYX_DISPLAY: '有效'
      });
    }
    return { termCode: termCode, grades: list };
  }

  /* ============================ 空闲教室 ============================ */

  static classroom(campusId: number): ClassroomQueryResponse {
    const buildings: string[] = campusId === 1 ?
      ['主楼', '教学区北楼'] : ['J3 教学楼', 'J4 教学楼', 'W3 教学楼'];
    const prefix: string = campusId === 1 ? '学院路 ' : '沙河 ';

    const list: Record<string, ClassroomInfo[]> = {};
    for (let b = 0; b < buildings.length; b++) {
      const rooms: ClassroomInfo[] = [];
      const roomCount: number = 6 + b * 2;
      for (let r = 0; r < roomCount; r++) {
        const floor: number = (r % 4) + 1;
        const roomNo: string = floor.toString() + '0' + (r + 1).toString();
        rooms.push({
          id: buildings[b] + '-' + roomNo,
          floorid: floor.toString(),
          name: prefix + buildings[b] + ' ' + roomNo,
          kxsds: MockData.freePattern(b * 7 + r)
        });
      }
      list[buildings[b]] = rooms;
    }
    return { e: 0, m: 'ok', d: { list: list } };
  }

  /** 生成看起来合理的空闲节次组合。 */
  private static freePattern(seed: number): string {
    const candidates: string[] = [
      '1,2', '3,4', '5,6', '7,8', '9,10', '1,2,3,4', '5,6,7,8', '3,4,5', '', '1,2,5,6'
    ];
    return candidates[seed % candidates.length];
  }

  /* ============================ 版本 ============================ */

  static version(): string {
    return '{"hasUpdate":false,"latestVersion":"0.1.0","forceUpdate":false}';
  }
}
