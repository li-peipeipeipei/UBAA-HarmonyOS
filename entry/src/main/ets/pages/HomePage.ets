import { AppRouter, LoadState, RouteName } from '../common/AppRouter';
import { DateUtil } from '../common/DateUtil';
import { Logger } from '../common/Logger';
import { Toast } from '../common/Toast';
import { ApiError } from '../network/ApiError';
import { ApiService } from '../network/ApiService';
import { TokenStore } from '../network/TokenStore';
import { AppColor, AppFont, AppSize } from '../components/AppTheme';
import { topSafeInsetVp } from '../common/ImmersiveUtil';
import {
  EmptyView,
  ErrorView,
  FeatureTile,
  LoadingView,
  SectionCard
} from '../components/CommonViews';
import { FeatureItem, quickFeatures } from '../components/FeatureRegistry';
import {
  buildCourseDetail,
  buildSimpleDetail,
  CourseDetail,
  CourseDetailDialog
} from '../components/CourseDetailDialog';
import { CourseClass, Exam, Term, TodayClass, Week, WeeklySchedule } from '../model/ApiTypes';

/** 取今日课程时间串 `15:50-17:25` 里的开始时间（取不到返回空串）。 */
function startTimeOf(item: TodayClass): string {
  const time: string = item.time === undefined ? '' : item.time;
  const dash: number = time.indexOf('-');
  return (dash > 0 ? time.substring(0, dash) : time).trim();
}

/** 取今日课程时间串里的结束时间（取不到返回空串）。 */
function endTimeOf(item: TodayClass): string {
  const time: string = item.time === undefined ? '' : item.time;
  const dash: number = time.indexOf('-');
  return dash >= 0 ? time.substring(dash + 1).trim() : '';
}

/** 当前时刻 `HH:mm`（与接口给的时间串同为定长，可直接字符串比较）。 */
function nowHHmm(): string {
  const date = new Date();
  const hour: number = date.getHours();
  const minute: number = date.getMinutes();
  return (hour < 10 ? '0' : '') + hour.toString() + ':' +
    (minute < 10 ? '0' : '') + minute.toString();
}

/**
 * 今日课程按**开始时间升序**排列（接口返回的顺序是随机的，不是按时间排的）。
 * 没有时间的条目排到最后。
 */
function sortTodayClasses(list: TodayClass[]): TodayClass[] {
  const sorted: TodayClass[] = list.slice();
  sorted.sort((a: TodayClass, b: TodayClass): number => {
    const left: string = startTimeOf(a);
    const right: string = startTimeOf(b);
    if (left === right) {
      return 0;
    }
    if (left.length === 0) {
      return 1;
    }
    if (right.length === 0) {
      return -1;
    }
    return left < right ? -1 : 1;
  });
  return sorted;
}

/**
 * 在课表里按课程名找课。
 *
 * 先精确匹配；不一致时退化为「包含」匹配 —— 今日课程接口有时用简称，
 * 与课表里的全称不完全一致。
 */
function findCourseByName(list: CourseClass[], name: string): CourseClass | null {
  for (let i = 0; i < list.length; i++) {
    if (list[i].courseName === name) {
      return list[i];
    }
  }
  for (let i = 0; i < list.length; i++) {
    const candidate: string = list[i].courseName;
    if (candidate.length > 0 && (candidate.indexOf(name) >= 0 || name.indexOf(candidate) >= 0)) {
      return list[i];
    }
  }
  return null;
}

/**
 * 主页。
 *
 * 信息层级：问候语 → 下一场考试倒计时 → 今日课程 → 快捷入口。
 * 页面本身不持有标题栏，标题栏由 MainPage 的 HdsNavigation 统一提供（含沉浸光感）。
 */
@Component
export struct HomePage {
  stack: NavPathStack = new NavPathStack();

  @State private loadState: LoadState = LoadState.LOADING;
  @State private errorMessage: string = '';
  @State private todayClasses: TodayClass[] = [];
  @State private hasNextExam: boolean = false;
  @State private nextExam: Exam = { courseName: '' };
  /** 下拉刷新进行中；Refresh 组件靠它复位转圈动画。 */
  @State private refreshing: boolean = false;
  /** 刷新请求是否在途（非 @State：只做互斥，不参与渲染）。 */
  private refreshInFlight: boolean = false;
  /** 今日课程详情弹窗的内容（@Observed 实例，弹窗用 @ObjectLink 订阅，可原地刷新）。 */
  @State private courseDetail: CourseDetail = new CourseDetail();
  private detailController: CustomDialogController | null = null;
  /**
   * 本周课表缓存（**进页面就预加载**）。
   *
   * 「今日课程」接口只给课程名 / 时间 / 地点，完整详情在课表响应里。预加载之后，
   * 点击课程块时是**同步组装**详情的 —— 与课表页同一个体验：点开即是完整内容，
   * 没有加载态、也没有「先把标签列出来再慢慢填值」的过程。
   */
  private preloadedCourses: CourseClass[] = [];
  private preloadDone: boolean = false;

  /** 各功能入口的使用次数；快捷入口按它排序（见 quickFeatures）。 */
  @State private featureUsage: Record<string, number> = {};

  aboutToAppear(): void {
    this.featureUsage = TokenStore.getFeatureUsage();
    this.loadHome(true);
    // 后台预加载本周课表（不阻塞首页渲染）—— 点课程时才有完整的详情可用
    this.preloadCourses();
  }

  /**
   * 预加载本周课表（与课表页取的是同一份数据）。
   *
   * 失败不影响首页（只是点开课程时退化成「时间 / 地点」两行），所以这里只记日志。
   */
  private async preloadCourses(): Promise<void> {
    if (this.preloadDone) {
      return;
    }
    try {
      const termCode: string = await this.resolveTermCode();
      if (termCode.length === 0) {
        return;
      }
      const week: number = await this.resolveCurrentWeek(termCode);
      const schedule: WeeklySchedule = await ApiService.fetchWeeklySchedule(termCode, week);
      this.preloadedCourses = schedule.arrangedList;
      this.preloadDone = true;
      Logger.info('首页预加载本周课表：' + this.preloadedCourses.length + ' 门（第 ' + week + ' 周）');
    } catch (error) {
      Logger.warn('首页预加载课表失败：' + (error as Error).message);
    }
  }

  /**
   * 当前教学周。
   *
   * **必须用「当前教学周」而不是「用户记住的周次」优先**：课表页会把用户翻看的周次记下来
   * （比如翻到第 10 周），若按它取，今天的课自然找不到。
   */
  private async resolveCurrentWeek(termCode: string): Promise<number> {
    const weeks: Week[] = await ApiService.fetchWeeks(termCode);
    for (let i = 0; i < weeks.length; i++) {
      if (weeks[i].curWeek) {
        return weeks[i].serialNumber;
      }
    }
    const remembered: number = TokenStore.getSelectedWeek();
    return remembered > 0 ? remembered : 1;
  }

  /**
   * 拉取主页数据。
   *
   * @param showLoading 首次进入（true）：整页切加载态，失败显示错误页 + 重试；
   *                    下拉刷新（false）：**保持现有内容**后台拉新，失败只轻提示 ——
   *                    刷新的语义是「更新」，把用户正在看的内容清空反而是打扰。
   */
  private async loadHome(showLoading: boolean): Promise<void> {
    if (showLoading) {
      this.loadState = LoadState.LOADING;
    }
    try {
      const classes: TodayClass[] = await ApiService.fetchTodayClasses();
      // 接口返回的顺序是乱的，按开始时间重排（早的在上）
      this.todayClasses = sortTodayClasses(classes);

      // 首次登录时还没有缓存学期，此时不能直接跳过考试 —— 否则首页会缺掉倒计时卡片
      const termCode: string = await this.resolveTermCode();
      if (termCode.length > 0) {
        const data = await ApiService.fetchExams(termCode);
        this.pickNextExam(data.arranged);
      }
      this.loadState = LoadState.SUCCESS;
    } catch (error) {
      const message = error instanceof ApiError ?
        (error as ApiError).friendlyMessage() : '加载失败，请稍后重试';
      if (showLoading) {
        this.errorMessage = message;
        this.loadState = LoadState.ERROR;
      } else {
        Toast.show('刷新失败：' + message);
      }
      Logger.error('主页数据加载失败：' + (error as Error).message);
    }
  }

  /** 下拉刷新入口；结束后把 refreshing 复位，Refresh 的转圈才会收起。 */
  private async refresh(): Promise<void> {
    // 互斥：不干净的手势（快速滑动收尾时）可能连续触发两次 onRefreshing，
    // 第二次直接忽略，否则同一秒内会对上游打两轮完全相同的请求（真机实测出现过）。
    if (this.refreshInFlight) {
      return;
    }
    this.refreshInFlight = true;
    try {
      await this.loadHome(false);
    } finally {
      this.refreshInFlight = false;
      this.refreshing = false;
    }
  }

  /** 取当前学期编码：优先用已缓存的，没有就拉一次学期列表并记住。 */
  private async resolveTermCode(): Promise<string> {
    const remembered = TokenStore.getSelectedTerm();
    if (remembered[0].length > 0) {
      return remembered[0];
    }
    const terms: Term[] = await ApiService.fetchTerms();
    if (terms.length === 0) {
      return '';
    }
    let picked: Term = terms[0];
    for (let i = 0; i < terms.length; i++) {
      if (terms[i].selected) {
        picked = terms[i];
        break;
      }
    }
    TokenStore.setSelectedTerm(picked.itemCode, picked.itemName);
    return picked.itemCode;
  }

  /** 取最近一场未结束的考试。 */
  private pickNextExam(list: Exam[]): void {
    let best: Exam | null = null;
    let bestDays: number = Number.MAX_SAFE_INTEGER;
    for (let i = 0; i < list.length; i++) {
      const item = list[i];
      const dateText = item.examDate !== undefined && item.examDate.length > 0 ?
        item.examDate : (item.examTimeDescription !== undefined ? item.examTimeDescription : '');
      const days = DateUtil.daysUntil(dateText);
      if (days === null || days < 0) {
        continue;
      }
      if (days < bestDays) {
        bestDays = days;
        best = item;
      }
    }
    if (best !== null) {
      this.nextExam = best as Exam;
      this.hasNextExam = true;
    } else {
      this.hasNextExam = false;
    }
  }

  private greeting(): string {
    const hour = new Date().getHours();
    if (hour < 6) {
      return '夜深了';
    }
    if (hour < 11) {
      return '早上好';
    }
    if (hour < 14) {
      return '中午好';
    }
    if (hour < 18) {
      return '下午好';
    }
    return '晚上好';
  }

  private userName(): string {
    const session = TokenStore.getSession();
    return session.userName.length > 0 ? session.userName : '同学';
  }

  private openFeature(item: FeatureItem): void {
    if (item.route.length === 0) {
      Toast.show(item.title + ' · 敬请期待');
      return;
    }
    // 记一次使用：快捷入口按使用次数排序，回来时顺序已经是新的
    TokenStore.recordFeatureUse(item.title);
    this.featureUsage = TokenStore.getFeatureUsage();
    AppRouter.push(this.stack, item.route);
  }

  /**
   * 点击今日课程：**同步组装、直接弹出完整详情**。
   *
   * 完整详情来自 `preloadedCourses`（进页面就预加载好的本周课表），所以这里没有任何
   * 异步等待 —— 与课表页点课程块的行为完全一致。只有预加载还没回来（或失败）时，
   * 才退化成「时间 / 地点」两行，不会出现加载态。
   */
  private openTodayDetail(item: TodayClass): void {
    const name: string = item.bizName;
    const time: string = item.time === undefined ? '' : item.time;
    const place: string = item.place === undefined ? '' : item.place;

    const match: CourseClass | null = findCourseByName(this.preloadedCourses, name);
    const detail: CourseDetail = match === null ?
      buildSimpleDetail(name, time, place) : buildCourseDetail(match);
    this.courseDetail.apply(detail.title, detail.rows);
    this.showDetail();
  }

  /** 弹出详情弹窗（controller 只建一次，重复打开复用）。 */
  private showDetail(): void {
    if (this.detailController === null) {
      this.detailController = new CustomDialogController({
        builder: CourseDetailDialog({ detail: this.courseDetail }),
        autoCancel: true,
        alignment: DialogAlignment.Center,
        customStyle: true
      });
    }
    if (this.detailController !== null) {
      this.detailController.open();
    }
  }

  @Builder
  examBanner() {
    Column({ space: 4 }) {
      Row() {
        Text(this.nextExam.courseName)
          .fontSize(AppFont.subtitle)
          .fontWeight(FontWeight.Medium)
          .fontColor(Color.White)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(DateUtil.countdownText(this.examDateText()))
          .fontSize(AppFont.caption)
          .fontColor('#E8F1FF')
      }
      .width('100%')

      Row({ space: 12 }) {
        Text(this.examDateText())
          .fontSize(AppFont.caption)
          .fontColor('#D6E6FF')
        if (this.nextExam.examPlace !== undefined && this.nextExam.examPlace.length > 0) {
          Text(this.nextExam.examPlace)
            .fontSize(AppFont.caption)
            .fontColor('#D6E6FF')
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .width('100%')
    }
    .width('100%')
    .padding(AppSize.cardPadding)
    .borderRadius(AppSize.cardRadius)
    .linearGradient({
      angle: 135,
      colors: [
        [AppColor.brand, 0.0],
        [AppColor.brandDark, 1.0]
      ]
    })
    .onClick(() => {
      AppRouter.push(this.stack, RouteName.EXAM);
    })
  }

  private examDateText(): string {
    const exam = this.nextExam;
    if (exam.examDate !== undefined && exam.examDate.length > 0) {
      return exam.examDate;
    }
    if (exam.examTimeDescription !== undefined) {
      return exam.examTimeDescription;
    }
    return '时间待定';
  }

  /** 这堂课是否已经上完（结束时间早于当前时刻）。 */
  private isPastClass(item: TodayClass): boolean {
    const end: string = endTimeOf(item);
    return end.length > 0 && end < nowHHmm();
  }

  @Builder
  todayClassItem(item: TodayClass) {
    Row({ space: AppSize.gap }) {
      Column() {
        Text(item.shortName !== undefined && item.shortName.length > 0 ? item.shortName : '课程')
          .fontSize(AppFont.caption)
          .fontColor(Color.White)
      }
      .width(36)
      .height(36)
      .borderRadius(10)
      // 已上完的课用灰底、未上的用品牌色 —— 扫一眼就知道今天上到哪儿了
      .backgroundColor(this.isPastClass(item) ? AppColor.textTertiary : AppColor.brand)
      .justifyContent(FlexAlign.Center)

      Column({ space: 2 }) {
        Text(item.bizName)
          .fontSize(AppFont.body)
          // 已上完的课程名也压暗一档，与待上的拉开一点点层次
          .fontColor(this.isPastClass(item) ? AppColor.textSecondary : AppColor.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Row({ space: 8 }) {
          if (item.time !== undefined && item.time.length > 0) {
            Text(item.time)
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textTertiary)
          }
          if (item.place !== undefined && item.place.length > 0) {
            Text(item.place)
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textTertiary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 点击提示：能弹出详情
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(14)
        .fontColor([AppColor.textTertiary])
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
    .alignItems(VerticalAlign.Center)
    .onClick(() => {
      this.openTodayDetail(item);
    })
  }

  build() {
    // 下拉刷新外壳：Refresh 包 Scroll，内容停在顶部时继续下拉即触发。
    // 注意：顶部模糊依赖「clip(false)+expandSafeArea()」这套扩展，Refresh 作为
    // 新的最外层容器也要开（见下方 .clip(false)/.expandSafeArea()），否则会避让
    // 标题栏组件安全区、把模糊顶没了。
    Refresh({ refreshing: $$this.refreshing }) {
      Scroll() {
        Column({ space: AppSize.gapLarge }) {
          // 问候语
          Column({ space: 2 }) {
            Text(this.greeting() + '，' + this.userName())
              .fontSize(26)
              .fontWeight(FontWeight.Bold)
              .fontColor(AppColor.textPrimary)
            Text(DateUtil.today() + ' · ' + DateUtil.weekdayNames()[DateUtil.currentWeekday() - 1])
              .fontSize(14)
              .fontColor(AppColor.textTertiary)
              // 日期相对问候语净下移（纯视觉位移）
              .translate({ y: 3 })
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          // 主页只上移「问候语 + 日期」两行（16vp，比其余页的整体上移 8vp 多一倍），
          // 卡片等其余内容保持原位不动。
          .translate({ y: -16 })

          if (this.loadState === LoadState.LOADING) {
            LoadingView({ message: '正在获取校园数据…' })
          } else if (this.loadState === LoadState.ERROR) {
            ErrorView({
              message: this.errorMessage,
              onRetry: () => {
                this.loadHome(true);
              }
            })
          } else {
            if (this.hasNextExam) {
              this.examBanner()
            }

            SectionCard({
              title: '今日课程',
              subtitle: this.todayClasses.length > 0 ?
                this.todayClasses.length.toString() + ' 节课' : '今天没有课',
              showAction: false
            }) {
              if (this.todayClasses.length === 0) {
                EmptyView({ message: '今天没有课程安排' })
              } else {
                Column() {
                  ForEach(this.todayClasses, (item: TodayClass, index: number) => {
                    this.todayClassItem(item)
                    if (index < this.todayClasses.length - 1) {
                      Divider().color(AppColor.divider).strokeWidth(0.5)
                    }
                  }, (item: TodayClass, index: number) => index.toString())
                }
                .width('100%')
              }
            }

            SectionCard({ title: '快捷入口', subtitle: '按最近使用排序' }) {
              Grid() {
                ForEach(quickFeatures(this.featureUsage), (item: FeatureItem) => {
                  GridItem() {
                    FeatureTile({
                      title: item.title,
                      icon: item.icon,
                      color: item.color,
                      onTileClick: () => {
                        this.openFeature(item);
                      }
                    })
                  }
                }, (item: FeatureItem) => item.title)
              }
              .columnsTemplate('1fr 1fr 1fr 1fr')
              .columnsGap(AppSize.gapSmall)
              .rowsGap(AppSize.gap)
              .width('100%')
            }
          }

          // 为悬浮底栏预留高度（barOverlap 模式下内容会被底栏覆盖）
          Blank()
            .height(AppSize.contentBottomInset)
        }
        .width('100%')
        .padding({
          left: AppSize.pagePadding,
          right: AppSize.pagePadding,
          // 顶部让开「状态栏 + 悬浮标题栏（MINI，56vp）」。状态栏那一段的模糊由
          // PageShell 的磨砂层补上，视口必须从屏幕顶开始（见 MainPage.PageShell）；
          // 留白只能写在这里，写到外壳上会把视口压低、内容就滑不进磨砂层了。
          top: AppSize.destTopInset(topSafeInsetVp()),
          bottom: 0
        })
        .constraintSize({ minHeight: '100%' })
      }
      .scrollBar(BarState.Off)
      // 顶/底拖到边界时回弹（内容不足一屏也生效）
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      // 沉浸光感「三件套」之二 / 之三（配合 titleBar 的 enableComponentSafeArea）：
      //   clip(false)      —— 允许内容画到自身布局矩形之外；
      //   expandSafeArea() —— 绘制区延伸进标题栏声明的组件安全区。
      // 缺了这两个，内容永远停在标题栏下沿（首屏位置是对的，但上滑时内容不会从
      // 标题栏底下钻进去），标题栏的渐变模糊「没东西可糊」。官方文档明确要求。
      .clip(false)
      .expandSafeArea()
      .width('100%')
      .height('100%')
      // 顶部留白不写在 Scroll 上 —— ArkUI 会把 Scroll 的 padding 当 contentInset，
      // 把滚动内容整体上移（实测反而顶到时钟上）；留白写在滚动内容的内边距里。
      .backgroundColor(AppColor.pageBackground)
    }
    // Refresh 也必须补「沉浸光感三件套」：它现在是最外层容器，若不开
    // clip(false)+expandSafeArea()，会默认避开 HDS 标题栏声明的组件安全区，
    // 把主页内容整体往下压、顶部渐变模糊失去可糊的内容（这是加下拉刷新后
    // 模糊丢失的直接原因）。
    .clip(false)
    .expandSafeArea()
    // 刷新态转圈位置：refreshOffset 越大转圈越靠上。按反馈微调。
    .refreshOffset(65)
    .onRefreshing(() => {
      this.refresh();
    })
    .width('100%')
    .height('100%')
  }
}
