
/**
 * 路由表。
 *
 * 说明：4 个一级页签各自持有一个 NavPathStack（见 MainPage），
 * 二级页面在当前页签栈内跳转，底部悬浮页签栏保持可见（与主流原生 App 一致）。
 */
export class RouteName {
  static readonly EXAM: string = 'exam';
  static readonly GRADE: string = 'grade';
  static readonly CLASSROOM: string = 'classroom';
  static readonly SIGNIN: string = 'signin';
  /** iHome（接诉即办）。 */
  static readonly IHOME: string = 'ihome';
  /** iHome 诉求详情。 */
  static readonly IHOME_DETAIL: string = 'ihomeDetail';
  /** 希冀作业（列表）。 */
  static readonly JUDGE: string = 'judge';
  /** 希冀作业详情。 */
  static readonly JUDGE_DETAIL: string = 'judgeDetail';
  /** 自动评教（一键评教）。 */
  static readonly EVALUATION: string = 'evaluation';
  static readonly SPOC: string = 'spoc';
  static readonly YGDK: string = 'ygdk';
  static readonly BYKC: string = 'bykc';
  /** 图书馆座位首页。 */
  static readonly LIBBOOK_HOME: string = 'libbookHome';
  /** 图书馆座位：预约座位。 */
  static readonly LIBBOOK_RESERVE: string = 'libbookReserve';
  /** 图书馆座位：我的座位预约。 */
  static readonly LIBBOOK_BOOKINGS: string = 'libbookBookings';
  /** 博雅子页：选择课程（列表 + 筛选）。 */
  static readonly BYKC_COURSES: string = 'bykcCourses';
  /** 博雅子页：我的课程。 */
  static readonly BYKC_CHOSEN: string = 'bykcChosen';
  /** 博雅子页：课程统计。 */
  static readonly BYKC_STATISTICS: string = 'bykcStatistics';
  /** 博雅子页：课程详情。 */
  static readonly BYKC_DETAIL: string = 'bykcDetail';
  static readonly USER_INFO: string = 'userInfo';
  static readonly SETTINGS: string = 'settings';
  static readonly ABOUT: string = 'about';
}

/** 宽屏 Split 右栏栈空时压入的占位路由（只由 MainPage 在 lg / xxl 档使用）。 */
export const WIDE_PLACEHOLDER_ROUTE: string = 'widePlaceholder';

export class AppRouter {
  static push(stack: NavPathStack, name: string, param?: object): void {
    if (param === undefined) {
      stack.pushPath({ name: name });
    } else {
      stack.pushPath({ name: name, param: param });
    }
  }

  static back(stack: NavPathStack): void {
    stack.pop();
  }
}

/** 加载状态机，页面统一用它驱动 加载中 / 内容 / 错误 / 空 四态。 */
export enum LoadState {
  LOADING = 0,
  SUCCESS = 1,
  ERROR = 2
}
