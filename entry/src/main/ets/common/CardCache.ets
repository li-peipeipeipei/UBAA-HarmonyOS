import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';

/**
 * 桌面服务卡片的数据缓存（**跨进程共享**）。
 *
 * ## 为什么需要它
 *
 * 卡片提供方（FormExtensionAbility）与主应用（UIAbility）是**两个独立进程**：
 * 「两个进程之间内存隔离，但是共享相同的文件沙箱」（官方《ArkTS卡片进程模型》）。
 * 所以内存里的东西（AppStorage、静态变量、Cookie 罐）**卡片一律读不到**，
 * 只有落进沙箱的文件（Preferences / RDB / 文件）才能两边共用。
 *
 * ## 为什么不能在卡片里现拉数据
 *
 * 官方明写：「FormExtensionAbility 进程不能常驻后台……在生命周期调度完成后会继续存在
 * 10 秒，若在 10 秒内未收到新的生命周期回调，则进程将自动退出」，并且
 * 「建议拉起主应用进行处理，处理完成后使用 updateForm 通知卡片进行刷新」。
 * 教务系统接口要走 CAS 登录 + Cookie 跳转 + 解密，基本必然超过这个窗口。
 *
 * 所以采用官方推荐的姿势：
 * **主应用拉数据 → 写进这里 → updateForm 推给卡片；卡片只读缓存，不联网。**
 *
 * ## 为什么用 getApplicationContext()
 *
 * `preferences.getPreferences(context, name)` 里传 UIAbilityContext 或
 * FormExtensionContext 都能拿到同一份沙箱，但用 **application 级 context**
 * 更明确 —— 两个进程里 `getApplicationContext()` 指向同一个沙箱根目录。
 */

/** 偏好存储名（两端必须完全一致，否则读不到同一份数据）。 */
const CARD_STORE: string = 'ubaa_card_cache';

/** 已加桌的卡片实例 id 列表（JSON 数组字符串）。 */
const KEY_FORM_IDS: string = 'card_form_ids';

/** 课表数据（JSON 字符串，主应用写入、卡片读取）。 */
const KEY_SCHEDULE: string = 'card_schedule';

/** 数据更新时间（展示在卡片上，让用户知道数据新鲜度）。 */
const KEY_UPDATED_AT: string = 'card_updated_at';

/** 今天的星期（1~7），主应用写入。 */
const KEY_TODAY: string = 'card_today';

/** 今天有几节课、下一节是什么等「今日摘要」。 */
const KEY_TODAY_SUMMARY: string = 'card_today_summary';

/* ---- 学业三件套（考试 / 成绩 / 空闲教室）各自的快照 ---- */

const KEY_EXAM: string = 'card_exam';
const KEY_GRADE: string = 'card_grade';
const KEY_CLASSROOM: string = 'card_classroom';
const KEY_WEEK_VIEW: string = 'card_week_view';
const KEY_DAY_VIEW: string = 'card_day_view';

const DOMAIN: number = 0x0100;
const TAG: string = 'CardCache';

function logInfo(msg: string): void {
  hilog.info(DOMAIN, TAG, '%{public}s', msg);
}

function logWarn(msg: string): void {
  hilog.warn(DOMAIN, TAG, '%{public}s', msg);
}

/**
 * 一条课（推给卡片的数据结构）。
 *
 * ⚠️ 卡片侧 `@LocalStorageProp` 收到的值**一律是 string**，所以真正传的是
 * `JSON.stringify([...])`，这里只是主进程侧的组装结构。
 */
export interface CardCourse {
  /** 节次文案，如 `1-2节` */
  section: string;
  /** 时间文案，如 `08:00~09:35` */
  time: string;
  courseName: string;
  place: string;
  /**
   * 星期文案（`明天` / `周三`），**只用于「下一节课」跨天时**。
   * 可选字段 —— 旧缓存里没有它，卡片侧要能兼容 undefined。
   */
  when?: string;
}

/** 今天概览。 */
export interface CardToday {
  /** 例如 `第6周 · 10月15日 周三` */
  headline: string;
  /** 例如 `今天 3 节课 · 下一节 08:00 高等数学` */
  summary: string;
  courses: CardCourse[];
  /**
   * **下一节课**（今天已结束的课不算），没有则为 null。
   *
   * 由主应用算好再推给卡片 —— 卡片那边不自己判断「现在几点」，
   * 免得宿主进程与 FRS 渲染进程的时间不一致导致显示错。
   *
   * ⚠️ **不限于今天** —— 今天没课时（比如周末），它会指向明天/本周后面某天的
   * 第一节课，卡片据此显示「今天没课，下一节是…」，把空白变成有用信息。
   */
  next: CardCourse | null;
  /** 「下一节课」是哪天的日期文案，如 `明天 08:00` / `周三 08:00`；今天则为 `今天 08:00`。 */
  nextWhen: string;
  /** 是否已登录（false 时卡片提示「打开 App 登录后显示课表」） */
  ready: boolean;
}

/**
 * 考试卡片数据（1×2）。
 *
 * 只放**最近一场**考试 —— 卡片只有一条窄屏，塞不下更多；
 * 要看全部得点进 App。
 */
export interface CardExam {
  /** 例如 `还剩 3 天`，今天就是 `今天` */
  countdown: string;
  /** 例如 `10月20日` */
  dateText: string;
  /** 例如 `09:00~11:00`，没有就空串 */
  timeText: string;
  courseName: string;
  /** 例如 `J3-101 · 座位 12` */
  placeText: string;
  ready: boolean;
}

/** 成绩卡片数据（1×2）。 */
export interface CardGrade {
  /** 例如 `2025-2026学年秋季学期` */
  termName: string;
  /** 例如 `3.72`，没有成绩时为 `—` */
  gpa: string;
  /** 例如 `已修 18.5 学分` */
  credit: string;
  /** 例如 `最高分：高等数学A 96` */
  bestText: string;
  ready: boolean;
}

/** 空闲教室卡片数据（1×2）。 */
export interface CardClassroom {
  /** 例如 `今天 · 10月15日` */
  dateText: string;
  /** 例如 `J3-101` */
  roomText: string;
  /** 例如 `空闲 3 间 · 主楼 J3` */
  summary: string;
  ready: boolean;
}

/* ----周课表卡 / 日课表卡（4×4 / 6×4 / 2×4）---- */

/** 一节课（周/日课表卡用，比 CardCourse 多了星期与节次区间）。 */
export interface CardSlot {
  /** 1~7（周一~周日） */
  day: number;
  /** 起始节次 */
  begin: number;
  /** 结束节次 */
  end: number;
  /** `08:00~09:35` */
  time: string;
  courseName: string;
  place: string;
  /** 上游给的颜色（`#RRGGBB`），卡片用它画课程块底色 */
  color: string;
}

/** 周课表卡数据。 */
export interface CardWeekView {
  /** 例如 `2026秋季课表` */
  termName: string;
  /** 例如 `第6周` */
  weekLabel: string;
  /** 星期表头下的日期，如 `10/05`（索引 0=周一）。 */
  dates: string[];
  /** 一周的全部课程（周一~周日）。 */
  slots: CardSlot[];
  /** 节次数（网格行数）。 */
  sections: number;
  /** 每个节次的起止时间，索引 = 节次-1；两行显示（起 / 止）。 */
  times: string[];
  /** 星期几是今天（1~7），0 表示没有（比如数据是历史周次）。 */
  today: number;
  /** 本学期总周数（卡片的左右箭头用它做边界判断）。 */
  totalWeeks: number;
  ready: boolean;
}

/** 日课表卡数据。 */
export interface CardDayView {
  /** 例如 `今天 · 周三 · 10/15` */
  headline: string;
  /** 星期几（1~7） */
  day: number;
  /** 当天全部课程，按节次升序。 */
  slots: CardSlot[];
  /** 当天节次总数（画网格行数用；上游没给就按最后一节课推）。 */
  sections: number;
  /** 每个节次的起止时间，索引 = 节次-1（下标越界按空串处理）。 */
  times: string[];
  /**
   * 分组标题：`今天` / `明天` / `周三`。
   *
   * **今天没课时会自动指向最近有课的那天**（官方卡片就是这么做的 ——
   * 空白卡没有信息量，「下一节课」才是用户要的），标题随之变化。
   */
  dayLabel: string;
  /** `dayLabel` 那天一共有几节课（官方在标题后跟一个数字）。 */
  dayCount: number;
  ready: boolean;
}

export class CardCache {
  /**
   * 打开共享存储。
   *
   * @param context UIAbilityContext 或 FormExtensionContext 都行 —— 取它的
   *               application context，两进程指向同一份沙箱。
   */
  private static store(context: common.Context): preferences.Preferences | null {
    try {
      const appCtx = context.getApplicationContext();
      return preferences.getPreferencesSync(appCtx, { name: CARD_STORE });
    } catch (error) {
      logWarn('打开卡片缓存失败：' + (error as Error).message);
      return null;
    }
  }

  /* ------------------------- 主应用写入 ------------------------- */

  /** 写今天概览 + 课表快照（主应用每次拉完课表调用）。 */
  static saveToday(context: common.Context, today: CardToday, weekLabel: string): void {
    const store = CardCache.store(context);
    if (store === null) {
      return;
    }
    try {
      store.putSync(KEY_SCHEDULE, JSON.stringify(today));
      store.putSync(KEY_TODAY, weekLabel);
      store.putSync(KEY_UPDATED_AT, CardCache.nowText());
      store.putSync(KEY_TODAY_SUMMARY, today.summary);
      store.flush();
      logInfo('已写入课表缓存：' + today.summary);
    } catch (error) {
      logWarn('写入课表缓存失败：' + (error as Error).message);
    }
  }

  /** 写最近一场考试（ExamPage 拉完后调用）。 */
  static saveExam(context: common.Context, exam: CardExam): void {
    CardCache.save(context, KEY_EXAM, exam, '考试');
  }

  /** 写成绩概览（GradePage 拉完后调用）。 */
  static saveGrade(context: common.Context, grade: CardGrade): void {
    CardCache.save(context, KEY_GRADE, grade, '成绩');
  }

  /** 写空闲教室（ClassroomPage 查询成功后调用）。 */
  static saveClassroom(context: common.Context, room: CardClassroom): void {
    CardCache.save(context, KEY_CLASSROOM, room, '空闲教室');
  }

  /** 写周课表卡数据（一整周七天）。 */
  static saveWeekView(context: common.Context, view: CardWeekView): void {
    CardCache.save(context, KEY_WEEK_VIEW, view, '周课表');
  }

  /** 写日课表卡数据（某一天全天）。 */
  static saveDayView(context: common.Context, view: CardDayView): void {
    CardCache.save(context, KEY_DAY_VIEW, view, '日课表');
  }

  /**
   * 三个功能卡共用的写入口。
   *
   * 统一在这里 `put + flush`：写完要落盘，卡片进程（另一个进程）才读得到 ——
   * 只 put 不 flush的话，另一个进程可能还在读旧值。
   */
  private static save(context: common.Context, key: string, value: Object, name: string): void {
    const store = CardCache.store(context);
    if (store === null) {
      return;
    }
    try {
      store.putSync(key, JSON.stringify(value));
      store.flush();
      logInfo('已写入' + name + '卡片缓存');
    } catch (error) {
      logWarn('写入' + name + '卡片缓存失败：' + (error as Error).message);
    }
  }

  /** 记下这张卡片，之后主应用可以主动推数据给它。 */
  static addFormId(context: common.Context, formId: string): void {
    const ids = CardCache.getFormIds(context);
    if (ids.indexOf(formId) >= 0) {
      return;
    }
    ids.push(formId);
    const store = CardCache.store(context);
    if (store === null) {
      return;
    }
    try {
      store.putSync(KEY_FORM_IDS, JSON.stringify(ids));
      store.flush();
      logInfo('记录卡片实例：' + formId + '，当前共 ' + ids.length + ' 张');
    } catch (error) {
      logWarn('记录卡片实例失败：' + (error as Error).message);
    }
  }

  /** 卡片被移除时清掉。 */
  static removeFormId(context: common.Context, formId: string): void {
    const ids = CardCache.getFormIds(context);
    const next: string[] = [];
    for (let i = 0; i < ids.length; i++) {
      if (ids[i] !== formId) {
        next.push(ids[i]);
      }
    }
    const store = CardCache.store(context);
    if (store === null) {
      return;
    }
    try {
      store.putSync(KEY_FORM_IDS, JSON.stringify(next));
      store.flush();
      logInfo('移除卡片实例：' + formId);
    } catch (error) {
      logWarn('移除卡片实例失败：' + (error as Error).message);
    }
  }

  /* ------------------------- 卡片读取 ------------------------- */

  /** 全部已加桌卡片 id。 */
  static getFormIds(context: common.Context): string[] {
    const store = CardCache.store(context);
    if (store === null) {
      return [];
    }
    try {
      const raw = store.getSync(KEY_FORM_IDS, '[]');
      if (typeof raw !== 'string') {
        return [];
      }
      return JSON.parse(raw) as string[];
    } catch (error) {
      logWarn('读取卡片实例列表失败：' + (error as Error).message);
      return [];
    }
  }

  /** 读今天概览；没有缓存时返回 null。 */
  static loadToday(context: common.Context): CardToday | null {
    const store = CardCache.store(context);
    if (store === null) {
      return null;
    }
    try {
      const raw = store.getSync(KEY_SCHEDULE, '');
      if (typeof raw !== 'string' || raw.length === 0) {
        return null;
      }
      return JSON.parse(raw) as CardToday;
    } catch (error) {
      logWarn('解析课表缓存失败：' + (error as Error).message);
      return null;
    }
  }

  /** 数据更新时间文案（没有就返回空串）。 */
  static updatedAt(context: common.Context): string {
    return CardCache.text(context, KEY_UPDATED_AT);
  }

  private static text(context: common.Context, key: string): string {
    const store = CardCache.store(context);
    if (store === null) {
      return '';
    }
    try {
      const raw = store.getSync(key, '');
      return typeof raw === 'string' ? raw : '';
    } catch (error) {
      return '';
    }
  }

  /** 当前教学周文案。 */
  static weekLabel(context: common.Context): string {
    return CardCache.text(context, KEY_TODAY);
  }

  /* ------------------------- 三件套读取 ------------------------- */

  /** 最近一场考试；没有缓存时返回 null。 */
  static loadExam(context: common.Context): CardExam | null {
    return CardCache.read<CardExam>(context, KEY_EXAM);
  }

  /** 成绩概览；没有缓存时返回 null。 */
  static loadGrade(context: common.Context): CardGrade | null {
    return CardCache.read<CardGrade>(context, KEY_GRADE);
  }

  /** 空闲教室；没有缓存时返回 null。 */
  static loadClassroom(context: common.Context): CardClassroom | null {
    return CardCache.read<CardClassroom>(context, KEY_CLASSROOM);
  }

  /** 周课表卡；没有缓存时返回 null。 */
  static loadWeekView(context: common.Context): CardWeekView | null {
    return CardCache.read<CardWeekView>(context, KEY_WEEK_VIEW);
  }

  /** 日课表卡；没有缓存时返回 null。 */
  static loadDayView(context: common.Context): CardDayView | null {
    return CardCache.read<CardDayView>(context, KEY_DAY_VIEW);
  }

  /**
   * 读一个 JSON 缓存。
   *
   * 用泛型而不是三个各写一遍：卡片侧的 ArkTS 接口必须显式声明类型，
   * 这里只做反序列化，出错就当「没有缓存」，让卡片显示空态而不是崩。
   */
  private static read<T>(context: common.Context, key: string): T | null {
    const store = CardCache.store(context);
    if (store === null) {
      return null;
    }
    try {
      const raw = store.getSync(key, '');
      if (typeof raw !== 'string' || raw.length === 0) {
        return null;
      }
      return JSON.parse(raw) as T;
    } catch (error) {
      logWarn('解析卡片缓存失败：' + (error as Error).message);
      return null;
    }
  }

  private static nowText(): string {
    const d: Date = new Date();
    return (d.getMonth() + 1).toString() + '月' + d.getDate().toString() + '日 ' +
      d.getHours().toString().padStart(2, '0') + ':' + d.getMinutes().toString().padStart(2, '0');
  }
}