import { LoadState } from '../common/AppRouter';
import { DateUtil } from '../common/DateUtil';
import { Logger } from '../common/Logger';
import { Toast } from '../common/Toast';
import curves from '@ohos.curves';
import { ApiError } from '../network/ApiError';
import { ApiService } from '../network/ApiService';
import { TokenStore } from '../network/TokenStore';
import { AppColor, AppFont, AppMaterial, AppSize } from '../components/AppTheme';
import { MaterialCardLayer } from '../components/MaterialCardLayer';
import { immersiveMaterialActive } from '../common/SystemMaterial';
import { topSafeInsetVp } from '../common/ImmersiveUtil';
import { EmptyView, ErrorView, LoadingView } from '../components/CommonViews';
import { ScheduleHeaderModel } from '../components/ScheduleHeader';
import { buildCourseDetail, CourseDetailDialog, CourseDetail } from '../components/CourseDetailDialog';
import { MultiCourseDialog } from '../components/MultiCourseDialog';
import { CardCache, CardCourse, CardDayView, CardSlot, CardToday, CardWeekView } from '../common/CardCache';
import { ScheduleCache } from '../network/ScheduleCache';
import { GlobalContext } from '../common/GlobalContext';
import { CourseClass, SectionTime, Term, Week, WeeklySchedule } from '../model/ApiTypes';

/** 一门课参与「是否变化」比较的字段（不含颜色等纯展示字段）。 */
function courseSignature(c: CourseClass): string {
  const begin = c.beginSection === undefined ? 0 : c.beginSection;
  const end = c.endSection === undefined ? 0 : c.endSection;
  const day = c.dayOfWeek === undefined ? 0 : c.dayOfWeek;
  return [
    c.courseCode, c.courseName, begin.toString(), end.toString(), day.toString(),
    c.placeName === undefined ? '' : c.placeName,
    c.weeksAndTeachers === undefined ? '' : c.weeksAndTeachers,
    c.beginTime === undefined ? '' : c.beginTime,
    c.endTime === undefined ? '' : c.endTime,
    c.courseSerialNo === undefined ? '' : c.courseSerialNo,
    c.credit === undefined ? '' : c.credit
  ].join('|');
}

/**
 * 两份周课表是否「内容一致」。
 *
 * 只比较真正影响显示的字段：课程集合（排序后逐门比）+ 周名 / 周代码。
 * 一致时调用方不再写状态、不再写缓存，界面就不会闪。
 */
function sameWeeklySchedule(a: WeeklySchedule, b: WeeklySchedule): boolean {
  if (a === b) {
    return true;
  }
  const left = a.arrangedList === undefined ? [] : a.arrangedList;
  const right = b.arrangedList === undefined ? [] : b.arrangedList;
  if (left.length !== right.length) {
    return false;
  }
  if ((a.code === undefined ? '' : a.code) !== (b.code === undefined ? '' : b.code)) {
    return false;
  }
  if ((a.name === undefined ? '' : a.name) !== (b.name === undefined ? '' : b.name)) {
    return false;
  }
  const leftSigs: string[] = [];
  for (let i = 0; i < left.length; i++) {
    leftSigs.push(courseSignature(left[i]));
  }
  const rightSigs: string[] = [];
  for (let i = 0; i < right.length; i++) {
    rightSigs.push(courseSignature(right[i]));
  }
  leftSigs.sort();
  rightSigs.sort();
  return leftSigs.join('\n') === rightSigs.join('\n');
}


/**
 * 「松手后回弹到位」的动画曲线（系统内置）。
 *
 * ## 为什么原来的 EaseOut 不对
 *
 * ArkUI 的 Swiper **默认就是弹簧曲线**（`interpolatingSpring`）—— 是这里显式写了
 * `.curve(Curve.EaseOut)` + `.duration(280)`，把系统自带的非线性回弹压成了
 * 「固定 280ms 的匀减速」：甩出去「咔」一下停住，没有苹果那种甩出去再荡回来的惯性。
 *
 * ## 三种可选（全是系统内置，换一行即可）
 *
 * - `curves.responsiveSpringMotion(response, dampingFraction)` —— **iOS 风格**（当前用的）：
 *   回弹时长随**松手时的速度**自适应 —— 甩得快就收得快、慢慢拖就慢慢滑到位。
 * - `curves.springMotion(response, dampingFraction)` —— Material 风格固定参数弹簧：
 *   response = 一次完整振荡的时长（秒），dampingFraction 0 = 一直弹 / 1 = 临界阻尼（不超调）。
 * - `Curve.FastOutSlowIn` —— 系统标准减速曲线 cubic-bezier(0.4, 0, 0.2, 1)，无超调，最「稳」。
 *
 * ## 参数怎么定的（真机试出来的）
 *
 * - `response`：**0.15（系统默认）→ 0.26 → 0.38**。默认那个归位太快，一甩就「咔」一下到位；
 *   0.26 还是偏快，0.38 才够「滑过去再稳下来」（约 1/0.15 ≈ 2.5 倍于系统默认），
 *   手感接近旧版 EaseOut 的 280ms 观感，但多了一段自然的收尾。
 * - `dampingFraction`：**0.86 → 0.88 → 0.90**。回弹幅度逐步收一点，别弹得过头。
 *
 * ⚠️ **弹簧曲线不受 `.duration()` 控制**（时长由曲线参数自己决定），
 * 所以 Swiper 上的 `.duration(280)` 只在换回 `Curve.*` 时才生效。
 */

/** 惰性单例：既不模块级求值，也避免每次 render 新建曲线对象、打断正在跑的动画。 */
let settleCurve: curves.ICurve | undefined = undefined;

function swipeSettleCurve(): curves.ICurve {
  if (settleCurve === undefined) {
    settleCurve = curves.responsiveSpringMotion(0.38, 0.90);
  }
  return settleCurve;
}

/**
 * 「周日下午几点之后默认显示下一周」。
 *
 * 周日本来就没课，下午 3 点是「这周上完了、开始想下周」的典型时刻 ——
 * 继续显示已经过完的这周没意义。
 */
const SUNDAY_ROLL_OVER_HOUR: number = 15;

const SECTION_CELL_HEIGHT: number = 56;

/**
 * 左侧「节次」列的宽度（vp）。
 *
 * 尽量窄 —— 这一列只放 1~2 位数字，省下的宽度全部让给七天列，课程条就更宽。
 * 配合下面的 GRID_SIDE_PADDING（比全局 pagePadding 小）一起腾空间。
 */
const SCHEDULE_COLUMN_WIDTH: number = 24;

/**
 * 课表网格的左右外边距（vp）。
 *
 * 比 `AppSize.pagePadding`(16) 小 —— 课表是「信息密度优先」的页面，两侧各收 8vp
 * 可以多出 16vp 给七天列，课程条宽度提升明显。表头与网格共用这个值，不会错列。
 */
const GRID_SIDE_PADDING: number = 8;

const HEADER_HEIGHT: number = 44;

/**
 * 课程块里教室名最多显示几行（上限）。
 *
 * 教室名长短差别很大（「J3-101」一行就够，「大学生活动中心羽毛球场」要三四行），
 * 所以按块高动态给行数：**至少给课程名留 2 行**，其余高度全让给教室名。
 * 真实布局里课程名带 `layoutWeight(1)`，教室按自然高度占位，所以教室优先、
 * 课程名不够时先被收成省略号 —— 见 courseBlock。
 */
const PLACE_MAX_LINES_CAP: number = 5;

const COURSE_PALETTE: string[] = [
  '#1976D2', '#7B5EA7', '#2E9E6B', '#C77800', '#C2185B', '#00838F'
];

/**
 * 课表一列里的一个「冲突簇」。
 *
 * 节次区间相交的几门课归为一簇（同一天不可能真的同时上两门）。
 * 簇内**只有一门**就照常画课程块；有**多门**就合成一块「N节课 / 查看」，
 * 点开才选具体哪门 —— 与官方课表的处理方式一致。
 */
interface ScheduleCluster {
  /** 簇内最早的开始节次（1 基）。 */
  begin: number;
  /** 簇跨越的节数。 */
  height: number;
  /** 簇内课程，按开始节次升序。 */
  courses: CourseClass[];
  /** ForEach 的 key —— **必须带数据身份 + 周次**，见 `dayClusters` 里的注释。 */
  key: string;
}

function makeCluster(begin: number, height: number, courses: CourseClass[], key: string): ScheduleCluster {
  const cluster: ScheduleCluster = { begin: begin, height: height, courses: courses, key: key };
  return cluster;
}

/* ---------------------- 「选择学期」列表的可见性 ---------------------- */

/** 单个字符是否 0-9。 */
function isDigit(ch: string): boolean {
  return ch >= '0' && ch <= '9';
}

/**
 * 取字符串里**最后一个**四位年份：`2026秋季` → 2026、`2025-2026学年春季学期` → 2026。
 *
 * 取最后一个，是为了让「学年」写法里的春季 / 夏季落到正确的公历年份上
 * （2025-2026 学年的春季学期其实是 2026 年 2 月）。找不到返回 0。
 */
function lastYearIn(text: string): number {
  let year: number = 0;
  for (let i = 0; i + 4 <= text.length; i++) {
    if (isDigit(text.charAt(i)) && isDigit(text.charAt(i + 1)) &&
      isDigit(text.charAt(i + 2)) && isDigit(text.charAt(i + 3))) {
      const value: number = (text.charCodeAt(i) - 48) * 1000 + (text.charCodeAt(i + 1) - 48) * 100 +
        (text.charCodeAt(i + 2) - 48) * 10 + (text.charCodeAt(i + 3) - 48);
      if (value >= 2000 && value <= 2100) {
        year = value;
      }
    }
  }
  return year;
}

/** 季节字 → 学期起始月份（0 基，取当月 1 号）。认不出返回 -1。 */
function seasonStartMonth(text: string): number {
  if (text.indexOf('春') >= 0) {
    return 1;    // 2 月
  }
  if (text.indexOf('夏') >= 0) {
    return 5;    // 6 月
  }
  if (text.indexOf('秋') >= 0) {
    return 7;    // 8 月
  }
  if (text.indexOf('冬') >= 0) {
    return 11;   // 12 月
  }
  return -1;
}

/**
 * 课表页。
 *
 * 数据链路：学期列表 → 教学周列表 → 指定周课表。
 * 网格采用「背景网格 + 绝对定位课程块」的画法：
 * 课程跨多节次时只需调整 y 与高度，避免复杂嵌套布局。
 */
/**
 * Swiper 的周次数据源（配合 LazyForEach）。
 *
 * 冷启动点开课表时，ForEach 会一次性创建 19 个 weekPage（每个都是一整套
 * 表头 + 7 列网格 + 课程块），真机实测首帧要 350ms，就是那一下卡顿。
 * 换成 LazyForEach 后只创建「当前页 + cachedCount 个邻页」，实测首帧降到 57ms。
 */
class WeekDataSource implements IDataSource {
  private items: Week[] = [];
  private listeners: DataChangeListener[] = [];

  totalCount(): number {
    return this.items.length;
  }

  getData(index: number): Week {
    return this.items[index];
  }

  registerDataChangeListener(listener: DataChangeListener): void {
    if (this.listeners.indexOf(listener) < 0) {
      this.listeners.push(listener);
    }
  }

  unregisterDataChangeListener(listener: DataChangeListener): void {
    const index = this.listeners.indexOf(listener);
    if (index >= 0) {
      this.listeners.splice(index, 1);
    }
  }

  setItems(items: Week[]): void {
    this.items = items;
    for (let i = 0; i < this.listeners.length; i++) {
      this.listeners[i].onDataReloaded();
    }
  }
}

/** 学期选择弹窗（@CustomDialog：尺寸/设计对齐课程详情弹窗）。 */
@CustomDialog
struct TermDialog {
  controller?: CustomDialogController;
  terms: Term[] = [];
  currentCode: string = '';
  onPick: (term: Term) => void = () => {
  };
  private readonly materialActive: boolean = immersiveMaterialActive();

  build() {
    Stack() {
      if (this.materialActive) {
        MaterialCardLayer({ layerRadius: AppSize.cardRadiusLarge })
      }

      Column() {
        Row() {
          Text('选择学期')
            .fontSize(AppFont.title)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColor.textPrimary)
            .maxLines(1)

          Stack() {
            if (this.materialActive) {
              MaterialCardLayer({ layerRadius: 20, layerShadow: false })
            } else {
              Column()
                .width('100%')
                .height('100%')
                .borderRadius(20)
                .backgroundColor(AppColor.circleButtonSurface)
            }
            Button({ type: ButtonType.Normal, stateEffect: false }) {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(24)
                .fontColor([AppColor.textPrimary])
            }
            .width(40)
            .height(40)
            .borderRadius(20)
            .backgroundColor(Color.Transparent)
            .onClick(() => {
              if (this.controller !== undefined) {
                this.controller.close();
              }
            })
          }
          .width(40)
          .height(40)
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .alignItems(VerticalAlign.Center)
        .margin({ bottom: 8 })

        Divider()
          .color(AppColor.divider)
          .strokeWidth(0.5)

        Scroll() {
          Column({ space: 6 }) {
            ForEach(this.terms, (item: Term) => {
              Row() {
                Text(item.itemName)
                  .fontSize(AppFont.body)
                  .fontColor(AppColor.textPrimary)
                  .layoutWeight(1)
                if (item.itemCode === this.currentCode) {
                  SymbolGlyph($r('sys.symbol.checkmark'))
                    .fontSize(18)
                    .fontColor([AppColor.brand])
                }
              }
              .width('100%')
              .height(44)
              .padding({ left: 12, right: 12 })
              .borderRadius(AppSize.cardRadius)
              .backgroundColor(item.itemCode === this.currentCode ? AppColor.brandContainerGlass : Color.Transparent)
              .onClick(() => {
                this.onPick(item);
                if (this.controller !== undefined) {
                  this.controller.close();
                }
              })
            }, (item: Term) => item.itemCode)
          }
          .width('100%')
          .padding({ top: 8 })
        }
        .width('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .constraintSize({ maxHeight: 380 })
        .margin({ top: 4 })

        Stack() {
          if (this.materialActive) {
            MaterialCardLayer({ layerRadius: 22, layerShadow: false })
          }
          Button('完成')
            .width('100%')
            .height(44)
            .fontSize(AppFont.subtitle)
            .fontColor(AppColor.textOnBrand)
            .backgroundColor(this.materialActive ? AppColor.brandGlass : AppColor.brand)
            .onClick(() => {
              if (this.controller !== undefined) {
                this.controller.close();
              }
            })
        }
        .width('100%')
        .height(44)
        .borderRadius(22)
        .margin({ top: 16 })
      }
      .width('100%')
      .padding(AppSize.cardPadding + 4)
      .alignItems(HorizontalAlign.Start)
    }
    .width('86%')
    .constraintSize({ maxWidth: 400 })
    .borderRadius(AppSize.cardRadiusLarge)
    .backgroundColor(this.materialActive ? Color.Transparent : AppColor.glassSurface)
    .backdropBlur(this.materialActive ? 0 : AppMaterial.blurLarge)
  }
}

@Component
export struct SchedulePage {
  stack: NavPathStack = new NavPathStack();

  /**
   * 顶部「学期 / 周次」选择器的共享状态 —— 与 MainPage 持有的是**同一个实例**
   * （构造时由 MainPage 传入，见 MainPage 的 SchedulePage({ header: ... })）。
   *
   * 那些选择器渲染在悬浮标题栏里（MainPage.scheduleTitleBar），本页只负责
   * 往里写数据、挂回调，不再自己画。
   */
  header: ScheduleHeaderModel = new ScheduleHeaderModel();


  @State private loadState: LoadState = LoadState.LOADING;
  @State private errorMessage: string = '';

  @State private terms: Term[] = [];
  @State private weeks: Week[] = [];
  /** 周次列表的 LazyForEach 数据源（与 weeks 同步）。 */
  private weekData: WeekDataSource = new WeekDataSource();
  @State private schedule: WeeklySchedule = { arrangedList: [], code: '', name: '', sectionTimes: [] };

  @State private termCode: string = '';
  @State private currentWeek: number = 1;
  @State private showTermSheet: boolean = false;
  /** 学期选择弹窗（CustomDialog，和课程详情同一套尺寸/动效）。 */
  private termDialogController: CustomDialogController | null = null;
  @State private sectionCount: number = 12;
  /**
   * 切换周次时是否正在拉新数据。
   *
   * 只用于给网格加一点「变淡」的反馈 —— 切周**不能**切整页加载态，否则顶部日期、
   * 左侧节次会跟着一起闪一下（用户反馈「整个页面黑一下」）。
   */
  @State private weekLoading: boolean = false;
  /**
   * 预加载的**全部周**课表，下标 = 教学周序号（1 基）。`null`/未定义 = 这一周还没拉到。
   *
   * 进页面就后台把本学期所有周一次性拉好，Swiper 里每页直接读它 ——
   * 切周时不需要联网、不需要转加载态，像翻照片一样立刻显示
   * （用户要求「提前把所有课表全加载出来、直接滑动图片一样直接显示」）。
   */
  @State private weekSchedules: WeeklySchedule[] = [];
  /** 某周拉取失败且无本地缓存时置 true，该周页面显示错误占位。 */
  @State private weekErrors: boolean[] = [];
  /** 切周横滑的 Swiper 控制器：点周次条时用它做带动画的跳页。 */
  private swiperController: SwiperController = new SwiperController();
  /** 切周请求序号：快速连点周次时丢弃过期响应，避免旧数据盖新数据。 */
  private weekRequestId: number = 0;

  /**
   * 当前界面上的课表**是不是本地缓存**渲染出来的。
   *
   * 决定两件事：
   * 1. 进页面时要不要转加载态（已有本地内容就别转，否则首屏白闪一下）；
   * 2. 网络失败时是「保留内容轻提示」还是「换成错误页」。
   *
   * 网络成功拿到数据后立刻置 false —— 此后每次切周都直接走网络。
   */
  private fromCache: boolean = false;

  /**
   * 本地数据的更新时间（离线显示时让用户知道数据新鲜度）。
   * 空串表示还没缓存过。
   */
  private cachedAt: string = '';

  /** 点击课程块后展示的课程详情（@Observed 实例，弹窗用 @ObjectLink 订阅）。 */
  @State private courseDetail: CourseDetail = new CourseDetail();
  private detailController: CustomDialogController | null = null;

  /**
   * 沉浸材质是否可用（API ≥ 26、应用级没被 DISABLE、材质构造成功）。
   *
   * 学期选择半模态的三处底板都靠它切换：**面板底板 / 每个选项块 / 关闭按钮圆底**。
   * 不可用时走各自原来的「半透明玻璃底 + 半模态自带背景模糊」兜底。
   */
  private readonly materialActive: boolean = immersiveMaterialActive();

  /**
   * 该学期是否已经「到点」—— 用来隐藏还没开始的**未来学期**。
   *
   * 上游的学期列表是往后一路排的（现在 2026 秋，列表里就已经带着 2027 春 / 2027 夏），
   * 全列出来会让人误以为可以切到还没到的学期。学期名形如 `2026秋季`（也兼容
   * `2025-2026学年春季学期`），取最后一个四位年份 + 季节字推算起始月份
   * （春 2 / 夏 6 / 秋 8 / 冬 12，取当月 1 号），起始时间未到就隐藏。
   * 名称认不出来时**不隐藏** —— 宁可多显示，也不要让用户找不到自己的学期。
   */
  private termStarted(item: Term, nowMs: number): boolean {
    const year: number = lastYearIn(item.itemName);
    const month: number = seasonStartMonth(item.itemName);
    if (year === 0 || month < 0) {
      return true;
    }
    return new Date(year, month, 1).getTime() <= nowMs;
  }

  /** 学期面板里实际显示的学期：**已到点的全部**（含历次有课的学期）+ 当前选中的那个。 */
  private visibleTerms(): Term[] {
    const nowMs: number = new Date().getTime();
    const out: Term[] = [];
    for (let i = 0; i < this.terms.length; i++) {
      const item: Term = this.terms[i];
      if (item.itemCode === this.termCode || this.termStarted(item, nowMs)) {
        out.push(item);
      }
    }
    return out;
  }

  aboutToDisappear(): void {
    // 宽屏断点切换可能销毁本页，清掉残留跟手位移（不动翻页阈值与手势逻辑）
    this.dragOffsetX = 0;
  }

  aboutToAppear(): void {
    // 记录首屏加载时刻：抑制「点开页签立刻再刷一次」的重复请求（见 refreshNow）
    this.lastLoadAt = Date.now();
    // 标题栏里的两个选择器不能直接调本页方法，把回调挂到共享模型上。
    this.header.onOpenTerm = () => {
      this.openTermDialog();
    };
    this.header.onSelectWeek = (week: number) => {
      if (week !== this.currentWeek) {
        this.gotoWeek(week); // 手动点周次条：带动画跳过去
      }
    };
    // 标题栏右上角「回本周」（仅当当前不在本周时出现）
    this.header.onBackToCurrentWeek = () => {
      this.goCurrentWeek();
    };
    // 页签切走再切回时**不再**自动刷新：按产品要求，只有下拉刷新 / 换账号才联网比对
    this.header.onRefresh = () => {
    };
    // **缓存优先**：有本地缓存就直接渲染，不再发任何网络请求；
    // 只有「没缓存」或「登录账号变了」才走联网加载
    const restored: boolean = this.restoreFromCache();
    if (!restored) {
      this.needFullRefresh = true;
      this.loadTerms();
    }
  }

  /**
   * App 每次回到前台都会翻转这个值（EntryAbility.onForeground 里写）。
   *
   * 「每次打开刷新一下」的第二条通路 —— 页签内切走再切回靠 `header.onRefresh`，
   * 而 App 整体从后台恢复（用户根本没离开 App，只是锁屏/切了别的应用）靠这个。
   */
  @StorageLink('appForegroundTick') @Watch('onForegroundTick') foregroundTick: boolean = false;

  private onForegroundTick(): void {
    // 按产品要求：回到前台不再自动刷新，直接沿用本地缓存
  }

  /**
   * 页面重新可见时（从别的页签切回来 / App 从后台恢复）刷新当前周。
   *
   * 「每次打开刷新一下」靠这个。⚠️ **不是靠 `onPageShow`** ——
   * 实测在 HdsTabs 的页签切换下 `onPageShow` **不触发**（切走再切回，
   * 上游请求 0 次），因为页签内容常驻、页面可见性回调不跟着页签走。
   *
   * 两条通路（缺一不可）：
   * - **页签内切走再切回** → 父组件 MainPage 在 `HdsTabs.onChange` 里调
  `scheduleHeader.onRefresh()`（SchedulePage 在 aboutToAppear 里注册）；
   * - **App 整体从后台恢复** → `appForegroundTick` 翻转（`EntryAbility.onForeground` 写）。
   *
   * 刻意**不重拉学期/周次**（那两步慢且极少变动），只刷当前这一周的课表 ——
   * 课表变动（学校临时调课之类）基本都体现在周内。
   */
  refreshNow(): void {
    if (this.termCode.length === 0) {
      return; // 首屏还在加载中，交给 loadTerms
    }
    // 刚点开页签时 aboutToAppear 的加载/预取已经在跑，别再叠一次重复请求
    if (Date.now() - this.lastLoadAt < 5000) {
      return;
    }
    // 静默刷新当前周（其余周已是预加载好的，不用逐个刷）
    this.reloadWeek(this.currentWeek);
  }

  /* ------------------------- 数据加载 ------------------------- */

  /**
   * **离线优先**的第一步：同步读本地缓存并立刻渲染。
   *
   * 只做「已经有缓存」的情况 —— 没有缓存就什么都不做（走下面的联网加载，
   * 让用户看到加载态而不是一个空的表头）。
   *
   * 返回是否成功渲染了本地数据：调用方据此决定失败时是「静默」还是「报错」。
   */
  /** 当前登录账号的学号（优先本地会话，退 JWT 会话）。 */
  private currentSchoolId(): string {
    const local = TokenStore.getLocalSession();
    if (local !== null && local.schoolId.length > 0) {
      return local.schoolId.trim();
    }
    return TokenStore.getSession().schoolId.trim();
  }

  /** 当前登录账号的登录名。 */
  private currentUsername(): string {
    const local = TokenStore.getLocalSession();
    if (local !== null && local.username.length > 0) {
      return local.username.trim();
    }
    return TokenStore.getSession().username.trim();
  }

  /**
   * 账号标识：学号 + 登录名。
   *
   * 只存登录名不行 —— 有的登录方式（WebVPN / 会话恢复）只有学号；
   * 只存学号也不行 —— 老缓存里存的是登录名。这里俩都存，比对时任一对得上就算同一人。
   */
  private currentAccountKey(): string {
    return this.currentSchoolId() + '|' + this.currentUsername();
  }

  /**
   * 缓存里的账号与当前账号是否一致。
   *
   * - 学号都有 → 只比学号（最权威）；
   * - 有一边学号缺失 → 退化为比登录名；
   * - 老缓存（没有 '|' 分隔）→ 直接和学号 / 登录名任一对上即可；
   * - 缓存里没有账号信息（老版本）→ 视为一致并补写，避免无谓地清缓存重拉。
   */
  private isSameCachedAccount(cached: string): boolean {
    if (cached.length === 0) {
      return true;
    }
    const sid = this.currentSchoolId();
    const user = this.currentUsername();
    if (cached.indexOf('|') < 0) {
      return cached === sid || cached === user;
    }
    const parts: string[] = cached.split('|');
    const cachedSid = parts.length > 0 ? parts[0] : '';
    const cachedUser = parts.length > 1 ? parts[1] : '';
    if (sid.length > 0 && cachedSid.length > 0) {
      return sid === cachedSid;
    }
    if (user.length > 0 && cachedUser.length > 0) {
      return user === cachedUser;
    }
    return true;
  }

  private restoreFromCache(): boolean {
    try {
      // 换账号：旧缓存不可复用，整体作废，走联网加载（这就是「账号变化才比对」）
      const account: string = this.currentAccountKey();
      const cachedAccount: string = ScheduleCache.loadAccount();
      if (!this.isSameCachedAccount(cachedAccount)) {
        Logger.info('课表缓存属于其他账号（' + cachedAccount + ' ≠ ' + account + '），清空后重新拉取');
        ScheduleCache.clearAll();
        return false;
      }
      if (cachedAccount.length === 0) {
        // 老缓存没有账号字段：认作同一账号并补写，别让用户白重拉一次
        ScheduleCache.saveAccount(account);
      }
      const termCode: string = ScheduleCache.loadTermCode();
      if (termCode.length === 0) {
        return false;
      }
      const terms: Term[] = ScheduleCache.loadTerms();
      const weeks: Week[] = ScheduleCache.loadWeeks();
      if (weeks.length === 0) {
        return false;
      }
      // 用缓存里的学期信息 + 周次列表搭出完整界面
      this.termCode = termCode;
      this.header.termName = ScheduleCache.loadTermName();
      this.terms = terms;
      this.applyWeeks(weeks);

      const cachedCur: number = ScheduleCache.loadCurWeek();
      let target: number = this.pickStartWeek(weeks, cachedCur);
      let data: WeeklySchedule | null = ScheduleCache.loadWeek(termCode, target);
      if (data === null) {
        // 目标周没缓存（换过周 / 换过学期）→ 退回「任意一个已缓存的周」，
        // 至少让离线时能看到课表，而不是只剩标题栏。
        for (let i = 0; i < weeks.length; i++) {
          const n: number = weeks[i].serialNumber;
          const cached: WeeklySchedule | null = ScheduleCache.loadWeek(termCode, n);
          if (cached !== null) {
            target = n;
            data = cached;
            break;
          }
        }
      }
      if (data === null) {
        return false;
      }
      this.applySchedule(data, target);
      // 初始化「全周预加载」容器：至少把当前周放进去，Swiper 才有内容可显示；
      // 其余周在 prefetchAllWeeks 里补全（优先读本地缓存）
      let maxWeekC = 0;
      for (let i = 0; i < weeks.length; i++) {
        if (weeks[i].serialNumber > maxWeekC) {
          maxWeekC = weeks[i].serialNumber;
        }
      }
      const arrC: WeeklySchedule[] = new Array(maxWeekC + 1);
      arrC[target] = data;
      for (let i = 0; i < weeks.length; i++) {
        const n: number = weeks[i].serialNumber;
        if (arrC[n] === undefined || arrC[n] === null) {
          const cached: WeeklySchedule | null = ScheduleCache.loadWeek(termCode, n);
          if (cached !== null) {
            arrC[n] = cached;
          }
        }
      }
      this.weekSchedules = arrC;
      // 明确标记「这是本地数据」，网络回来之前别把它清掉
      this.fromCache = true;
      this.cachedAt = ScheduleCache.savedAt();
      this.loadState = LoadState.SUCCESS;
      Logger.info('已从本地缓存渲染课表：第' + target.toString() + '周（缓存于 ' + this.cachedAt + '）');
      // 注意：这里**不再**自动联网比对 —— 打开课表只显示本地缓存
      return true;
    } catch (error) {
      Logger.warn('读取本地课表缓存失败：' + (error as Error).message);
      return false;
    }
  }

  /**
   * 首屏要显示哪一周。
   *
   * 优先用户上次看的那周 → 本地缓存里的当前周 → 上游标的当前周 → 第 1 周。
   */
  /** 学期周次统一入口：同时更新页面状态、标题栏胶囊条与 LazyForEach 数据源。 */
  private applyWeeks(list: Week[]): void {
    let same = this.weeks.length === list.length;
    if (same) {
      for (let i = 0; i < list.length; i++) {
        if (this.weeks[i].serialNumber !== list[i].serialNumber ||
          this.weeks[i].curWeek !== list[i].curWeek ||
          this.weeks[i].name !== list[i].name) {
          same = false;
          break;
        }
      }
    }
    this.weeks = list;
    this.header.weeks = list;
    if (!same) {
      // 只在周次真的变化时才让 LazyForEach 重载，避免「缓存 → 网络」同一份数据白重绘
      this.weekData.setItems(list);
    }
  }

  private pickStartWeek(weeks: Week[], cachedCur: number): number {
    const remembered = TokenStore.getSelectedWeek();
    if (remembered > 0 && ScheduleCache.loadWeek(this.termCode, remembered) !== null) {
      return remembered;
    }
    if (cachedCur > 0 && ScheduleCache.loadWeek(this.termCode, cachedCur) !== null) {
      return cachedCur;
    }
    for (let i = 0; i < weeks.length; i++) {
      if (weeks[i].curWeek) {
        return weeks[i].serialNumber;
      }
    }
    return weeks.length > 0 ? weeks[0].serialNumber : 1;
  }

  /**
   * 把一份课表数据应用到界面（**联网与本地缓存共用这一条路径**）。
   *
   * 单独抽出来是为了保证「本地渲染出来的界面」与「联网渲染出来的」**逐像素一致** ——
   * 否则会出现断网时排版和联网时不一样这种诡异差异。
   */
  private applySchedule(data: WeeklySchedule, week: number): void {
    this.currentWeek = week;
    this.header.currentWeek = week;
    // 周次胶囊条跟着滚到这一周（否则滑到靠后的周次时，胶囊条上一颗都没高亮）
    this.header.onScrollWeekIntoView(week);
    this.schedule = data;
    if (data.sectionTimes.length > 0) {
      let maxSection = 0;
      for (let i = 0; i < data.sectionTimes.length; i++) {
        if (data.sectionTimes[i].section > maxSection) {
          maxSection = data.sectionTimes[i].section;
        }
      }
      this.sectionCount = maxSection > 0 ? maxSection : data.sectionTimes.length;
    }
  }

  /**
   * 「周日下午 3 点后显示下一周」规则。
   *
   * ## 为什么是这个时间点
   *
   * 学期里**周日是空的**（实验课/竞赛占用得多，本项目用户的周日也整天空着）。
   * 下午 3 点是「这周的课已经上完、用户开始想下周的安排」的典型时刻 ——
   * 继续显示已经过完的这一周没有意义，直接切到下周更有用。
   *
   * ## 什么时候才生效
   *
   * - **只在「用户没有手动选过周次」时生效**（`TokenStore.getSelectedWeek()` 为 0）。
   *   用户手动翻到某一周就是明确要看那一周，别自动把他拽走；
   * - 上游标 `curWeek` 的那一周（= 学校认定的当前教学周）为准，
   *   **加一之后不能超出学期范围**（最后一周的周日下午仍显示最后一周）。
   */
  private weekForNow(curWeek: number, weeks: Week[]): number {
    const now: Date = new Date();
    // 星期几：0=周日 … 6=周六（与 Date 的 getDay 一致）
    const day: number = now.getDay();
    if (day !== 0) {
      return curWeek; // 只有周日才可能切
    }
    // 周日 15:00 之后
    if (now.getHours() < SUNDAY_ROLL_OVER_HOUR) {
      return curWeek;
    }
    let maxWeek = 0;
    for (let i = 0; i < weeks.length; i++) {
      if (weeks[i].serialNumber > maxWeek) {
        maxWeek = weeks[i].serialNumber;
      }
    }
    const next: number = curWeek + 1;
    if (maxWeek > 0 && next > maxWeek) {
      return curWeek; // 已经是最后一周了
    }
    Logger.info('周日下午 ' + SUNDAY_ROLL_OVER_HOUR.toString() +
      ' 点后，默认显示下一周（第 ' + next.toString() + ' 周）');
    return next;
  }

  /**
   * 记起来的周次，**但要排除「系统自动选的那一周」**。
   *
   * ## 为什么需要这一层过滤
   *
   * 早先版本 `selectWeek` 无条件写 `setSelectedWeek`，于是首屏算出的周次
   * （含自动规则的结果）也被当成「用户手动选的」记住了 ——
   * 之后 `getSelectedWeek() !== 0` → 自动规则**永久失效**，
   * 而且存量脏数据（用户根本没主动选过，只是跑过旧版本）也会挡住新规则。
   *
   * 判断方法：记起来的周次如果**恰好等于系统自己会算出的那一周**，
   * 就说明它不是用户的意思 → 当作「没记」。
   */
  private rememberedWeek(weeks: Week[], systemWeek: number): number {
    const remembered: number = TokenStore.getSelectedWeek();
    if (remembered <= 0) {
      return 0;
    }
    if (remembered === systemWeek || remembered === systemWeek - 1) {
      // 与系统算出来的一致（或正好差一 = 上一版自动规则的产物）→ 视为未记
      return 0;
    }
    return remembered;
  }

  /**
   * 周课表卡应该显示的周次。
   *
   * ## 规则
   *
   * 卡片默认跟着「首屏会落到的那一周」走 ——
   * 也就是 `weekForNow(当前教学周, weeks)`：周日下午 3 点后是下一周，其余时间是本周。
   * 用户手动选过周次时**不干预**（他在 App 里看到的是他自己选的那一周）。
   *
   * 之所以要单独算：卡片是**桌面常驻**的，用户不一定先打开 App ——
   * 万一周日下午看桌面，卡片还挂着已经过完的那一周，没意义。
   */
  private cardWeek(): number {
    // 卡片该显示哪一周：先按规则算，再让「用户手动选过的」覆盖它
    const shown: number = this.weekForNow(this.currentWeek, this.weeks);
    const remembered: number = this.rememberedWeek(this.weeks, shown);
    return remembered > 0 ? remembered : shown;
  }

  private async loadTerms(): Promise<void> {
    // 只有「本地啥也没有」才转加载态；已经有本地数据就保持界面不闪
    if (!this.fromCache) {
      this.loadState = LoadState.LOADING;
    }
    try {
      const list: Term[] = await ApiService.fetchTerms();
      this.terms = list;
      if (list.length === 0) {
        this.loadState = LoadState.SUCCESS;
        return;
      }
      let picked: Term = list[0];
      const remembered = TokenStore.getSelectedTerm();
      for (let i = 0; i < list.length; i++) {
        if (list[i].selected) {
          picked = list[i];
          break;
        }
        if (remembered[0].length > 0 && list[i].itemCode === remembered[0]) {
          picked = list[i];
        }
      }

      this.applyTerm(picked);
      await this.loadWeeks(picked.itemCode);
    } catch (error) {
      // 断网时**保留本地渲染出来的课表**，只轻提示 —— 这是离线优先的核心
      if (this.fromCache) {
        Logger.warn('离线：用本地课表继续显示（' + (error as Error).message + '）');
        Toast.show('当前无网络，显示本地课表' + (this.cachedAt.length > 0 ? '（' + this.cachedAt + '）' : ''));
        return;
      }
      this.errorMessage = error instanceof ApiError ?
        (error as ApiError).friendlyMessage() : '课表加载失败';
      this.loadState = LoadState.ERROR;
      Logger.error('学期列表加载失败：' + (error as Error).message);
    }
  }

  private async loadWeeks(termCode: string): Promise<void> {
    try {
      const list: Week[] = await ApiService.fetchWeeks(termCode);
      // ⚠️ 必须走 applyWeeks：它同时把列表交给 Swiper 的 LazyForEach 数据源。
      // 之前这里直接写 this.weeks / header.weeks，漏了 weekData —— 一旦本地缓存路径
      // 没命中（换学期、清缓存），Swiper 的数据源还是空的，页面就只剩标题栏和
      // 周次胶囊、下面一片黑。
      this.applyWeeks(list);
      let systemWeek = 1;
      for (let i = 0; i < list.length; i++) {
        if (list[i].curWeek) {
          systemWeek = list[i].serialNumber;
          break;
        }
      }
      // 系统该显示哪一周（周日下午 15:00 后是下一周）
      systemWeek = this.weekForNow(systemWeek, list);
      // 用户手动选过的那一周（过滤掉系统自动选出来的脏数据）
      const remembered: number = this.rememberedWeek(list, systemWeek);
      const week: number = remembered > 0 ? remembered : systemWeek;
      // 元数据先落缓存（即使下面的课表拉失败，也有周次条可用）
      let curWeek = 0;
      for (let i = 0; i < list.length; i++) {
        if (list[i].curWeek) {
          curWeek = list[i].serialNumber;
          break;
        }
      }
      ScheduleCache.saveMeta(this.terms, list, termCode, this.header.termName, curWeek);
      ScheduleCache.saveAccount(this.currentAccountKey());
      // 全周预加载：先把当前周（优先本地缓存）放进去让页面立刻有内容，
      // 再从后台把本学期所有周的课表补齐 —— 切周时直接显示、像翻照片一样跟手。
      // 不 await：绝不能拖慢用户看到当前周的时间。
      this.initWeekSchedules(termCode, list, week);
      if (this.needFullRefresh) {
        this.needFullRefresh = false;
        this.schedulePrefetch(termCode, list);
      }
    } catch (error) {
      // 周次都拉不到：本地有缓存就继续用本地界面，别把用户已看到的内容换成错误页
      if (this.fromCache) {
        Logger.warn('离线：周次列表也拉不到，继续显示本地课表');
        return;
      }
      this.errorMessage = error instanceof ApiError ?
        (error as ApiError).friendlyMessage() : '教学周加载失败';
      this.loadState = LoadState.ERROR;
    }
  }

  /**
   * 后台预取**整个学期**的课表，写进 `weekSchedules` 预加载容器 + 落本地缓存。
   *
   * ## 为什么要预加载全部周
   *
   * 用户要求「提前把所有课表全加载出来、像滑动图片一样直接显示」—— 所以每个教学周
   * 的课表都提前拉好，Swiper 里每页直接读 `weekSchedules[week]`，切周时**零等待**。
   *
   * ## 为什么不 await
   *
   * 二十几周 × 一次上游请求，全串行要好几秒。用户在等的是**当前这一周**，
   * 学期预取是锦上添花 —— 一律放后台，失败就失败（缓存里已有的周照样能用）。
   *
   * ## 跳过已拉到的周
   *
   * 已放进 `weekSchedules` 的周直接跳过（`initWeekSchedules` 已把本地缓存那几周填进去了），
   * 避免重复联网；只有既不在内存、本地也没缓存的周才真正发请求。
   */
  /** 是否已有一轮预取在跑（两条入口会同时触发，必须去重）。 */
  private prefetching: boolean = false;
  /** 上次首屏数据加载时间：用来抑制「点开页签立刻再刷一次」的重复请求。 */
  private lastLoadAt: number = 0;
  /**
   * 正在进行的「点周次条跳周」的目标周（-1 = 没有）。
   *
   * changeIndex 带动画跨多周时会依次回调中间页的 onChange。若不过滤，
   * 标题栏高亮会跟着中间页来回跳（先 11 再 10 最后 12），看起来像闪。
   */
  private gotoTargetWeek: number = -1;

  /**
   * 把整学期预取**推迟到首帧之后**再启动。
   *
   * 冷启动点开课表时，页面构造 + Swiper 首帧 + 19 个网络请求如果挤在同一帧，
   * 就会出现肉眼可见的停顿。延后 400ms 让首帧先画完，再开始后台补数据。
   */
  private schedulePrefetch(termCode: string, weeks: Week[]): void {
    setTimeout(() => {
      this.prefetchAllWeeks(termCode, weeks);
    }, 400);
  }

  private async prefetchAllWeeks(termCode: string, weeks: Week[]): Promise<void> {
    if (this.prefetching) {
      return;
    }
    this.prefetching = true;
    try {
      let maxWeek = 0;
      for (let i = 0; i < weeks.length; i++) {
        if (weeks[i].serialNumber > maxWeek) {
          maxWeek = weeks[i].serialNumber;
        }
      }
      // 容器 / 错误表按 maxWeek+1 兜底扩容
      if (this.weekSchedules.length <= maxWeek) {
        const arr: WeeklySchedule[] = new Array(maxWeek + 1);
        for (let i = 0; i < this.weekSchedules.length; i++) {
          arr[i] = this.weekSchedules[i];
        }
        this.weekSchedules = arr;
      }
      if (this.weekErrors.length <= maxWeek) {
        const errs: boolean[] = new Array(maxWeek + 1);
        for (let i = 0; i < this.weekErrors.length; i++) {
          errs[i] = this.weekErrors[i];
        }
        this.weekErrors = errs;
      }
      if (weeks.length === 0) {
        return;
      }
      Logger.info('后台比对学期课表：' + weeks.length.toString() + ' 周');
      const changed: WeeklySchedule[] = [];
      const changedNums: number[] = [];
      // 待落盘的周（只存真正变化的）
      const fresh: WeeklySchedule[] = [];
      const freshNums: number[] = [];
      let dirty: number = 0;
      // 连续失败计数：弱网 / 断网时别把 19 周逐个等到超时
      let failStreak: number = 0;
      for (let i = 0; i < weeks.length; i++) {
        const n: number = weeks[i].serialNumber;
        const existing: WeeklySchedule | null =
          this.weekSchedules[n] === undefined || this.weekSchedules[n] === null
            ? null : this.weekSchedules[n];
        let fetched: WeeklySchedule | null = null;
        try {
          // 每次都联网取一份，再和本地比 —— 用户要求「登录后自动比对差异」
          fetched = await ApiService.fetchWeeklySchedule(termCode, n);
        } catch (error) {
          Logger.warn('比对第' + n.toString() + '周失败：' + (error as Error).message);
        }
        if (fetched === null) {
          failStreak++;
          // 拉不到：有本地就继续用本地；没有才标错误占位
          if (existing === null && this.weekErrors[n] !== true) {
            this.weekErrors[n] = true;
            dirty++;
          }
          if (failStreak >= 3) {
            Logger.warn('连续 3 周取数失败，停止本轮比对（弱网 / 断网）');
            break;
          }
          continue;
        }
        failStreak = 0;
        if (existing !== null && sameWeeklySchedule(existing, fetched)) {
          // 完全一致：不写状态、不写缓存、不重绘
          continue;
        }
        this.weekSchedules[n] = fetched;
        this.weekErrors[n] = false;
        changed.push(fetched);
        changedNums.push(n);
        fresh.push(fetched);
        freshNums.push(n);
        dirty++;
        if (!this.refreshInFlight && dirty % 3 === 0) {
          this.weekSchedules = this.weekSchedules.slice();
          this.weekErrors = this.weekErrors.slice();
          ScheduleCache.saveWeeks(termCode, fresh.splice(0, fresh.length),
            freshNums.splice(0, freshNums.length));
        }
      }
      if (dirty > 0) {
        this.weekSchedules = this.weekSchedules.slice();
        this.weekErrors = this.weekErrors.slice();
      }
      if (fresh.length > 0) {
        ScheduleCache.saveWeeks(termCode, fresh, freshNums);
      }
      if (changed.length === 0) {
        Logger.info('课表与本地一致，未改动界面 / 缓存');
        return;
      }
      Logger.info('课表有更新：' + changed.length.toString() + ' 周已刷新');
      // 当前周若被刷新，重新应用一次（其余页由 Swiper 自己读 weekSchedules）
      if (changedNums.indexOf(this.currentWeek) >= 0) {
        const cur = this.weekSchedules[this.currentWeek];
        if (cur !== undefined && cur !== null) {
          this.applySchedule(cur, this.currentWeek);
        }
      }
      // 卡片用**完整学期**（含未变化的周）重算一次
      const all: WeeklySchedule[] = [];
      const allNums: number[] = [];
      for (let i = 0; i < weeks.length; i++) {
        const n = weeks[i].serialNumber;
        const data = this.weekSchedules[n];
        if (data !== undefined && data !== null) {
          all.push(data);
          allNums.push(n);
        }
      }
      if (all.length > 0) {
        this.pushTermCards(termCode, all, allNums);
      }
    } catch (error) {
      Logger.warn('预取学期课表失败：' + (error as Error).message);
    } finally {
      this.prefetching = false;
    }
  }

  /**
   * 把「当前周」和「今天」两张卡的数据写进缓存。
   *
   * ## 为什么不在 `pushToCards` 里一起做
   *
   * `pushToCards` 每次切周都会跑，不能每次都重算整周 —— 而周课表卡要的是
   * **完整七天**（含课程块颜色、节次区间），跟「今天有几节课」是两套聚合。
   * 所以拆开：切周写「今日卡」，预取完写「周卡 + 日卡」。
   *
   * ## 数据来源优先用**本周**
   *
   * 用户可能停在历史周次上（周末翻看），这时该给周卡看**用户正在看的那一周** ——
   * 与他眼前的内容一致比「绝对正确的本周」更有用。
   */
  private pushTermCards(termCode: string, list: WeeklySchedule[], numbers: number[]): void {
    try {
      // 找出「当前周」那份（预取结果里 week==currentWeek 的）
            // 卡片要显示哪一周（周日下午 3 点后是下一周）
      const shown: number = this.cardWeek();
      let cur: WeeklySchedule | null = null;
      for (let i = 0; i < list.length; i++) {
        if (numbers[i] === shown) {
          cur = list[i];
          break;
        }
      }
      if (cur === null) {
        const cached: WeeklySchedule | null = ScheduleCache.loadWeek(termCode, shown);
        if (cached !== null) {
          cur = cached;
        }
      }
      if (cur === null) {
        return;
      }
      const ctx = GlobalContext.getContext();

      // ---- 周课表卡：一整周七天的全部课程（仿官方课表版式）----
      const weekSlots: CardSlot[] = this.toCardSlots(cur);
      let maxSection = 0;
      for (let i = 0; i < cur.sectionTimes.length; i++) {
        if (cur.sectionTimes[i].section > maxSection) {
          maxSection = cur.sectionTimes[i].section;
        }
      }
      for (let i = 0; i < weekSlots.length; i++) {
        if (weekSlots[i].end > maxSection) {
          maxSection = weekSlots[i].end;
        }
      }
      const today: number = DateUtil.currentWeekday();
      const weekView: CardWeekView = {
        termName: this.header.termName.length > 0 ? this.header.termName : '课表',
        weekLabel: '第 ' + shown.toString() + ' 周',
        dates: this.weekDates(),
        slots: weekSlots,
        sections: maxSection > 0 ? maxSection : 12,
        times: this.sectionTimes(cur),
        today: today,
        totalWeeks: this.weeks.length,
        ready: true
      };
      CardCache.saveWeekView(ctx, weekView);

      // ---- 日课表卡：今天（或当前周的今天）----
      const weekday: number = DateUtil.currentWeekday();
      this.pushDayCard(cur, weekday);
    } catch (error) {
      Logger.warn('写入周/日课表卡片失败：' + (error as Error).message);
    }
  }

  /** 把一周数据里所有课转成卡片用的扁平结构（按星期、节次升序）。 */
  private toCardSlots(data: WeeklySchedule): CardSlot[] {
    const out: CardSlot[] = [];
    for (let i = 0; i < data.arrangedList.length; i++) {
      const c: CourseClass = data.arrangedList[i];
      const begin: number = this.beginOf(c);
      const end: number = begin + this.spanOf(c) - 1;
      const beginTime: string = c.beginTime === undefined ? '' : c.beginTime;
      const endTime: string = c.endTime === undefined ? '' : c.endTime;
      out.push({
        day: c.dayOfWeek === undefined ? 1 : c.dayOfWeek,
        begin: begin,
        end: end,
        time: beginTime + (endTime.length > 0 ? (beginTime.length > 0 ? '~' + endTime : endTime) : ''),
        courseName: c.courseName,
        place: c.placeName === undefined ? '' : c.placeName,
        color: c.color === undefined ? '' : c.color
      });
    }
    // 排序：先星期、再节次（上游 arrangedList 不保证有序，卡片画网格必须有序）
    out.sort((a: CardSlot, b: CardSlot) => {
      if (a.day !== b.day) {
        return a.day - b.day;
      }
      return a.begin - b.begin;
    });
    return out;
  }

  /**
   * 本周七天的日期文案（`10/05`），供周课表卡表头用。
   *
   * 官方课表表头是「周一 / 10/05」两行，日期很有用 —— 一眼看出这周是哪几天。
   */
  private weekDates(): string[] {
    return this.weekDatesFor(this.currentWeek);
  }

  /**
 * 日课表卡的分组标题。
 *
 * 官方写法是「今天」/「明天」+ 节数 —— 今天没课就把最近有课那天顶上来，
 * 标题随之变成「明天」/「周三」，让用户一眼知道这是哪天的课。
 */
  private dayLabelFor(target: number, today: number): string {
    if (target === today) {
      return '今天';
    }
    const nextDay: number = (today % 7) + 1;
    if (target === nextDay) {
      return '明天';
    }
    return DateUtil.weekdayNames()[target - 1];
  }

  /** 从一周数据里取出某天的课（保持已排序）。 */
  private slotsOfDayFor(data: WeeklySchedule, day: number): CardSlot[] {
    const all: CardSlot[] = this.toCardSlots(data);
    const out: CardSlot[] = [];
    for (let i = 0; i < all.length; i++) {
      if (all[i].day === day) {
        out.push(all[i]);
      }
    }
    return out;
  }

  /**
   * 节次时间表（索引 = 节次-1）。
   *
   * 卡片左列要显示**起止两行**，所以这里存成两行文本；
   * 上游某些节次只给了 `start` 没给 `end`（第 3/4/6 节就是这样），
   * 那时第二行留空 —— **绝不能拿 start 顶替 end**
   * （早先拼成了 `09:5009:50`、`14:0014:00` 这种重复时间，左列显示很乱）。
   */
  private sectionTimes(data: WeeklySchedule): string[] {
    const times: string[] = [];
    for (let i = 0; i < data.sectionTimes.length; i++) {
      const t: SectionTime = data.sectionTimes[i];
      const n: number = t.section;
      const begin: string = t.start === undefined ? '' : t.start;
      const end: string = t.end === undefined ? '' : t.end;
      while (times.length < n - 1) {
        times.push('');
      }
      times.push(begin + (end.length > 0 ? '~' + end : ''));
    }
    return times;
  }

  /**
   * 写日课表卡。
   *
   * **今天没课时会自动往后找最近有课的一天**（明天优先），并把分组标题写成
   * 「明天」/「周三」+ 那天的节数 —— 这是官方卡片的做法：
   * 空卡没有任何信息量，「下一节课」才是用户真正想知道的。
   */
  private pushDayCard(data: WeeklySchedule, weekday: number): void {
    const today: number = DateUtil.currentWeekday();
    // 先看今天；今天没课就往后找（最多找 7 天）
    let target: number = weekday;
    let slots: CardSlot[] = [];
    for (let step = 0; step <= 7; step++) {
      const day: number = ((weekday - 1 + step) % 7) + 1;
      const found: CardSlot[] = this.slotsOfDayFor(data, day);
      if (found.length > 0) {
        target = day;
        slots = found;
        break;
      }
    }
    // 节次时间表：索引 = 节次-1
    const times: string[] = this.sectionTimes(data);
    let maxSection = 0;
    for (let i = 0; i < data.sectionTimes.length; i++) {
      if (data.sectionTimes[i].section > maxSection) {
        maxSection = data.sectionTimes[i].section;
      }
    }
    for (let i = 0; i < slots.length; i++) {
      if (slots[i].end > maxSection) {
        maxSection = slots[i].end;
      }
    }
    const view: CardDayView = {
      headline: DateUtil.currentWeekday() === target ?
        ('今天 · ' + DateUtil.weekdayNames()[target - 1] + ' · ' + this.dayDate(target)) :
        (DateUtil.weekdayNames()[target - 1] + ' · ' + this.dayDate(target)),
      day: target,
      slots: slots,
      sections: maxSection > 0 ? maxSection : 12,
      times: times,
      // 分组标题：今天没课就写「明天」/「周三」，否则「今天」
      dayLabel: this.dayLabelFor(target, today),
      dayCount: slots.length,
      ready: true
    };
    CardCache.saveDayView(GlobalContext.getContext(), view);
  }

  /**
   * 静默刷新某一周的课表（联网 + 落缓存），并同步到 `weekSchedules` 预加载容器。
   *
   * 与旧 `selectWeek` 的区别：它**只更新数据、不切 Swiper 页、不转整页加载态** ——
   * 因为现在切周靠 Swiper（手指实时跟手），这一份只负责把「当前停的那一周」刷成最新。
   */
  private async reloadWeek(week: number): Promise<void> {
    const requestId: number = ++this.weekRequestId;
    this.weekLoading = true;
    try {
      const data: WeeklySchedule = await ApiService.fetchWeeklySchedule(this.termCode, week);
      if (requestId !== this.weekRequestId) {
        return; // 期间又切到别的周了，这次结果作废
      }
      // 写进预加载容器 —— 之后切到这一周直接显示，不再等网络
      this.weekSchedules[week] = data;
      this.weekSchedules = this.weekSchedules.slice();
      this.weekErrors[week] = false;
      this.weekErrors = this.weekErrors.slice();
      ScheduleCache.saveWeek(this.termCode, week, data);
      // 若当前正停在这一周，顺手同步给卡片 / 全局状态
      if (week === this.currentWeek) {
        this.applySchedule(data, week);
        this.pushToCards();
        this.pushTermCards(this.termCode, [data], [week]);
      }
      // 网络回来的这一刻才结束「本地模式」—— 之后的每一次切周都直接走网络
      this.fromCache = false;
      this.cachedAt = '';
    } catch (error) {
      if (requestId !== this.weekRequestId) {
        return;
      }
      const message = error instanceof ApiError ?
        (error as ApiError).friendlyMessage() : '课表加载失败';
      // 离线兜底：这周本地有缓存就直接显示
      const cached: WeeklySchedule | null = ScheduleCache.loadWeek(this.termCode, week);
      if (cached !== null) {
        this.weekSchedules[week] = cached;
        this.weekSchedules = this.weekSchedules.slice();
        if (week === this.currentWeek) {
          this.applySchedule(cached, week);
          this.pushToCards();
        }
        this.fromCache = true;
        this.cachedAt = ScheduleCache.savedAt();
        Logger.warn('离线：第' + week.toString() + '周用本地缓存');
        Toast.show('当前无网络，显示本地课表' + (this.cachedAt.length > 0 ? '（' + this.cachedAt + '）' : ''));
      } else {
        this.weekErrors[week] = true;
        this.weekErrors = this.weekErrors.slice();
        Logger.error('周课表加载失败：' + (error as Error).message);
      }
    } finally {
      if (requestId === this.weekRequestId) {
        this.weekLoading = false;
      }
    }
  }

  /**
   * 跳回当前教学周（标题栏右上角「回本周」按钮）。
   *
   * 「当前周」以教学周列表里的 `curWeek` 标记为准，不看本地记住的值。
   */
  private goCurrentWeek(): void {
    for (let i = 0; i < this.weeks.length; i++) {
      const item: Week = this.weeks[i];
      if (item.curWeek) {
        if (item.serialNumber !== this.currentWeek) {
          this.gotoWeek(item.serialNumber); // 带动画跳过去
        }
        return;
      }
    }
  }

  /**
   * 通过 Swiper 控制器带动画跳到指定周（点周次条 / 回本周用）。
   *
   * Swiper 滑到位后会回调 `onSwipeToWeek` 完成状态同步，所以这里只负责「动」，
   * 真正的「切数据 + 写记忆 + 刷卡片」都收敛在那一个入口。
   *
   * 边界处不越界（第 1 周再往前、最后一周再往后都无效）。
   */
  private gotoWeek(week: number): void {
    if (this.weeks.length === 0) {
      return;
    }
    let maxWeek = 0;
    for (let i = 0; i < this.weeks.length; i++) {
      if (this.weeks[i].serialNumber > maxWeek) {
        maxWeek = this.weeks[i].serialNumber;
      }
    }
    if (week < 1 || week > maxWeek || week === this.currentWeek) {
      return;
    }
    // 先把标题栏的高亮 / 胶囊条挪过去，再启动翻页动画。
    // 否则要等 Swiper 动画结束（onChange → onSwipeToWeek）才更新 currentWeek，
    // 蓝色选中态会比课表晚约 300ms 才动，看着就是“不同步”。
    this.gotoTargetWeek = week;
    this.header.currentWeek = week;
    this.header.onScrollWeekIntoView(week);
    this.swiperController.changeIndex(this.weekIndex(week), true);
    // 兜底：动画被手势打断 / 没回调时，别让这个标记卡住后续的翻页
    setTimeout(() => {
      if (this.gotoTargetWeek === week) {
        this.gotoTargetWeek = -1;
      }
    }, 900);
  }

  /**
   * Swiper 滑动（手指实时跟手）结束时回调：同步当前周、写记忆、刷卡片。
   *
   * 因为全周已预加载（`weekSchedules`），这里**不联网、不转加载态**，直接显示 ——
   * 像翻照片一样跟手。手指拖到哪一周、松手停在哪一页，就是哪一页。
   *
   * 滑动是用户的明确意图 → 按手动选周记下来（下次进页默认停在这一周）。
   */
  private onSwipeToWeek(week: number): void {
    if (week === this.currentWeek) {
      return; // 回弹到原周等无变化的情况，什么都不做
    }
    this.currentWeek = week;
    this.header.currentWeek = week;
    // 滑动切周 → 周次胶囊条跟着滚到这一周（跟手翻页时胶囊条也要跟得上）
    this.header.onScrollWeekIntoView(week);
    const data = this.scheduleFor(week);
    if (data !== null) {
      // 同步给卡片 / 全局状态（pushToCards 等读的是 this.schedule + this.currentWeek）
      this.applySchedule(data, week);
      this.pushToCards();
      this.pushTermCards(this.termCode, [data], [week]);
    }
    TokenStore.setSelectedWeek(week);
  }

  private applyTerm(term: Term): void {
    this.termCode = term.itemCode;
    // 学期名不再存在本页 —— 标题栏上的学期胶囊读的是共享模型
    this.header.termName = term.itemName;
    TokenStore.setSelectedTerm(term.itemCode, term.itemName);
  }

  /* ------------------------- 视图辅助 ------------------------- */

  private sections(): number[] {
    const list: number[] = [];
    for (let i = 1; i <= this.sectionCount; i++) {
      list.push(i);
    }
    return list;
  }

  private coursesOfDay(day: number): CourseClass[] {
    return this.coursesOfDayFor(day, this.schedule);
  }

  /** 节次区间是否相交。 */
  private sectionsOverlap(a: CourseClass, b: CourseClass): boolean {
    const aBegin: number = this.beginOf(a);
    const aEnd: number = aBegin + this.spanOf(a) - 1;
    const bBegin: number = this.beginOf(b);
    const bEnd: number = bBegin + this.spanOf(b) - 1;
    return bBegin <= aEnd && aBegin <= bEnd;
  }

  /** 是否与簇内**任一**课程相交（只比最后一个会漏判：`1-10` 长课 + `2-2` + `5-5`）。 */
  private overlapsCluster(cluster: CourseClass[], course: CourseClass): boolean {
    for (let i = 0; i < cluster.length; i++) {
      if (this.sectionsOverlap(cluster[i], course)) {
        return true;
      }
    }
    return false;
  }

  /**
   * 某一天的「冲突簇」：时间上重叠的课归为一簇，簇与簇之间不重叠。
   *
   * 从最早开始的课起贪心聚簇，簇范围取 `min(begin)..max(end)`。
   *
   * ⚠️ **簇的 key 必须带「数据身份 + 周次」**：
   * - 只用结构位置（`day-序号`）的话，切周后 key 完全不变，ArkUI 直接复用旧组件节点，
   *   而课程块拿到的是**普通对象**（不是 @State/@Observed），复用时文本不刷新 ——
   *   实测表现为「整格课程停在你第一次打开那周的内容」；
   * - 只带课程码不够：同一时段的两门**同名实验班**可能课程码、节次都一样，只有教室不同。
   * 所以这里拼上簇内每门课的「课程码+教室+起始节次」，再加上当前周次。
   */
  private dayClusters(day: number): ScheduleCluster[] {
    return this.dayClustersFor(day, this.schedule, this.currentWeek);
  }

  /** 「同时段 N 节课」选择弹窗的控制器（与课程详情弹窗分开，避免两层互相持有）。 */
  private multiController: CustomDialogController | null = null;

  /**
   * 把「今天」写进跨进程缓存，供桌面卡片读取。
   *
   * ## 为什么是「主应用写、卡片只读」
   *
   * 卡片提供方（FormExtensionAbility）与主应用是两个进程，内存隔离、只共享文件沙箱；
   * 而且官方明写该进程「在生命周期调度完成后会继续存在 10 秒」——
   * 教务系统那条 CAS 登录 + Cookie 跳转 + 解密的链路必然超时，
   * 所以卡片那边**绝不联网**，只读这里写好的快照。
   *
   * 「下一节课」在主应用这边判定：卡片渲染进程与主应用的时间可能差几秒，
   * 让卡片自己判断会出现「明明还有一节课却显示今天没课了」。
   *
   * 找「下一节」时会**往后跨天找**（今天没有就找明天、再找本周后面的课）——
   * 否则周末/无课日卡片是一片空白，什么信息都给不出。
   */
  private pushToCards(): void {
    try {
      const weekday: number = DateUtil.currentWeekday();
      const todayList: CourseClass[] = this.coursesOfDay(weekday);
      const courses: CardCourse[] = [];
      const nowText: string = this.nowClock();
      let next: CardCourse | null = null;
      for (let i = 0; i < todayList.length; i++) {
        const item: CardCourse = this.toCardCourse(todayList[i]);
        courses.push(item);
        // 「下一节」= 今天第一节**还没开始**的课
        if (next === null && item.time.length > 0 && item.time.localeCompare(nowText) > 0) {
          next = item;
        }
      }
      let nextWhen: string = '';
      if (next !== null) {
        nextWhen = '今天 ' + next.time;
      } else {
        // 今天没有「未开始」的课了 → 往后跨天找最近一节
        const found: CardCourse | null = this.findNextLaterCourse(weekday, nowText);
        if (found !== null) {
          next = found;
          nextWhen = found.when + ' ' + found.time;
        }
      }
      const headline: string = '第' + this.currentWeek.toString() + '周 · ' + this.dayDate(weekday);
      const summary: string = courses.length > 0 ?
        ('今天 ' + courses.length.toString() + ' 节课' +
          (next === null ? ' · 已全部结束' : ' · 下一节 ' + next.time + ' ' + next.courseName)) :
        (next === null ? '今天没有课' : '今天没有课 · 下一节 ' + nextWhen + ' ' + next.courseName);
      const snapshot: CardToday = {
        headline: headline,
        summary: summary,
        courses: courses,
        next: next,
        nextWhen: nextWhen,
        ready: true
      };
      CardCache.saveToday(GlobalContext.getContext(), snapshot, headline);
    } catch (error) {
      Logger.warn('写入桌面卡片缓存失败：' + (error as Error).message);
    }
  }

  /** 一门课 → 卡片用的扁平结构。 */
  private toCardCourse(c: CourseClass): CardCourse {
    const begin: number = this.beginOf(c);
    const end: number = begin + this.spanOf(c) - 1;
    const beginTime: string = c.beginTime === undefined ? '' : c.beginTime;
    const endTime: string = c.endTime === undefined ? '' : c.endTime;
    const item: CardCourse = {
      section: begin === end ? begin.toString() + '节' : begin.toString() + '-' + end.toString() + '节',
      time: beginTime + (endTime.length > 0 ? (beginTime.length > 0 ? '~' + endTime : endTime) : ''),
      courseName: c.courseName,
      place: c.placeName === undefined ? '' : c.placeName
    };
    return item;
  }

  /**
   * 从今天往后找最近的一节课（跨天）。
   *
   * 只看本周（1~7 天后），不做「下周」的推算 —— 本周没有就是真的没有，
   * 凭空猜下周一几节几是不负责任的。
   *
   * @returns 带 `when` 的课程；找不到返回 null。
   */
  private findNextLaterCourse(todayWeekday: number, nowText: string): CardCourse | null {
    const names: string[] = DateUtil.weekdayNames();
    for (let step = 0; step <= 7; step++) {
      // step=1 → 明天（weekday 7 的下一个是 1）
      const day: number = ((todayWeekday - 1 + step) % 7) + 1;
      const list: CourseClass[] = this.coursesOfDay(day);
      if (list.length === 0) {
        continue;
      }
      for (let i = 0; i < list.length; i++) {
        const item: CardCourse = this.toCardCourse(list[i]);
        // 今天要额外比时间（还没开始的才算），往后的天直接取最早那节
        if (item.time.length > 0 && (step > 0 || item.time.localeCompare(nowText) > 0)) {
          const withWhen: CardCourse = {
            section: item.section,
            time: item.time,
            courseName: item.courseName,
            place: item.place,
            when: step === 0 ? '今天' : (step === 1 ? '明天' : names[day - 1])
          };
          return withWhen;
        }
      }
    }
    return null;
  }

  /** 当前时刻 `HH:MM`（用于判断课程是否已开始）。 */
  private nowClock(): string {
    const d: Date = new Date();
    const h: string = d.getHours() < 10 ? '0' + d.getHours().toString() : d.getHours().toString();
    const m: string = d.getMinutes() < 10 ? '0' + d.getMinutes().toString() : d.getMinutes().toString();
    return h + ':' + m;
  }

  /**
   * 打开「同时段 N 节课」弹窗。
   *
   * 用户选中后本弹窗会先 `close()`，这里延迟 180ms 再开课程详情 ——
   * 连着 open 两个 CustomDialog 会互相顶掉，关掉一个另一个也跟着消失。
   */
  private openMultiCourse(cluster: ScheduleCluster): void {
    const list: CourseClass[] = cluster.courses.slice();
    this.multiController = new CustomDialogController({
      builder: MultiCourseDialog({
        courses: list,
        onPick: (course: CourseClass) => {
          setTimeout(() => {
            this.openCourseDetail(course);
          }, 180);
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      customStyle: true
    });
    if (this.multiController !== null) {
      this.multiController.open();
    }
  }

  /**
   * 课程块的取色：优先用上游给的色值，没有则按课程编号稳定散列到调色板。
   *
   * 返回**实色**（不透明），块边缘才清晰 —— 详见 courseBlock 的注释。
   */
  private courseColor(course: CourseClass): string {
    if (course.color !== undefined && course.color.length > 0) {
      return course.color;
    }
    let hash = 0;
    const key = course.courseCode.length > 0 ? course.courseCode : course.courseName;
    for (let i = 0; i < key.length; i++) {
      hash = (hash + key.charCodeAt(i)) % 9973;
    }
    return COURSE_PALETTE[hash % COURSE_PALETTE.length];
  }

  /**
   * 底色算不算浅色（按相对亮度）。
   *
   * 上游给的课程色是一整套**浅色系**（实测 `#FFF0CC` 淡黄、浅粉、浅蓝…），照着
   * 「白字」画会完全看不清；而内置兜底调色板又都是饱和深色。所以文字颜色不能按
   * 深浅色模式一刀切，只能按**块底色自己的明度**定 —— 浅底黑字、深底白字，
   * 两种模式、两种色源都成立。
   */
  private isLightColor(color: string): boolean {
    const hex = color.charAt(0) === '#' ? color.substring(1) : color;
    if (hex.length !== 6) {
      return false;
    }
    const r = parseInt(hex.substring(0, 2), 16);
    const g = parseInt(hex.substring(2, 4), 16);
    const b = parseInt(hex.substring(4, 6), 16);
    if (isNaN(r) || isNaN(g) || isNaN(b)) {
      return false;
    }
    return (0.299 * r + 0.587 * g + 0.114 * b) > 140;
  }

  /** 课程块主文字颜色：浅底黑字、深底白字。 */
  private courseTextColor(course: CourseClass): ResourceColor {
    return this.isLightColor(this.courseColor(course)) ? '#FF000000' : '#FFFFFFFF';
  }

  /** 课程块副文字（地点）颜色：主文字的柔和版本。 */
  private courseSubTextColor(course: CourseClass): ResourceColor {
    return this.isLightColor(this.courseColor(course)) ? '#B3000000' : '#E8FFFFFF';
  }

  /** 课程块描边色：浅底用淡黑、深底用淡白，让相邻 / 同色块的边界更清晰。 */
  private courseBorderColor(course: CourseClass): ResourceColor {
    return this.isLightColor(this.courseColor(course)) ? '#26000000' : '#33FFFFFF';
  }

  /** 点击课程块：组装详情并弹出。 */
  private openCourseDetail(course: CourseClass): void {
    const detail: CourseDetail = buildCourseDetail(course);
    // 原地更新（弹窗 @ObjectLink 订阅的是这个实例本身）
    this.courseDetail.apply(detail.title, detail.rows);
    this.detailController = new CustomDialogController({
      builder: CourseDetailDialog({ detail: this.courseDetail }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      customStyle: true
    });
    if (this.detailController !== null) {
      this.detailController.open();
    }
  }

  /* ------------------------- 预加载 / 按周取数（Swiper 每页独立渲染） ------------------------- */

  /**
   * 某一教学周在 `this.weeks` 数组里的**位置**（Swiper 页索引）。
   *
   * ⚠️ 不能假设 `serialNumber - 1 == 数组下标` —— 上游周次列表可能有缺口、也可能
   * 不是从 1 连续排到 N。Swiper 的页序严格按 `weeks` 数组顺序，所以索引必须按
   * 「找到 serialNumber 的那一项的位置」来算。找不到返回 0。
   */
  private weekIndex(week: number): number {
    for (let i = 0; i < this.weeks.length; i++) {
      if (this.weeks[i].serialNumber === week) {
        return i;
      }
    }
    return 0;
  }

  /** 取某一周已预加载的课表（下标 = 周序号，1 基）；没拉到返回 null。 */
  private scheduleFor(week: number): WeeklySchedule | null {
    if (week >= 0 && week < this.weekSchedules.length && this.weekSchedules[week] !== undefined) {
      return this.weekSchedules[week];
    }
    return null;
  }

  /** 某一周课表里的节次数（按该周自己的 sectionTimes 算，不同周可能不同）。 */
  private sectionCountFor(week: number): number {
    const data = this.scheduleFor(week);
    if (data === null) {
      return 12;
    }
    let maxSection = 0;
    for (let i = 0; i < data.sectionTimes.length; i++) {
      if (data.sectionTimes[i].section > maxSection) {
        maxSection = data.sectionTimes[i].section;
      }
    }
    return maxSection > 0 ? maxSection : (data.sectionTimes.length > 0 ? data.sectionTimes.length : 12);
  }

  /** 1..count 的节次数组（替代依赖全局 sectionCount 的 `sections()`，做到「按周独立」）。 */
  private sectionsOf(count: number): number[] {
    const list: number[] = [];
    for (let i = 1; i <= count; i++) {
      list.push(i);
    }
    return list;
  }

  private weekStartFor(week: number): Date | null {
    for (let i = 0; i < this.weeks.length; i++) {
      if (this.weeks[i].serialNumber === week) {
        return DateUtil.parse(this.weeks[i].startDate);
      }
    }
    return null;
  }

  private dayDateFor(day: number, week: number): string {
    const start = this.weekStartFor(week);
    if (start === null) {
      return '';
    }
    const date = DateUtil.addDays(start, day - 1);
    return DateUtil.pad(date.getMonth() + 1) + '/' + DateUtil.pad(date.getDate());
  }

  private weekDatesFor(week: number): string[] {
    const out: string[] = [];
    for (let day = 1; day <= 7; day++) {
      const text = this.dayDateFor(day, week);
      if (text.length >= 8) {
        out.push(text.substring(0, 5));
      } else {
        out.push(text);
      }
    }
    return out;
  }

  private coursesOfDayFor(day: number, data: WeeklySchedule): CourseClass[] {
    const result: CourseClass[] = [];
    for (let i = 0; i < data.arrangedList.length; i++) {
      const item = data.arrangedList[i];
      if (item.dayOfWeek === day) {
        result.push(item);
      }
    }
    return result;
  }

  /**
   * 某一天的「冲突簇」（与 `dayClusters` 同算法，但按传入的周课表 + 周次算 key）。
   *
   * ⚠️ 簇的 key 必须带「数据身份 + 周次」—— 否则切周后 ArkUI 复用旧节点、课程文本不刷新
   * （详见原 `dayClusters` 的注释）。
   */
  private dayClustersFor(day: number, data: WeeklySchedule, week: number): ScheduleCluster[] {
    const list: CourseClass[] = this.coursesOfDayFor(day, data).slice();
    list.sort((a: CourseClass, b: CourseClass) => this.beginOf(a) - this.beginOf(b));
    const clusters: ScheduleCluster[] = [];
    let i = 0;
    let index = 0;
    while (i < list.length) {
      const group: CourseClass[] = [list[i]];
      let j = i + 1;
      while (j < list.length && this.overlapsCluster(group, list[j])) {
        group.push(list[j]);
        j++;
      }
      let minBegin: number = this.beginOf(group[0]);
      let maxEnd: number = this.beginOf(group[0]) + this.spanOf(group[0]) - 1;
      let signature: string = '';
      for (let k = 0; k < group.length; k++) {
        const b: number = this.beginOf(group[k]);
        const e: number = b + this.spanOf(group[k]) - 1;
        if (b < minBegin) {
          minBegin = b;
        }
        if (e > maxEnd) {
          maxEnd = e;
        }
        const item: CourseClass = group[k];
        const rawPlace: string | undefined = item.placeName;
        const place: string = rawPlace === undefined ? '' : rawPlace;
        signature += item.courseCode + place + b.toString() + '_';
      }
      clusters.push(makeCluster(minBegin, maxEnd - minBegin + 1, group,
        'c' + day + '-' + index.toString() + '-' + signature + 'w' + week.toString()));
      index++;
      i = j;
    }
    return clusters;
  }

  /**
   * 初始化「全周预加载」容器：把本地缓存里所有周先填进去（首屏不等网络），
   * 再把 Swiper 对齐到当前周。其余周由 `prefetchAllWeeks` 后台补齐。
   */
  private initWeekSchedules(termCode: string, weeks: Week[], current: number): void {
    let maxWeek = 0;
    for (let i = 0; i < weeks.length; i++) {
      if (weeks[i].serialNumber > maxWeek) {
        maxWeek = weeks[i].serialNumber;
      }
    }
    const arr: WeeklySchedule[] = new Array(maxWeek + 1);
    for (let i = 0; i < weeks.length; i++) {
      const n: number = weeks[i].serialNumber;
      const cached: WeeklySchedule | null = ScheduleCache.loadWeek(termCode, n);
      if (cached !== null) {
        arr[n] = cached;
      }
    }
    // 与当前内存中的容器逐周比较：内容一致就不替换（否则「缓存 → 网络」会用同一份数据
    // 触发一次全量重绘，看起来像闪了一下）
    let same = this.weekSchedules.length === arr.length;
    if (same) {
      for (let i = 0; i < arr.length; i++) {
        const oldOne = this.weekSchedules[i];
        const newOne = arr[i];
        if (oldOne === newOne) {
          continue;
        }
        if ((oldOne === undefined || oldOne === null) &&
          (newOne === undefined || newOne === null)) {
          continue;
        }
        if (oldOne === undefined || oldOne === null || newOne === undefined || newOne === null) {
          same = false;
          break;
        }
        if (!sameWeeklySchedule(oldOne, newOne)) {
          same = false;
          break;
        }
      }
    }
    if (!same) {
      this.weekSchedules = arr;
    }
    // 当前周若缓存里没有，等 prefetchAllWeeks 补；有的话直接刷界面
    const cur = this.scheduleFor(current);
    if (cur !== null && (this.currentWeek !== current || !sameWeeklySchedule(this.schedule, cur))) {
      this.applySchedule(cur, current);
    }
    this.currentWeek = current;
    this.header.currentWeek = current;
    this.header.onScrollWeekIntoView(current);
    // weeks 已经拿到 → 进入 Swiper 渲染（每页各自显示自己的加载/错误占位），
    // 不要再卡在整页 LOADING（否则当前周没缓存时会永远转圈）
    this.loadState = LoadState.SUCCESS;
    // 挂载后对齐到当前周（不再用 .index()，见 Swiper.onAppear 的注释）
    this.syncSwiperIndex();
  }

  /** 把 Swiper 当前页对齐到 `currentWeek`，延时确保组件已挂载。 */
  private syncSwiperIndex(): void {
    setTimeout(() => {
      try {
        this.swiperController.changeIndex(this.weekIndex(this.currentWeek), false);
      } catch (e) {
        // 尚未挂载则忽略（Swiper.onAppear 里还会再对齐一次）
      }
    }, 0);
  }

  @Builder
  gridHeaderForWeek(week: number) {
    Row() {
      Blank()
        .width(SCHEDULE_COLUMN_WIDTH)

      ForEach(DateUtil.weekdayNames(), (name: string, index: number) => {
        Column({ space: 2 }) {
          // 双层阴影：Text 一次只能挂一个 textShadow，所以叠两个完全重合的 Text
          // 底层 = 实心偏移阴影（深色起效），顶层 = 原来的柔和光晕（两主题都保留）
          Stack() {
            Text(name)
              .fontSize(AppFont.caption)
              .fontColor($r('app.color.header_text'))
              .fontWeight(index + 1 === DateUtil.currentWeekday() ? FontWeight.Bold : FontWeight.Normal)
              .textShadow({
                radius: $r('app.float.header_shadow_solid_radius'),
                color: $r('app.color.header_shadow_solid'),
                offsetX: $r('app.float.header_shadow_offset_x'),
                offsetY: $r('app.float.header_shadow_offset_y')
              })
            Text(name)
              .fontSize(AppFont.caption)
              .fontColor($r('app.color.header_text'))
              .fontWeight(index + 1 === DateUtil.currentWeekday() ? FontWeight.Bold : FontWeight.Normal)
              .textShadow({
                radius: $r('app.float.header_shadow_radius'),
                color: $r('app.color.header_shadow'),
                offsetX: 0,
                offsetY: 0
              })
          }

          Stack() {
            Text(this.dayDateFor(index + 1, week))
              .fontSize(10)
              .fontColor($r('app.color.header_text'))
              .textShadow({
                radius: $r('app.float.header_shadow_solid_radius'),
                color: $r('app.color.header_shadow_solid'),
                offsetX: $r('app.float.header_shadow_offset_x'),
                offsetY: $r('app.float.header_shadow_offset_y')
              })
            Text(this.dayDateFor(index + 1, week))
              .fontSize(10)
              .fontColor($r('app.color.header_text'))
              .textShadow({
                radius: $r('app.float.header_shadow_radius'),
                color: $r('app.color.header_shadow'),
                offsetX: 0,
                offsetY: 0
              })
          }
        }
        .height(HEADER_HEIGHT)
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      }, (name: string, index: number) => index.toString())
    }
    .width('100%')
    .padding({ top: 6, bottom: 6 })
    .borderRadius(AppSize.cardRadius)
    // 把顶栏的模糊往下延伸：表头这一条也做背景模糊，并向上一段盖住与标题栏之间的缝
    .backdropBlur(20)
    // 网格内容在 Scroll 里允许画到自身盒子之外（为了延伸到底栏下方），
    // 上滑时会从日期表头下面穿过去；给表头更高的层级，让它始终压住课程块
    .zIndex(2)
  }

  @Builder
  scheduleGridForWeek(week: number) {
    Row() {
      // 左侧节次列
      Column() {
        ForEach(this.sectionsOf(this.sectionCountFor(week)), (section: number) => {
          Column({ space: 2 }) {
            Text(section.toString())
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textSecondary)
          }
          .width(SCHEDULE_COLUMN_WIDTH)
          .height(SECTION_CELL_HEIGHT)
          .justifyContent(FlexAlign.Center)
        }, (section: number) => section.toString())
      }

      // 七天列
      ForEach(DateUtil.weekdayNames(), (name: string, index: number) => {
        Column() {
          Stack() {
            // 背景网格线
            Column() {
              ForEach(this.sectionsOf(this.sectionCountFor(week)), (section: number) => {
                Row()
                  .width('100%')
                  .height(SECTION_CELL_HEIGHT)
                  .border({
                    width: 0.5,
                    color: AppColor.divider
                  })
              }, (section: number) => section.toString())
            }
            .width('100%')

            // 课程块（按冲突簇渲染：只有一门课照常，多门合成「N节课 / 查看」）
            // 数据还没拉到时这一周是空网格（weekPage 已用加载/错误占位盖住整块）
            if (this.scheduleFor(week) !== null) {
              ForEach(this.dayClustersFor(index + 1, this.scheduleFor(week) as WeeklySchedule, week),
                (cluster: ScheduleCluster) => {
                  this.courseCluster(cluster)
                }, (cluster: ScheduleCluster) => cluster.key)
            }
          }
          .width('100%')
          .height(this.sectionCountFor(week) * SECTION_CELL_HEIGHT)
          .alignContent(Alignment.TopStart)
        }
        .layoutWeight(1)
      }, (name: string, index: number) => index.toString())
    }
    .width('100%')
    // 仅「当前正停的那一周」在数据刷新瞬间变淡一点；其余周已预加载好，始终保持实色
    .opacity(week === this.currentWeek && this.weekLoading ? 0.45 : 1)
  }

  /**
   * Swiper 的一页：某教学周的完整课表（表头 + 可纵向滚动的网格）。
   *
   * 数据来自预加载容器 `weekSchedules[week]`：拉到前显示加载/错误占位，
   * 拉到后像照片一样直接显示。每页自带纵向 Scroll，课程多时页内可滑。
   */
  @Builder
  weekPage(week: number) {
    Column() {
      Column() {
        if (this.scheduleFor(week) === null) {
          if (this.weekErrors[week] === true) {
            ErrorView({
              message: '第' + week.toString() + '周加载失败',
              onRetry: () => { this.reloadWeek(week); }
            })
          } else {
            LoadingView({ message: '第' + week.toString() + '周加载中…' })
          }
        } else if (this.scheduleFor(week)!.arrangedList.length === 0) {
          EmptyView({ message: '本周暂无课程安排' })
        } else {
          // 下拉刷新只包在「这一周的网格」上：Refresh 必须直接包住可滚动组件才会触发；
          // 转圈状态按「周」分开存，页面重建也不会残留（共享一个状态会导致一直转）
          Refresh({ refreshing: this.isWeekRefreshing(week) }) {
            Scroll() {
              this.scheduleGridForWeek(week)
            }
            .width('100%')
            .scrollBar(BarState.Off)
            // 页内纵向滚动要有回弹（内容不足一屏也能回弹）
            .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
            .clip(false)
            .expandSafeArea()
          }
          .onRefreshing(() => {
            this.startWeekRefresh(week);
          })
          .layoutWeight(1)
          .width('100%')
          // 允许内容画到底栏下面（放开裁剪）。上滑时课程块会从日期表头下面穿过去，
          // 表头本身已用 zIndex 提到上层，所以不会被盖住。
          .clip(false)
          .expandSafeArea()
        }
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .alignItems(HorizontalAlign.Start)
  }

  private weekStart(): Date | null {
    for (let i = 0; i < this.weeks.length; i++) {
      if (this.weeks[i].serialNumber === this.currentWeek) {
        return DateUtil.parse(this.weeks[i].startDate);
      }
    }
    return null;
  }

  private dayDate(day: number): string {
    return this.dayDateFor(day, this.currentWeek);
  }

  private spanOf(course: CourseClass): number {
    const begin = course.beginSection !== undefined && course.beginSection > 0 ? course.beginSection : 1;
    const end = course.endSection !== undefined && course.endSection >= begin ? course.endSection : begin;
    return end - begin + 1;
  }

  private beginOf(course: CourseClass): number {
    return course.beginSection !== undefined && course.beginSection > 0 ? course.beginSection : 1;
  }

  /** 教室名最多显示几行：给课程名留 2 行，其余高度按 14vp/行 折算给教室。 */
  private placeMaxLines(course: CourseClass): number {
    const height: number = this.spanOf(course) * SECTION_CELL_HEIGHT - 3;
    const lines: number = Math.floor((height - 8 - 28) / 14);
    if (lines < 1) {
      return 1;
    }
    return lines > PLACE_MAX_LINES_CAP ? PLACE_MAX_LINES_CAP : lines;
  }

  /**
   * 课程块里课程名最多显示几行。
   *
   * 行数按块高给（上限 6 行、下限 2 行）。真正的空间竞争交给布局本身：课程名带
   * `layoutWeight(1)`、教室按自然高度显示 —— 教室名长的时候课程名会先被压缩成
   * 省略号，这个上限只是防止极端长名把文字撑出块外。
   */
  private nameMaxLines(course: CourseClass): number {
    const height: number = this.spanOf(course) * SECTION_CELL_HEIGHT - 3;
    let lines: number = Math.floor((height - 8) / 14);
    if (lines < 2) {
      lines = 2;
    }
    if (lines > 6) {
      lines = 6;
    }
    return lines;
  }

  /* ------------------------- 构建 ------------------------- */

  /**
   * 半模态自绘头部：标题 + 右上角关闭按钮（×）。
   *
   * 与 SPOC 作业详情面板同一套做法（见 `SpocPage.sheetHeader`）：`bindSheet` 原生的
   * `title` / `showClose` 画在**面板 chrome 区**，而且 chrome 区会把内容压到它下方 ——
   * 面板底板一透明（要透出沉浸材质），chrome 区既没有底板、材质又铺不到，标题与关闭
   * 按钮就会「浮」在面板框外面。所以关掉原生头部，自己画一行，让内容铺满整个面板。
   *
   * **排版与原原生标题行逐像素一致**（真机 dump 实测原生行：面板顶 y=1362px 时标题
   * `[56,1446][336,1528]`、关闭按钮圆心 `(1190,1488)`）—— 即标题左缘 16vp、标题与关闭
   * 按钮同一条中线在面板顶下 36vp、关闭按钮 40vp 圆且圆心距右边 36vp。
   * `Row` + 行高 64 + 顶部内边距 8 → 内容盒 8~64vp，竖向居中正好落在 36vp。
   */
  /** 打开学期选择弹窗。 */
  private openTermDialog(): void {
    this.termDialogController = new CustomDialogController({
      builder: TermDialog({
        terms: this.visibleTerms(),
        currentCode: this.termCode,
        onPick: (item: Term) => {
          this.applyTerm(item);
          this.needFullRefresh = true;
          this.loadWeeks(item.itemCode);
        }
      }),
      autoCancel: true,
      alignment: DialogAlignment.Center,
      customStyle: true
    });
    if (this.termDialogController !== null) {
      this.termDialogController.open();
    }
  }

  /**
   * 学期选择弹窗：尺寸与设计对齐课程详情弹窗。
   * 宽 86% / 最大 400vp、圆角 24、内边距 cardPadding+4、标题 + 分隔线 + 限高滚动 + 完成。
   */
  @Builder
  termDialogCard() {
    Stack() {
      if (this.materialActive) {
        MaterialCardLayer({ layerRadius: AppSize.cardRadiusLarge })
      }

      Column() {
        Row() {
          Text('选择学期')
            .fontSize(AppFont.title)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColor.textPrimary)
            .maxLines(1)

          Stack() {
            if (this.materialActive) {
              MaterialCardLayer({ layerRadius: 20, layerShadow: false })
            } else {
              Column()
                .width('100%')
                .height('100%')
                .borderRadius(20)
                .backgroundColor(AppColor.circleButtonSurface)
            }
            Button({ type: ButtonType.Normal, stateEffect: false }) {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(24)
                .fontColor([AppColor.textPrimary])
            }
            .width(40)
            .height(40)
            .borderRadius(20)
            .backgroundColor(Color.Transparent)
            .onClick(() => {
              if (this.termDialogController !== null) {
                this.termDialogController.close();
              }
            })
          }
          .width(40)
          .height(40)
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .alignItems(VerticalAlign.Center)
        .margin({ bottom: 8 })

        Divider()
          .color(AppColor.divider)
          .strokeWidth(0.5)

        // 学期块可上下滑动（限高 380，与课程详情弹窗一致）
        Scroll() {
          Column({ space: 6 }) {
            ForEach(this.visibleTerms(), (item: Term) => {
              Row() {
                Text(item.itemName)
                  .fontSize(AppFont.body)
                  .fontColor(AppColor.textPrimary)
                  .layoutWeight(1)
                if (item.itemCode === this.termCode) {
                  SymbolGlyph($r('sys.symbol.checkmark'))
                    .fontSize(18)
                    .fontColor([AppColor.brand])
                }
              }
              .width('100%')
              .height(44)
              .padding({ left: 12, right: 12 })
              .borderRadius(AppSize.cardRadius)
              .backgroundColor(item.itemCode === this.termCode ? AppColor.brandContainerGlass : Color.Transparent)
              .onClick(() => {
                this.applyTerm(item);
                if (this.termDialogController !== null) {
                  this.termDialogController.close();
                }
                this.needFullRefresh = true;
                this.loadWeeks(item.itemCode);
              })
            }, (item: Term) => item.itemCode)
          }
          .width('100%')
          .padding({ top: 8 })
        }
        .width('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .constraintSize({ maxHeight: 380 })
        .margin({ top: 4 })

        Stack() {
          if (this.materialActive) {
            MaterialCardLayer({ layerRadius: 22, layerShadow: false })
          }
          Button('完成')
            .width('100%')
            .height(44)
            .fontSize(AppFont.subtitle)
            .fontColor(AppColor.textOnBrand)
            .backgroundColor(this.materialActive ? AppColor.brandGlass : AppColor.brand)
            .onClick(() => {
              if (this.termDialogController !== null) {
                this.termDialogController.close();
              }
            })
        }
        .width('100%')
        .height(44)
        .borderRadius(22)
        .margin({ top: 16 })
      }
      .width('100%')
      .padding(AppSize.cardPadding + 4)
      .alignItems(HorizontalAlign.Start)
    }
    .width('86%')
    .constraintSize({ maxWidth: 400 })
    .borderRadius(AppSize.cardRadiusLarge)
    .backgroundColor(Color.Transparent)
  }

  @Builder
  sheetHeader() {
    Row() {
      Text('选择学期')
        .fontSize(AppFont.title)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.textPrimary)
        .maxLines(1)

      // 关闭按钮：40vp 圆底，**与 SPOC 面板的关闭按钮逐字一致**，规格取自二级页左上角的
      // 原生返回按钮（真机实测：`Button` 盒 40×40vp、图标 24vp、圆底是「淡一层的叠加色」
      // `AppColor.circleButtonSurface`，**没有模糊**）。改一处务必同步改另一处。
      //
      // ⚠️ 两条踩过的坑：
      // 1. 叠加色不要写在容器 `backgroundColor` 上再垫材质 —— 材质的绘制层级在
      //    backgroundColor **之上**，颜色会被盖住，圆底等于没颜色；
      // 2. 不要给圆底加 `backdropBlur` —— 会变成一团「只有模糊、看不出底板」的糊斑
      //    （用户反馈「目前仅有模糊」）。返回按钮的底板就是干净的一层半透明色。
      // 关闭按钮：40vp 圆底，位置/尺寸不变，只是把底板换成系统沉浸材质
      Stack() {
        if (this.materialActive) {
          // 材质画在承载层上，按钮本身保持透明，避免底色盖住材质
          MaterialCardLayer({ layerRadius: 20, layerShadow: false })
        } else {
          Column()
            .width('100%')
            .height('100%')
            .borderRadius(20)
            .backgroundColor(AppColor.circleButtonSurface)
        }
        Button({ type: ButtonType.Normal, stateEffect: false }) {
          SymbolGlyph($r('sys.symbol.xmark'))
            .fontSize(24)
            .fontColor([AppColor.textPrimary])
        }
        .width(40)
        .height(40)
        .borderRadius(20)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.showTermSheet = false;
        })
      }
      .width(40)
      .height(40)
    }
    .width('100%')
    // 行高 64vp（内容盒 56vp、与原生标题行同高），顶部再让 8vp → 标题与关闭按钮的
    // 中线正好落在面板顶下 36vp，与原来那条原生标题行逐像素一致
    .height(64)
    .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding, top: 8 })
    .alignItems(VerticalAlign.Center)
    .justifyContent(FlexAlign.SpaceBetween)
  }

  @Builder
  termSheet() {
    // Stack 默认 alignContent 是 Center —— 头部（64vp）是内容列之外的兄弟节点，
    // 不显式置 Top 会被摆到面板正中、压在选项块上。
    Stack({ alignContent: Alignment.Top }) {
      // ① 面板底板：沉浸材质。承载层自己画成「上圆下方」（下两角贴屏幕底要切平）。
      if (this.materialActive) {
        MaterialCardLayer({ layerRadius: AppSize.sheetRadius, layerSquareBottom: true })
      }

      // ② 选项块：外面包一层 Scroll —— 学期多到超出面板时**可以滚动**（不再被固定裁掉），
      //    上/下划时也给弹性回弹（`alwaysEnabled`：列表没超出可视区也能回弹）。
      //    面板是固定高度，Scroll 铺满面板，承载层才糊得满。
      Scroll() {
        Column({ space: AppSize.gap }) {
          ForEach(this.visibleTerms(), (item: Term) => {
          // ③ 每个选项块各自一块材质：Stack{ 承载层 + 内容行 }，由内容行驱动尺寸
          Stack() {
            if (this.materialActive) {
              MaterialCardLayer({ layerRadius: AppSize.cardRadius, layerShadow: false })
            }
            Row() {
              Text(item.itemName)
                .fontSize(AppFont.body)
                .fontColor(AppColor.textPrimary)
                .layoutWeight(1)
              if (item.itemCode === this.termCode) {
                SymbolGlyph($r('sys.symbol.checkmark'))
                  .fontSize(18)
                  .fontColor([AppColor.brand])
              }
            }
            .width('100%')
            .padding(AppSize.cardPadding)
            .borderRadius(AppSize.cardRadius)
            // 选中态的品牌色**只能叠在材质之上**（材质的绘制层级在组件 backgroundColor
            // 之上，写在承载层那侧会被盖住），所以用带透明度的 brand_container_glass；
            // 未选中直接透明，让块自己的材质透出来。
            .backgroundColor(item.itemCode === this.termCode ? AppColor.brandContainerGlass : Color.Transparent)
            .onClick(() => {
              this.applyTerm(item);
              this.showTermSheet = false;
              // 换学期是用户主动操作：这个学期本地通常没有缓存，需要联网取一份
              this.needFullRefresh = true;
              this.loadWeeks(item.itemCode);
            })
          }
          .width('100%')
          .borderRadius(AppSize.cardRadius)
          // 材质不可用时退回原来的实底（选中品牌色 / 未选中半透明玻璃底）
          .backgroundColor(this.materialActive ? Color.Transparent :
            (item.itemCode === this.termCode ? AppColor.brandContainer : AppColor.glassSurface))
        }, (item: Term) => item.itemCode)
      }
        .width('100%')
        // ⚠️ 必须给最小高度：Scroll 会把「比视口矮的子节点」**垂直居中**（实测选项整体
        //    下移 176px）。撑满视口后内容才从顶部排起，选项位置与改前一致；学期多时
        //    内容自然长高、照样能滚。
        .constraintSize({ minHeight: '100%' })
        .padding({
          left: AppSize.pagePadding,
          right: AppSize.pagePadding,
          // 自绘头部占 64vp，再加原来的 8vp 段间距 = 72vp —— 选项块绝对位置与改前一致
          top: 72,
          bottom: AppSize.pagePadding
        })
      }
      .width('100%')
      .height('100%')
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })

      this.sheetHeader()
    }
    .width('100%')
    .height('100%')
    .borderRadius({
      topLeft: AppSize.sheetRadius,
      topRight: AppSize.sheetRadius,
      bottomLeft: 0,
      bottomRight: 0
    })
    // 材质之下必须透明（底色会垫在材质下叠出灰感）；材质不可用时退回玻璃底（配合面板自带模糊）
    .backgroundColor(this.materialActive ? Color.Transparent : AppColor.glassSurface)
  }

  @Builder
  courseBlock(course: CourseClass) {
    Column() {
      // 课程名贴顶，占满可用宽度；行数按块高动态放宽（见 nameMaxLines）
      Text(course.courseName)
        .fontSize(11)
        .fontColor(this.courseTextColor(course))
        .fontWeight(FontWeight.Medium)
        .maxLines(this.nameMaxLines(course))
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')
        // 关键：课程名带 layoutWeight(1) —— 先把位置让给教室（按自然高度完整占位），
        // 剩下多少才归课程名、不够时课程名自己收成省略号。反过来写（教室固定一两行）
        // 就会出现「教室名被截断」的问题。
        .layoutWeight(1)
        // 盒子被撑高时文字默认居中，这里显式贴顶
        .align(Alignment.TopStart)
      // 教室贴底：优先完整显示（行数按块高给，见 placeMaxLines）
      if (course.placeName !== undefined && course.placeName.length > 0) {
        Text(course.placeName)
          .fontSize(10)
          .fontColor(this.courseSubTextColor(course))
          .maxLines(this.placeMaxLines(course))
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .align(Alignment.BottomStart)
      }
    }
    .width('100%')
    .padding(4)
    .alignItems(HorizontalAlign.Start)
    // 不写 SpaceBetween：课程名靠 layoutWeight 撑满，教室自然被顶到最底部
    .justifyContent(FlexAlign.Start)
    .borderRadius(8)
    // 实色 + 细描边，不叠 backdropBlur / 半透明：
    //   1) 半透明 + 高斯模糊会让块边缘向外糊开、颜色发虚，块间边界看不清；
    //   2) 十几个块各做一次模糊也是这页滚动开销的大头。
    .backgroundColor(this.courseColor(course))
    .border({ width: 1, color: this.courseBorderColor(course) })
    .position({
      x: 1,
      y: (this.beginOf(course) - 1) * SECTION_CELL_HEIGHT + 1
    })
    .height(this.spanOf(course) * SECTION_CELL_HEIGHT - 3)
    .onClick(() => {
      this.openCourseDetail(course);
    })
  }

  /**
   * 「同时段 N 节课」块 —— 照官方课表的处理方式：不做左右分半，而是合成一块、
   * 占满整列宽，正中写「N节课 / 查看」，点开才选具体哪门课。
   *
   * 同一门课的多条记录（如常微分方程 1-1 与 2-2）节次不相交，仍各自成块、不受影响。
   */
  @Builder
  multiCourseBlock(cluster: ScheduleCluster) {
    Column({ space: 2 }) {
      Text(cluster.courses.length.toString() + '节课')
        .fontSize(12)
        .fontColor('#FFFFFFFF')
        .fontWeight(FontWeight.Medium)
        .maxLines(1)
      // 块太矮（就一节高）时只留一行，别把「查看」挤出去
      if (cluster.height * SECTION_CELL_HEIGHT >= 96) {
        Text('查看')
          .fontSize(11)
          .fontColor('#CCFFFFFF')
          .maxLines(1)
      }
    }
    .width('100%')
    .height(cluster.height * SECTION_CELL_HEIGHT - 3)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .borderRadius(8)
    // 品牌蓝：与课程本身的颜色区分开，一眼认出「这是汇总入口，不是某门课」
    .backgroundColor(AppColor.brand)
    .border({ width: 1, color: '#33FFFFFF' })
    .position({
      x: 1,
      y: (cluster.begin - 1) * SECTION_CELL_HEIGHT + 1
    })
    .onClick(() => {
      this.openMultiCourse(cluster);
    })
  }

  /**
   * 一个冲突簇的渲染：**只有一门课就正常显示课程块，多门课合成「N节课 / 查看」块**。
   *
   * 单门课走的是改造前那条路径（`width('100%')` + `position{x:1}`），几何逐像素不变。
   */
  @Builder
  courseCluster(cluster: ScheduleCluster) {
    if (cluster.courses.length > 1) {
      this.multiCourseBlock(cluster)
    } else {
      this.courseBlock(cluster.courses[0])
    }
  }

  @Builder
  gridHeader() {
    Row() {
      Blank()
        .width(SCHEDULE_COLUMN_WIDTH)

      ForEach(DateUtil.weekdayNames(), (name: string, index: number) => {
        Column({ space: 2 }) {
          Text(name)
            .fontSize(AppFont.caption)
            .fontColor(index + 1 === DateUtil.currentWeekday() ? AppColor.brand : AppColor.textSecondary)
          Text(this.dayDate(index + 1))
            .fontSize(10)
            .fontColor(AppColor.textTertiary)
        }
        .height(HEADER_HEIGHT)
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      }, (name: string, index: number) => index.toString())
    }
    .width('100%')
    // 沉浸光感：表头从「透明裸排」升级为一条浮起的材质条（磨砂 + 自适应着色 +
    // 半透明底）。左右不加 padding —— 表头与下面网格的列宽靠同一套
    // 「SCHEDULE_COLUMN_WIDTH + layoutWeight(1) × 7」对齐，加了内边距会错列。
    .padding({ top: 6, bottom: 6 })
    .borderRadius(AppSize.cardRadius)
    // 普通高斯模糊 + 半透明底。原先挂系统材质（backgroundBlurStyle + 自适应取色），
    // 表头 + 十几个课程块每帧一起重新取色，滚动直接掉帧，已换掉（见 AppMaterial 注释）。
    .backdropBlur(AppMaterial.blurLarge)
    .backgroundColor(AppColor.glassSurface)
  }

  @Builder
  scheduleGrid() {
    Row() {
      // 左侧节次列
      Column() {
        ForEach(this.sections(), (section: number) => {
          Column({ space: 2 }) {
            Text(section.toString())
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textSecondary)
          }
          .width(SCHEDULE_COLUMN_WIDTH)
          .height(SECTION_CELL_HEIGHT)
          .justifyContent(FlexAlign.Center)
        }, (section: number) => section.toString())
      }

      // 七天列
      ForEach(DateUtil.weekdayNames(), (name: string, index: number) => {
        Column() {
          Stack() {
            // 背景网格线
            Column() {
              ForEach(this.sections(), (section: number) => {
                Row()
                  .width('100%')
                  .height(SECTION_CELL_HEIGHT)
                  .border({
                    width: 0.5,
                    color: AppColor.divider
                  })
              }, (section: number) => section.toString())
            }
            .width('100%')

            // 课程块（按冲突簇渲染：只有一门课照常，多门合成「N节课 / 查看」）
            ForEach(this.dayClusters(index + 1), (cluster: ScheduleCluster) => {
              this.courseCluster(cluster)
            }, (cluster: ScheduleCluster) => cluster.key)
          }
          .width('100%')
          .height(this.sectionCount * SECTION_CELL_HEIGHT)
          .alignContent(Alignment.TopStart)
        }
        .layoutWeight(1)
      }, (name: string, index: number) => index.toString())
    }
    .width('100%')
    // 切周时网格整体变淡一点作为「正在更新」的反馈 —— 表头与节次列始终保持可见
    .opacity(this.weekLoading ? 0.45 : 1)
  }

  /* ---------------- 拖动翻页（自己接管手势，阈值比系统松） ---------------- */

  /**
   * 拖动位移（vp，负=向左）。整块 Swiper 跟着手指走，邻页从边上滑进来（照片式跟手）。
   */
  @State private dragOffsetX: number = 0;
  /**
   * Swiper 预渲染的邻页数量。
   *
   * 冷启动点开课表时同步构建 3 页网格要 ~350ms（真机实测），就是那一下卡顿。
   * 首帧只建当前页（0），渲染完再补到 1 —— 页面先出来，邻页晚一帧进渲染树。
   */
  @State private swiperCacheCount: number = 0;
  /** 各周自己的「下拉刷新中」状态（下标 = 周序号）。 */
  @State private refreshingWeeks: boolean[] = [];
  /** 下拉刷新是否在跑（互斥用）。 */
  private refreshInFlight: boolean = false;
  /** 是否需要「整学期联网比对」：只在本页无缓存 / 账号变化时置 true。 */
  private needFullRefresh: boolean = false;
  /** 下拉刷新的冷却截止时间：挡住 Refresh 组件因重建而重复触发的 onRefreshing。 */
  private refreshCooldownUntil: number = 0;
  /** 拖动开始时所在的页序（weeks 数组下标）。 */
  private dragStartIndex: number = 0;
  /** 一页的宽度（vp），用来换算翻页阈值。 */
  private pageWidthVp: number = 0;

  /**
   * 翻页阈值：滑过**页宽的百分之多少**就翻页。
   *
   * ## 为什么不用系统 Swiper 自带的
   *
   * ArkUI 的 Swiper 翻页阈值是**半页宽**（SDK 原文：the drag distance threshold for turning
   * pages is half of the width of the Swiper component）—— 本机 1316px 屏要划 658px
   * 才翻页，比系统/小程序（25~30%）费力得多，用户实测「同样距离系统能翻、我们翻不过去」。
   *
   * SDK 里**没有任何组件暴露滑动阈值**（`pageFlipMode` 只管鼠标滚轮），所以只能自己接管手势。
   */
  private static readonly FLIP_RATIO: number = 0.12;
  /** 快速甩动时的翻页速度阈值（vp/s）：甩得快就算距离不够也翻。 */
  private static readonly FLING_VELOCITY: number = 180;

  /** 拖动开始：记下起点页。 */
  private onWeekDragStart(): void {
    this.dragStartIndex = this.weekIndex(this.currentWeek);
    this.dragOffsetX = 0;
  }

  /** 拖动中：整块跟着手指走；到头了加橡皮筋阻尼。 */
  private onWeekDragUpdate(e: GestureEvent): void {
    let dx: number = e.offsetX;
    const atFirst: boolean = this.dragStartIndex <= 0;
    const atLast: boolean = this.dragStartIndex >= this.weeks.length - 1;
    if ((dx > 0 && atFirst) || (dx < 0 && atLast)) {
      dx = dx * 0.3; // 没得翻了 → 阻尼
    }
    this.dragOffsetX = dx;
  }

  /**
   * 松手：按**我们自己的阈值**决定翻不翻，然后弹到位。
   *
   * ## 位移怎么接上的（别看晕）
   *
   * Swiper 里第 P 页相对视口左缘的位置 = (P - 当前页序)×页宽 + 整体位移。
   * - **不翻**：位移从 dx 弹回 0 → 当前页滑回正中。
   * - **往前翻**：先把页序瞬切到 target（`changeIndex(target, false)`），此时目标页跑到「页序差 0」
   *   的位置；要让画面不跳，位移得先挪到 `dx + 页宽`（= 目标页切换前所在的位置），
   *   再从那里弹回 0 → 视觉上就是**邻页从右边滑进来归位**。
   * - **往后翻**同理，位移挪到 `dx - 页宽`。
   */
  private onWeekDragEnd(e: GestureEvent): void {
    const dx: number = this.dragOffsetX;
    const vx: number = e.velocityX;
    const threshold: number = Math.max(32, this.pageWidthVp * SchedulePage.FLIP_RATIO);
    let target: number = this.dragStartIndex;
    if (Math.abs(dx) > threshold || Math.abs(vx) > SchedulePage.FLING_VELOCITY) {
      target = dx < 0 ? this.dragStartIndex + 1 : this.dragStartIndex - 1;
    }
    if (target < 0) {
      target = 0;
    }
    if (target > this.weeks.length - 1) {
      target = this.weeks.length - 1;
    }
    if (target === this.dragStartIndex) {
      // 没翻过 → 弹回原位（弹簧）
      animateTo({ curve: swipeSettleCurve() }, () => {
        this.dragOffsetX = 0;
      });
      return;
    }
    const dir: number = target > this.dragStartIndex ? 1 : -1;
    // 先瞬切页（onChange 会接手同步当前周 / 胶囊条 / 记忆），再把位移挪到连续的位置
    this.swiperController.changeIndex(target, false);
    this.dragOffsetX = dx + dir * this.pageWidthVp;
    animateTo({ curve: swipeSettleCurve() }, () => {
      this.dragOffsetX = 0;
    });
  }

  /**
   * 下拉刷新：**唯一**会主动联网比对课表的入口（另一个是换账号后的首次加载）。
   *
   * 比对逻辑在 prefetchAllWeeks 里：逐周和本地比，只有真的变了才写状态 / 写缓存。
   */
  /**
   * 只比对指定周的课表（下拉刷新用：当前周 + 相邻一周）。
   *
   * 返回「实际发生变化的周数」。一致时不写状态、不写缓存、不重绘。
   */
  private async refreshWeeksNow(termCode: string, weeks: Week[], targets: number[]): Promise<number> {
    let changed = 0;
    const changedNums: number[] = [];
    const fresh: WeeklySchedule[] = [];
    const freshNums: number[] = [];
    let dirty = 0;
    for (let i = 0; i < targets.length; i++) {
      const n = targets[i];
      const existing: WeeklySchedule | null =
        this.weekSchedules[n] === undefined || this.weekSchedules[n] === null
          ? null : this.weekSchedules[n];
      let fetched: WeeklySchedule | null = null;
      try {
        fetched = await ApiService.fetchWeeklySchedule(termCode, n);
      } catch (error) {
        Logger.warn('刷新第' + n.toString() + '周失败：' + (error as Error).message);
      }
      if (fetched === null) {
        continue;
      }
      if (existing !== null && sameWeeklySchedule(existing, fetched)) {
        continue;
      }
      this.weekSchedules[n] = fetched;
      this.weekErrors[n] = false;
      changed++;
      changedNums.push(n);
      fresh.push(fetched);
      freshNums.push(n);
      dirty++;
    }
    if (dirty > 0) {
      this.weekSchedules = this.weekSchedules.slice();
      this.weekErrors = this.weekErrors.slice();
    }
    if (fresh.length > 0) {
      ScheduleCache.saveWeeks(termCode, fresh, freshNums);
    }
    if (changed > 0) {
      const all: WeeklySchedule[] = [];
      const allNums: number[] = [];
      for (let i = 0; i < weeks.length; i++) {
        const n = weeks[i].serialNumber;
        const data = this.weekSchedules[n];
        if (data !== undefined && data !== null) {
          all.push(data);
          allNums.push(n);
        }
      }
      if (all.length > 0) {
        this.pushTermCards(termCode, all, allNums);
      }
      Logger.info('课表有更新：' + changed.toString() + ' 周已刷新');
    }
    return changed;
  }

  /** 下拉刷新要优先比对的周：当前周 + 左右相邻各一周（存在才加）。 */
  private nearWeekNumbers(weeks: Week[]): number[] {
    const exists = (n: number): boolean => {
      for (let i = 0; i < weeks.length; i++) {
        if (weeks[i].serialNumber === n) {
          return true;
        }
      }
      return false;
    };
    const out: number[] = [];
    const push = (n: number): void => {
      if (n > 0 && exists(n) && out.indexOf(n) < 0) {
        out.push(n);
      }
    };
    push(this.currentWeek);
    push(this.currentWeek - 1);
    push(this.currentWeek + 1);
    return out;
  }

  /** 某一周是否正在下拉刷新。 */
  private isWeekRefreshing(week: number): boolean {
    return week < this.refreshingWeeks.length && this.refreshingWeeks[week] === true;
  }

  private setWeekRefreshing(week: number, value: boolean): void {
    const arr: boolean[] = this.refreshingWeeks.slice();
    while (arr.length <= week) {
      arr.push(false);
    }
    arr[week] = value;
    this.refreshingWeeks = arr;
  }

  /** 下拉刷新入口：先把「这一周」的转圈打开，结束后无论成败都关掉。 */
  private startWeekRefresh(week: number): void {
    if (this.refreshInFlight) {
      this.setWeekRefreshing(week, false);
      return;
    }
    this.setWeekRefreshing(week, true);
    this.onPullRefresh()
      .then(() => {
        this.setWeekRefreshing(week, false);
      })
      .catch(() => {
        this.setWeekRefreshing(week, false);
      });
  }

  private async onPullRefresh(): Promise<void> {
    if (this.refreshInFlight) {
      return;
    }
    // Refresh 在页面重建后可能再次回调 onRefreshing；冷却期内直接收敛状态，避免连环刷新
    if (Date.now() < this.refreshCooldownUntil) {
      this.refreshInFlight = false;
      return;
    }
    this.refreshInFlight = true;
    Logger.info('下拉刷新：开始');
    // 看门狗：任何异常路径都不允许转圈超过 15 秒
    const watchdog = setTimeout(() => {
      Logger.warn('下拉刷新超时，强制结束转圈');
      this.refreshInFlight = false;
    }, 8000);
    try {
      if (this.termCode.length === 0) {
        await this.loadTerms();
      } else {
        const list: Week[] = await ApiService.fetchWeeks(this.termCode);
        this.applyWeeks(list);
        // 先把「当前周 + 相邻一周」比完，转圈尽快结束；其余周放后台慢慢补
        const near = this.nearWeekNumbers(list);
        const changed = await this.refreshWeeksNow(this.termCode, list, near);
        const cur = this.scheduleFor(this.currentWeek);
        if (cur !== null) {
          this.applySchedule(cur, this.currentWeek);
        }
        Toast.show(changed > 0 ? '课表已更新' : '课表已是最新');
        // 后台补剩余周：不转圈、不阻塞下拉刷新
        const rest: number[] = [];
        for (let i = 0; i < list.length; i++) {
          const n = list[i].serialNumber;
          if (near.indexOf(n) < 0) {
            rest.push(n);
          }
        }
        if (rest.length > 0) {
          setTimeout(() => {
            // 与账号变化时的整学期预取互斥，避免同一周重复请求
            if (this.prefetching) {
              return;
            }
            this.prefetching = true;
            this.refreshWeeksNow(this.termCode, list, rest)
              .then(() => {
                this.prefetching = false;
              })
              .catch(() => {
                this.prefetching = false;
              });
          }, 1200);
        }
      }
      Logger.info('下拉刷新：近邻周比对完成');
      Logger.info('下拉刷新：结束');
    } catch (error) {
      Toast.show('刷新失败，继续显示本地课表');
      Logger.warn('下拉刷新课表失败：' + (error as Error).message);
    } finally {
      clearTimeout(watchdog);
      this.refreshInFlight = false;
      this.refreshCooldownUntil = Date.now() + 2000;
      // 再补一次复位：Refresh 组件在页面重建时可能把 true 写回来，下一拍强制收回
      setTimeout(() => {
        this.refreshInFlight = false;
      }, 120);
    }
  }

  build() {
    Column() {
      if (this.loadState === LoadState.LOADING) {
        LoadingView({ message: '正在加载课表…' })
      } else if (this.loadState === LoadState.ERROR) {
        ErrorView({
          message: this.errorMessage,
          onRetry: () => {
            this.loadTerms();
          }
        })
      } else if (this.weeks.length === 0) {
        EmptyView({ message: '暂无教学周数据' })
      } else {
        // 横向 Swiper：每一页 = 一个教学周的完整课表（表头 + 可纵向滚动的网格）。
        // 全部周已预加载进 weekSchedules，手指拖动时实时跟手、松手即停，
        // 像翻照片一样直接显示，无需等待网络（用户要求「直接滑动图片一样直接显示」）。
        Swiper(this.swiperController) {
          LazyForEach(this.weekData, (w: Week) => {
            this.weekPage(w.serialNumber)
          }, (w: Week) => w.serialNumber.toString())
        }
        .width('100%')
        .layoutWeight(1)
        .loop(false)
        .indicator(false)
        // ⚠️ `cachedCount(2, true)` 的第二个参数**必须给 true**：
        // 默认 false 时邻页只是「被缓存、**不加入渲染树**」—— 我们自己拖动时把邻页露出来，
        // 它却还没被渲染 → 滑到一半邻页那边**闪黑**。给 true 才真正画出来。
        .cachedCount(this.swiperCacheCount, true)
        // ⚠️ 不用 Swiper 自带的手势：它的翻页阈值是半页宽，太费力（见 FLIP_RATIO 注释）。
        // 关掉它，手势我们自己接管 —— 阈值 22% 页宽，还能自己加橡皮筋和甩动翻页。
        .disableSwipe(true)
        // 不裁剪 → 拖动时邻页能从边上露出来（照片式跟手：当前页滑走、邻页滑入）
        .clip(false)
        // 整块跟着手指走
        .translate({ x: this.dragOffsetX })
        // 弹簧曲线（iOS 风格）：松手后按甩出速度回弹到位，不用固定时长的匀减速。
        // ⚠️ 弹簧曲线不受 duration 控制，duration 只对 Curve.* 生效。
        .duration(280)
        .curve(swipeSettleCurve())
        .onAppear(() => {
          this.syncSwiperIndex();
          // 首帧已出：补上邻页，保证下一次滑动时邻页已在渲染树里
          setTimeout(() => {
            this.swiperCacheCount = 1;
          }, 32);
        })
        .onChange((index: number) => {
          const week = this.weeks[index].serialNumber;
          // 程序化跨周动画的中间页：跳过，只认最终目标那一页
          if (this.gotoTargetWeek >= 0 && week !== this.gotoTargetWeek) {
            return;
          }
          this.gotoTargetWeek = -1;
          this.onSwipeToWeek(week);
        })
        .onAreaChange((oldArea: Area, newArea: Area) => {
          const w = newArea.width;
          this.pageWidthVp = typeof w === 'number' ? w : 0;
        })
        .gesture(
          PanGesture({ direction: PanDirection.Horizontal, distance: 8 })
            .onActionStart(() => {
              this.onWeekDragStart();
            })
            .onActionUpdate((e: GestureEvent) => {
              this.onWeekDragUpdate(e);
            })
            .onActionEnd((e: GestureEvent) => {
              this.onWeekDragEnd(e);
            })
            // 手势被打断（父组件抢走 / 系统打断）时也要把位移弹回去，
            // 否则页面会一直停在偏移位置
            .onActionCancel(() => {
              animateTo({ curve: swipeSettleCurve() }, () => {
                this.dragOffsetX = 0;
              });
            })
        )
        .backgroundColor(Color.Transparent)
      }

      Blank()
        .height(AppSize.contentBottomInset)
    }
    .width('100%')
    .height('100%')
    .padding({
      // 课表用更小的左右边距，把宽度让给课程条（见 GRID_SIDE_PADDING 注释）
      left: GRID_SIDE_PADDING,
      right: GRID_SIDE_PADDING,
      // HDS 已把标题栏声明的组件安全区从内容区扣掉（网格从周次条下方开始），无需再让顶部
      top: 0,
      bottom: 0
    })
    // 沉浸光感：允许内容画到自身布局矩形之外、并延伸进标题栏安全区（下滚时钻到周次条底下）
    .backgroundColor(AppColor.pageBackground)
    .clip(false)
    .expandSafeArea()

  }
}