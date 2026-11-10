import { LoadState } from '../common/AppRouter';
import { CardCache, CardGrade } from '../common/CardCache';
import { GlobalContext } from '../common/GlobalContext';
import { GradeStatistics, calculateGradeStatistics, formatGradePoint, formatNumber } from '../common/GradeStats';
import { Logger } from '../common/Logger';
import { Toast } from '../common/Toast';
import { ApiError } from '../network/ApiError';
import { ApiService } from '../network/ApiService';
import { TokenStore } from '../network/TokenStore';
import { AppColor, AppFont, AppSize } from '../components/AppTheme';
import { topSafeInsetVp } from '../common/ImmersiveUtil';
import { ErrorView, LoadingView } from '../components/CommonViews';
import { GradeSummaryCard } from '../components/GradeSummaryCard';import { GradeHeaderModel } from '../components/GradeHeader';
import { Grade, GradeData, Term } from '../model/ApiTypes';

/**
 * 成绩查询。
 *
 * 版式对齐原版 UBAA 的成绩页（参考图 IMG_1668）：
 *   ① 顶栏：← **学期名（居中）** ‹ ›   —— ‹ › 切换上一/下一学期；
 *   ② 「全部成绩」卡：GPA / 加权平均分 / 算术平均分；
 *   ③ 「本学期」卡：课程数 / 总学分 + GPA / 加权平均分 / 算术平均分；
 *   ④ 课程卡：书图标 + 课程名 + 成绩徽章（★ 分数），下面列出学分 / 课程属性 / 成绩类型等。
 *
 * 统计口径（GPA 换算、加权平均分、算术平均分）**全部照抄原项目** `GradeScreen.kt`，
 * 见 `common/GradeStats.ets`。
 */
@Component
export struct GradePage {
  /** 顶栏共享模型（由 RouteBuilder 建好后传进来，与标题栏同一个实例）。 */
  header: GradeHeaderModel = new GradeHeaderModel();

  @State private loadState: LoadState = LoadState.LOADING;
  @State private errorMessage: string = '';
  /** 当前学期的成绩明细。 */
  @State private grades: Grade[] = [];
  /** 全部学期汇总（喂给「全部成绩」卡）。 */
  @State private allGrades: Grade[] = [];
  /** 「全部成绩」还在后台加载（显示「统计中」，与原版一致）。 */
  @State private summaryLoading: boolean = false;
  @State private termName: string = '';

  /** 各学期的成绩缓存（termCode → 该学期成绩），切学期时复用。 */
  private termGrades: Map<string, Grade[]> = new Map<string, Grade[]>();
  /** 后台补齐全学期成绩的开关，防止重复起。 */
  private allLoading: boolean = false;

  aboutToAppear(): void {
    // 顶栏箭头 → 切学期（回调挂在共享模型上，标题栏与页面拿到的是同一个实例）
    this.header.onPrevTerm = () => {
      this.switchTerm(-1);
    };
    this.header.onNextTerm = () => {
      this.switchTerm(1);
    };
    this.load();
  }

  /* ------------------------------ 数据 ------------------------------ */

  private async load(): Promise<void> {
    this.loadState = LoadState.LOADING;
    try {
      const terms: Term[] = await ApiService.fetchTerms();
      if (terms.length === 0) {
        this.loadState = LoadState.SUCCESS;
        this.header.terms = [];
        this.header.termIndex = -1;
        this.termName = '';
        this.header.termName = '成绩查询';
        return;
      }
      this.header.terms = terms;
      const index: number = this.pickTermIndex(terms);
      this.header.termIndex = index;
      this.applyTerm(terms[index]);
      await this.loadCurrentTerm();
      this.loadState = LoadState.SUCCESS;
      // 「全部成绩」要遍历所有学期 —— 放后台，不挡当前学期出内容
      this.loadAllTerms(terms);
    } catch (error) {
      this.errorMessage = error instanceof ApiError ?
        (error as ApiError).friendlyMessage() : '成绩加载失败';
      this.loadState = LoadState.ERROR;
      Logger.error('成绩加载失败：' + (error as Error).message);
    }
    this.pushToCards();
  }

  /** 选学期：优先本地记住的 → 上游标记 selected 的 → 第一个。 */
  private pickTermIndex(terms: Term[]): number {
    const remembered: string = TokenStore.getSelectedTerm()[0];
    for (let i = 0; i < terms.length; i++) {
      if (terms[i].itemCode === remembered) {
        return i;
      }
    }
    for (let i = 0; i < terms.length; i++) {
      if (terms[i].selected) {
        return i;
      }
    }
    return 0;
  }

  private applyTerm(term: Term): void {
    this.header.termCode = term.itemCode;
    this.header.termName = term.itemName;
    this.termName = term.itemName;
    TokenStore.setSelectedTerm(term.itemCode, term.itemName);
  }

  /** 拉当前学期的成绩。 */
  private async loadCurrentTerm(): Promise<void> {
    const termCode: string = this.header.termCode;
    if (termCode.length === 0) {
      return;
    }
    const cached: Grade[] | undefined = this.termGrades.get(termCode);
    if (cached !== undefined) {
      this.grades = cached;
      return;
    }
    const data: GradeData = await ApiService.fetchGrades(termCode);
    this.termGrades.set(termCode, data.grades);
    this.grades = data.grades;
  }

  /**
   * 后台把**所有**学期的成绩都拉一遍，汇总成「全部成绩」卡。
   *
   * 与原版一致：只统计**有成绩**的学期（成绩为空/学分为 0 的学期不参与统计）。
   * 逐个学期串行拉，避免一次性并发把上游打挂；每拉完一个就更新一次卡片。
   */
  private async loadAllTerms(terms: Term[]): Promise<void> {
    if (this.allLoading) {
      return;
    }
    this.allLoading = true;
    this.summaryLoading = true;
    try {
      for (let i = 0; i < terms.length; i++) {
        const termCode: string = terms[i].itemCode;
        if (this.termGrades.has(termCode)) {
          continue;
        }
        try {
          const data: GradeData = await ApiService.fetchGrades(termCode);
          this.termGrades.set(termCode, data.grades);
        } catch (error) {
          Logger.warn('汇总成绩：第' + terms[i].itemName + '拉取失败：' + (error as Error).message);
        }
        this.rebuildAllGrades();
      }
    } finally {
      this.allLoading = false;
      this.summaryLoading = false;
      this.rebuildAllGrades();
    }
  }

  /** 把各学期的成绩汇总（供「全部成绩」卡）。 */
  private rebuildAllGrades(): void {
    const merged: Grade[] = [];
    this.termGrades.forEach((value: Grade[]) => {
      for (let i = 0; i < value.length; i++) {
        merged.push(value[i]);
      }
    });
    this.allGrades = merged;
  }

  /** 切换学期（顶栏 ‹ ›）。 */
  private switchTerm(delta: number): void {
    const index: number = this.header.termIndex + delta;
    if (index < 0 || index >= this.header.terms.length) {
      return;
    }
    this.header.termIndex = index;
    this.applyTerm(this.header.terms[index]);
    this.loadCurrentTerm()
      .then(() => {
        this.pushToCards();
      })
      .catch((error: Error) => {
        Logger.warn('切换学期后拉取成绩失败：' + error.message);
      });
  }

  /**
   * 把本学期概览写进桌面卡片缓存（平均绩点 / 已修学分 / 最高分课程）。
   *
   * 与课表卡同样的道理：卡片进程不能联网，只能读主应用写好的快照（见 `CardCache`）。
   */
  private pushToCards(): void {
    try {
      const stats: GradeStatistics = calculateGradeStatistics(this.grades);
      // 最高分：按 XSZCJ（显示分数）取最大值，取不到数字就跳过
      let bestText: string = '';
      let bestScore: number = -1;
      for (let i = 0; i < this.grades.length; i++) {
        const item: Grade = this.grades[i];
        const value: number = parseFloat(this.score(item));
        if (Number.isNaN(value) || value <= bestScore) {
          continue;
        }
        bestScore = value;
        bestText = this.score(item) + ' · ' + this.courseName(item);
      }
      const snapshot: CardGrade = {
        termName: this.termName,
        gpa: stats.gpa !== null ? formatGradePoint(stats.gpa) : '—',
        credit: stats.totalCredits > 0 ? ('已修 ' + formatNumber(stats.totalCredits) + ' 学分') : '',
        bestText: bestText.length > 0 ? ('最高分 ' + bestText) : '',
        ready: true
      };
      Logger.info('写入成绩卡片：GPA ' + snapshot.gpa + ' · ' + snapshot.credit);
      CardCache.saveGrade(GlobalContext.getContext(), snapshot);
    } catch (error) {
      Logger.warn('写入成绩卡片缓存失败：' + (error as Error).message);
    }
  }

  /* ------------------------------ 取值 ------------------------------ */

  private courseName(item: Grade): string {
    if (item.KCM !== undefined && item.KCM.length > 0) {
      return item.KCM;
    }
    if (item.TDKCM !== undefined && item.TDKCM.length > 0) {
      return item.TDKCM;
    }
    return '未命名课程';
  }

  private score(item: Grade): string {
    if (item.XSZCJ !== undefined && item.XSZCJ.length > 0) {
      return item.XSZCJ;
    }
    return '--';
  }

  /** 课程号。 */
  private courseCode(item: Grade): string {
    if (item.KCH !== undefined && item.KCH.length > 0) {
      return item.KCH;
    }
    if (item.TDKCH !== undefined && item.TDKCH.length > 0) {
      return item.TDKCH;
    }
    return '';
  }

  /* ------------------------------ 概览数值 ------------------------------ */

  private gpaTextOf(grades: Grade[]): string {
    const stats: GradeStatistics = calculateGradeStatistics(grades);
    return stats.gpa === null ? '--' : formatGradePoint(stats.gpa);
  }

  private weightedTextOf(grades: Grade[]): string {
    const stats: GradeStatistics = calculateGradeStatistics(grades);
    return stats.weightedAverage === null ? '--' : formatNumber(stats.weightedAverage);
  }

  private arithmeticTextOf(grades: Grade[]): string {
    const stats: GradeStatistics = calculateGradeStatistics(grades);
    return stats.arithmeticAverage === null ? '--' : formatNumber(stats.arithmeticAverage);
  }

  private creditsTextOf(grades: Grade[]): string {
    const stats: GradeStatistics = calculateGradeStatistics(grades);
    return stats.totalCredits > 0 ? formatNumber(stats.totalCredits) : '--';
  }

  /* ------------------------------ 视图 ------------------------------ */

  /** 课程卡右上角的成绩徽章（★ + 分数）。 */
  @Builder
  gradeBadge(item: Grade) {
    Row({ space: 4 }) {
      SymbolGlyph($r('sys.symbol.star'))
        .fontSize(13)
        .fontColor([AppColor.textSecondary])
      Text(this.score(item))
        .fontSize(AppFont.body)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.textPrimary)
    }
    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
    .borderRadius(12)
    .backgroundColor(AppColor.surfaceSubtle)
  }

  /** 课程卡下面的一行明细（标签 + 值）。 */
  @Builder
  detailRow(label: string, value: string, withIcon: boolean) {
    if (value.length > 0) {
      Row({ space: 6 }) {
        if (withIcon) {
          SymbolGlyph($r('sys.symbol.person'))
            .fontSize(14)
            .fontColor([AppColor.textTertiary])
        }
        Text(label + '：')
          .fontSize(AppFont.body)
          .fontColor(AppColor.textSecondary)
        Text(value)
          .fontSize(AppFont.body)
          .fontColor(AppColor.textPrimary)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
  }

  /** 一门课的卡片。 */
  @Builder
  gradeCard(item: Grade) {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.book'))
          .fontSize(20)
          .fontColor([AppColor.brand])
        Text(this.courseName(item))
          .fontSize(AppFont.subtitle)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.textPrimary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        this.gradeBadge(item)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      this.detailRow('课程号', this.courseCode(item), false)
      this.detailRow('学分', item.XF !== undefined ? formatNumber(item.XF) : '', false)
      this.detailRow('课程属性', item.KCXZDM_DISPLAY !== undefined ? item.KCXZDM_DISPLAY : '', false)
      this.detailRow('课程类别', this.courseCategory(item), false)
      this.detailRow('考试性质', item.KSLXDM_DISPLAY !== undefined ? item.KSLXDM_DISPLAY : '', false)
      this.detailRow('考试类型', item.CXCKDM_DISPLAY !== undefined ? item.CXCKDM_DISPLAY : '', false)
      this.detailRow('成绩类型', item.CJRDFSDM_DISPLAY !== undefined ? item.CJRDFSDM_DISPLAY : '', true)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(AppSize.pagePadding)
    .borderRadius(AppSize.cardRadius)
    .border({ width: 1, color: AppColor.divider })
    .backgroundColor(AppColor.surface)
    .onClick(() => {
      const detail = '课程：' + this.courseName(item) +
        '\n成绩：' + this.score(item) +
        '\n学分：' + (item.XF !== undefined ? formatNumber(item.XF) : '—') +
        '\n课程属性：' + (item.KCXZDM_DISPLAY !== undefined ? item.KCXZDM_DISPLAY : '—');
      Toast.show(detail);
    })
  }

  /** 课程类别：优先 KCLBDM_DISPLAY，退回 XGXKLBDM_DISPLAY（与原版一致）。 */
  private courseCategory(item: Grade): string {
    if (item.KCLBDM_DISPLAY !== undefined && item.KCLBDM_DISPLAY.length > 0) {
      return item.KCLBDM_DISPLAY;
    }
    if (item.XGXKLBDM_DISPLAY !== undefined && item.XGXKLBDM_DISPLAY.length > 0) {
      return item.XGXKLBDM_DISPLAY;
    }
    return '';
  }

  build() {
    Scroll() {
      Column({ space: AppSize.gap }) {
        if (this.loadState === LoadState.LOADING) {
          LoadingView({ message: '正在获取成绩…' })
        } else if (this.loadState === LoadState.ERROR) {
          ErrorView({
            message: this.errorMessage,
            onRetry: () => {
              this.load();
            }
          })
        } else {
          // 全部成绩（跨学期汇总）
          GradeSummaryCard({
            title: '全部成绩',
            showCourseAndCredits: false,
            loading: this.summaryLoading,
            courseCountText: '',
            creditsText: '',
            gpaText: this.gpaTextOf(this.allGrades),
            weightedText: this.weightedTextOf(this.allGrades),
            arithmeticText: this.arithmeticTextOf(this.allGrades)
          })
          // 本学期
          GradeSummaryCard({
            title: '本学期',
            showCourseAndCredits: true,
            loading: false,
            courseCountText: calculateGradeStatistics(this.grades).courseCount.toString(),
            creditsText: this.creditsTextOf(this.grades),
            gpaText: this.gpaTextOf(this.grades),
            weightedText: this.weightedTextOf(this.grades),
            arithmeticText: this.arithmeticTextOf(this.grades)
          })

          if (this.grades.length === 0) {
            Text('暂无成绩')
              .fontSize(AppFont.body)
              .fontColor(AppColor.textTertiary)
              .padding({ top: AppSize.gapLarge, bottom: AppSize.gapLarge })
          } else {
            ForEach(this.grades, (item: Grade, index: number) => {
              this.gradeCard(item)
            }, (item: Grade, index: number) => this.courseKey(item) + '-' + index.toString())
          }
        }

        Blank()
          .height(AppSize.gapLarge)
      }
      .width('100%')
      .padding({
        left: AppSize.pagePadding,
        right: AppSize.pagePadding,
        // 顶部让开「状态栏 + 悬浮标题栏（MINI，56vp）」。留白必须写在滚动内容里、
        // 而不是 DestShell 外壳上：视口仍从屏幕顶开始，内容才能滑进标题栏 + 状态栏
        // 那一段毛玻璃底板（DestShell 用 backdropBlur 补的那层）。
        top: AppSize.destTopInset(topSafeInsetVp()),
        // 底部为悬浮底栏留白。必须留在滚动内容里，不能留给 destination ——
        // 否则底栏背后永远是一块实心底板，毛玻璃透不出内容，看着就是「黑遮罩」。
        bottom: AppSize.contentBottomInset
      })
      .constraintSize({ minHeight: '100%' })
    }
    .scrollBar(BarState.Off)
    // 顶/底拖到边界时回弹（内容不足一屏也生效）
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    // 沉浸光感「三件套」之二 / 之三（配合 titleBar 的 enableComponentSafeArea）：
    // clip(false) 允许内容画到布局矩形之外，expandSafeArea() 让绘制区延伸进
    // 标题栏声明的组件安全区 —— 缺了它们标题栏的渐变模糊就没东西可糊。
    .clip(false)
    .expandSafeArea()
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.pageBackground)
  }

  /** ForEach 的 key：课程号 + 名称 + 学分（同名同号课程要靠序号区分）。 */
  private courseKey(item: Grade): string {
    return this.courseCode(item) + '-' + this.courseName(item) + '-' +
      (item.XF !== undefined ? item.XF.toString() : '') + '-' +
      (item.XSZCJ !== undefined ? item.XSZCJ : '');
  }
}
