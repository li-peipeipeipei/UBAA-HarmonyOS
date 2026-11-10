import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { GlobalContext } from '../common/GlobalContext';
import { WeeklySchedule, Week, Term } from '../model/ApiTypes';

/**
 * 课表本地缓存（离线优先）。
 *
 * ## 解决什么问题
 *
 * 原来课表页是「纯在线」的：`aboutToAppear` → 拉学期 → 拉周次 → 拉课表，
 * 三步全在网络上。任何一步失败（没网、校园网断了、上游抽风），
 * 用户看到的都是一张错误页 —— **明明上次的课表还在本地，却什么都看不到**。
 *
 * 现在改成**先渲染本地、后台静默刷新**：
 * 1. `restoreFromCache()` 同步读本地缓存，**立刻**把表头/网格/课程块填上；
 * 2. 再发网络请求，成功则覆盖并写回缓存；失败则保持本地内容不动（只轻提示）。
 *
 * 结果就是：断网进 App 一样能看到完整课表，有网时进 App 顺手更新一份。
 *
 * ## 为什么用 Preferences 而不是 RDB / 文件
 *
 * 数据量极小（一个学期 20 周 × 7 天 × 几节课，JSON 也就几十 KB），
 * 只要求「一次写入、整体读取」。Preferences 的同步读写正好合适，
 * 不用引入关系库和迁移。**按周分 key 存**是为了别让单条key 撑爆长度上限。
 *
 * ## 为什么同步读写
 *
 * 首屏要先渲染 —— 用异步读会变成「先空白 → 再闪一下内容」，
 * 与「打开就能看到课表」的目标背道而驰。同步读在 Preferences 上是毫秒级。
 */

const DOMAIN: number = 0x0100;
const TAG: string = 'ScheduleCache';

const STORE_NAME: string = 'ubaa_schedule_cache';

const KEY_TERMS: string = 'terms';
const KEY_WEEKS: string = 'weeks';
const KEY_TERM_CODE: string = 'term_code';
const KEY_TERM_NAME: string = 'term_name';
const KEY_CUR_WEEK: string = 'cur_week';
const KEY_WEEK_PREFIX: string = 'week_';
const KEY_SAVED_AT: string = 'saved_at';
/** 缓存所属账号（学号 / 登录名）：换账号后旧缓存必须整体作废。 */
const KEY_ACCOUNT: string = 'account';

export class ScheduleCache {
  private static pref: preferences.Preferences | null = null;
  /** 打开失败过就别再试了（每次读写都抛异常会拖慢页面）。 */
  private static failed: boolean = false;

  private static store(): preferences.Preferences | null {
    if (ScheduleCache.failed) {
      return null;
    }
    if (ScheduleCache.pref === null) {
      try {
        const ctx: common.UIAbilityContext = GlobalContext.getContext();
        ScheduleCache.pref = preferences.getPreferencesSync(ctx, { name: STORE_NAME });
      } catch (error) {
        ScheduleCache.failed = true;
        hilog.warn(DOMAIN, TAG, '打开课表缓存失败：%{public}s', (error as Error).message);
        return null;
      }
    }
    return ScheduleCache.pref;
  }

  /* ------------------------- 写入（联网成功后调用） ------------------------- */

  /** 存学期列表 + 当前学期的周次列表。 */
  static saveMeta(terms: Term[], weeks: Week[], termCode: string, termName: string, curWeek: number): void {
    const store = ScheduleCache.store();
    if (store === null) {
      return;
    }
    try {
      if (terms.length > 0) {
        store.putSync(KEY_TERMS, JSON.stringify(terms));
      }
      if (weeks.length > 0) {
        store.putSync(KEY_WEEKS, JSON.stringify(weeks));
      }
      store.putSync(KEY_TERM_CODE, termCode);
      store.putSync(KEY_TERM_NAME, termName);
      store.putSync(KEY_CUR_WEEK, curWeek);
      store.putSync(KEY_SAVED_AT, ScheduleCache.nowText());
      store.flush();
      hilog.info(DOMAIN, TAG, '已缓存课表元数据：%{public}s 第%{public}d周', termName, curWeek);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '缓存课表元数据失败：%{public}s', (error as Error).message);
    }
  }

  /** 记录这份缓存属于哪个账号。 */
  static saveAccount(account: string): void {
    ScheduleCache.put(KEY_ACCOUNT, account);
  }

  /** 读取缓存所属账号；老版本没有这个字段时返回空串。 */
  static loadAccount(): string {
    return ScheduleCache.text(KEY_ACCOUNT);
  }

  /**
   * 清空整份课表缓存（切换账号时调用）。
   *
   * 周课表是按「学期 + 周」分 key 存的，这里先按缓存的周次列表把每个 week key 删掉，
   * 再删元数据，避免上一个账号的课程留在下一个账号里。
   */
  static clearAll(): void {
    const store = ScheduleCache.store();
    if (store === null) {
      return;
    }
    try {
      const termCode = ScheduleCache.text(KEY_TERM_CODE);
      const weeks = ScheduleCache.loadWeeks();
      if (termCode.length > 0) {
        for (let i = 0; i < weeks.length; i++) {
          store.deleteSync(ScheduleCache.weekKey(termCode, weeks[i].serialNumber));
        }
      }
      store.deleteSync(KEY_TERMS);
      store.deleteSync(KEY_WEEKS);
      store.deleteSync(KEY_TERM_CODE);
      store.deleteSync(KEY_TERM_NAME);
      store.deleteSync(KEY_CUR_WEEK);
      store.deleteSync(KEY_SAVED_AT);
      store.deleteSync(KEY_ACCOUNT);
      store.flush();
      hilog.info(DOMAIN, TAG, '已清空课表缓存（账号切换）');
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '清空课表缓存失败：%{public}s', (error as Error).message);
    }
  }

  /** 存一周的课表。 */
  static saveWeek(termCode: string, week: number, data: WeeklySchedule): void {
    ScheduleCache.put(ScheduleCache.weekKey(termCode, week), JSON.stringify(data));
  }

  /**
   * 批量写入多周（**只 flush 一次**）。
   *
   * 预取整个学期时逐周调 `saveWeek` 会 flush 二十多次 —— 每次都是一次磁盘写，
   * 在主线程上明显卡顿。
   *
   * @param list `[周次, 课表数据]` 的扁平数组
   */
  static saveWeeks(termCode: string, list: WeeklySchedule[], weeks: number[]): void {
    const store = ScheduleCache.store();
    if (store === null || list.length === 0) {
      return;
    }
    try {
      for (let i = 0; i < list.length; i++) {
        store.putSync(ScheduleCache.weekKey(termCode, weeks[i]), JSON.stringify(list[i]));
      }
      store.putSync(KEY_SAVED_AT, ScheduleCache.nowText());
      store.flush();
      hilog.info(DOMAIN, TAG, '已缓存 %{public}d 周课表', list.length);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '批量缓存周课表失败：%{public}s', (error as Error).message);
    }
  }

  private static put(key: string, value: string): void {
    const store = ScheduleCache.store();
    if (store === null) {
      return;
    }
    try {
      store.putSync(key, value);
      store.putSync(KEY_SAVED_AT, ScheduleCache.nowText());
      store.flush();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '写入 %{public}s 失败：%{public}s', key, (error as Error).message);
    }
  }

  /* ------------------------- 读取（首屏同步调用） ------------------------- */

  /** 读学期列表；没有缓存时返回空数组。 */
  static loadTerms(): Term[] {
    const list = ScheduleCache.read<Term[]>(KEY_TERMS);
    return list === null ? [] : list;
  }

  /** 读周次列表；没有缓存时返回空数组。 */
  static loadWeeks(): Week[] {
    const list = ScheduleCache.read<Week[]>(KEY_WEEKS);
    return list === null ? [] : list;
  }

  /** 读某一周的课表；没缓存返回 null。 */
  static loadWeek(termCode: string, week: number): WeeklySchedule | null {
    return ScheduleCache.read<WeeklySchedule>(ScheduleCache.weekKey(termCode, week));
  }

  /** 缓存里记住的当前学期代码。 */
  static loadTermCode(): string {
    return ScheduleCache.text(KEY_TERM_CODE);
  }

  /** 缓存里记住的当前学期名。 */
  static loadTermName(): string {
    return ScheduleCache.text(KEY_TERM_NAME);
  }

  /** 缓存里记住的当前周（离线时仍知道「本周」是第几周）。 */
  static loadCurWeek(): number {
    const store = ScheduleCache.store();
    if (store === null) {
      return 0;
    }
    try {
      const raw = store.getSync(KEY_CUR_WEEK, 0);
      return typeof raw === 'number' ? raw : 0;
    } catch (error) {
      return 0;
    }
  }

  /** 上次缓存时间文案（给用户看数据新鲜度）。 */
  static savedAt(): string {
    return ScheduleCache.text(KEY_SAVED_AT);
  }

  /**
   * 挑一个**本地有缓存**的周次来显示。
   *
   * 优先给 `week`；那一周没缓存就退回第一周（离线时至少能显示点什么，
   * 总比一片空白好）。
   */
  static pickCachedWeek(termCode: string, week: number, weeks: Week[]): number {
    if (ScheduleCache.loadWeek(termCode, week) !== null) {
      return week;
    }
    for (let i = 0; i < weeks.length; i++) {
      if (ScheduleCache.loadWeek(termCode, weeks[i].serialNumber) !== null) {
        return weeks[i].serialNumber;
      }
    }
    return week;
  }

  /** 彻底清空（**切换账号 / 登出时必须调**，否则会把 A 的课表显示给 B）。 */
  static clear(): void {
    const store = ScheduleCache.store();
    if (store === null) {
      return;
    }
    try {
      store.clear();
      store.flush();
      hilog.info(DOMAIN, TAG, '已清空课表缓存');
    } catch (error) {
      hilog.warn(DOMAIN, TAG, '清空课表缓存失败：%{public}s', (error as Error).message);
    }
  }

  /* ------------------------- 内部 ------------------------- */

  private static weekKey(termCode: string, week: number): string {
    return KEY_WEEK_PREFIX + termCode + '_' + week.toString();
  }

  private static text(key: string): string {
    const store = ScheduleCache.store();
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

  private static read<T>(key: string): T | null {
    const store = ScheduleCache.store();
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
      hilog.warn(DOMAIN, TAG, '解析缓存 %{public}s 失败：%{public}s', key, (error as Error).message);
      return null;
    }
  }

  private static nowText(): string {
    const d: Date = new Date();
    return (d.getMonth() + 1).toString() + '月' + d.getDate().toString() + '日 ' +
      d.getHours().toString().padStart(2, '0') + ':' + d.getMinutes().toString().padStart(2, '0');
  }
}