import { LoadState } from '../common/AppRouter';
import { CardCache, CardExam } from '../common/CardCache';
import { DateUtil } from '../common/DateUtil';
import { GlobalContext } from '../common/GlobalContext';
import { Logger } from '../common/Logger';
import { ApiError } from '../network/ApiError';
import { ApiService } from '../network/ApiService';
import { TokenStore } from '../network/TokenStore';
import { AppColor, AppFont, AppMaterial, AppSize } from '../components/AppTheme';
import { topSafeInsetVp } from '../common/ImmersiveUtil';
import { EmptyView, ErrorView, LoadingView, SectionCard } from '../components/CommonViews';
import { Exam, ExamArrangementData, Term } from '../model/ApiTypes';

/**
 * 考试安排。
 *
 * 分两段：已安排考试（按日期升序）与未安排考试。
 */
@Component
export struct ExamPage {
  @State private loadState: LoadState = LoadState.LOADING;
  @State private errorMessage: string = '';
  @State private arranged: Exam[] = [];
  @State private notArranged: Exam[] = [];
  @State private termName: string = '';
  /** 学期列表（右上角切换栏用）。 */
  @State private terms: Term[] = [];
  /** 当前选中的学期码（切换栏用，初始从 TokenStore 读）。 */
  @State private termCode: string = '';
  /** 右上角学期切换栏是否展开。 */
  @State private showTermPicker: boolean = false;

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.loadState = LoadState.LOADING;
    try {
      // 学期列表始终拉一次，供右上角切换栏显示全部可选学期
      const terms: Term[] = await ApiService.fetchTerms();
      this.terms = terms;
      let termCode = TokenStore.getSelectedTerm()[0];
      let name = TokenStore.getSelectedTerm()[1];
      if (termCode.length === 0 && terms.length > 0) {
        let picked: Term = terms[0];
        for (let i = 0; i < terms.length; i++) {
          if (terms[i].selected) {
            picked = terms[i];
            break;
          }
        }
        TokenStore.setSelectedTerm(picked.itemCode, picked.itemName);
        termCode = picked.itemCode;
        name = picked.itemName;
      }
      this.termCode = termCode;
      this.termName = name;

      if (termCode.length === 0) {
        this.loadState = LoadState.SUCCESS;
        return;
      }

      const data: ExamArrangementData = await ApiService.fetchExams(termCode);
      this.arranged = data.arranged;
      this.notArranged = data.notArranged;
      this.arranged.sort((a: Exam, b: Exam) => {
        return this.dateOf(a).localeCompare(this.dateOf(b));
      });
      this.loadState = LoadState.SUCCESS;
    } catch (error) {
      this.errorMessage = error instanceof ApiError ?
        (error as ApiError).friendlyMessage() : '考试信息加载失败';
      this.loadState = LoadState.ERROR;
      Logger.error('考试加载失败：' + (error as Error).message);
    }
    this.pushToCards();
  }

  /**
   * 选中某个学期：写回 TokenStore、收起切换栏、重新拉该学期考试。
   *
   * `manual` 场景下直接复用 `load` 的解析逻辑，只换 termCode 重新发请求。
   */
  private async applyTerm(term: Term): Promise<void> {
    this.termCode = term.itemCode;
    this.termName = term.itemName;
    TokenStore.setSelectedTerm(term.itemCode, term.itemName);
    this.showTermPicker = false;
    this.loadState = LoadState.LOADING;
    try {
      const data: ExamArrangementData = await ApiService.fetchExams(term.itemCode);
      this.arranged = data.arranged;
      this.notArranged = data.notArranged;
      this.arranged.sort((a: Exam, b: Exam) => {
        return this.dateOf(a).localeCompare(this.dateOf(b));
      });
      this.loadState = LoadState.SUCCESS;
    } catch (error) {
      this.errorMessage = error instanceof ApiError ?
        (error as ApiError).friendlyMessage() : '考试信息加载失败';
      this.loadState = LoadState.ERROR;
      Logger.error('切换学期后考试加载失败：' + (error as Error).message);
    }
    this.pushToCards();
  }

  /**
   * 把**最近一场考试**写进桌面卡片缓存。
   *
   * 与课表卡同样的道理：卡片进程活不过10 秒、不能联网，
   * 数据只能主应用拉完顺手写进共享沙箱（见 `CardCache` 的注释）。
   *
   * 只写「最近一场」—— 1×2 的窄卡塞不下更多，要看全部得点进 App。
   * 「今天已过期的考试」不写：倒计时是负数，卡片上出现「还剩 -2 天」比不显示更糟。
   */
  private pushToCards(): void {
    try {
      const now: Date = new Date();
      let pick: Exam | null = null;
      for (let i = 0; i < this.arranged.length; i++) {
        const item: Exam = this.arranged[i];
        const left: number | null = DateUtil.daysUntil(this.dateOf(item));
        if (left === null || left < 0) {
          continue;
        }
        if (pick === null || left < (DateUtil.daysUntil(this.dateOf(pick)) ?? 99999)) {
          pick = item;
        }
      }

      let snapshot: CardExam;
      if (pick === null) {
        // 「近期没有考试」也是一个有效状态：卡片据此显示空态而不是「打开 App」
        snapshot = {
          countdown: '',
          dateText: '',
          timeText: '',
          courseName: '',
          placeText: '',
          ready: true
        };
      } else {
        const exam: Exam = pick;
        const left: number = DateUtil.daysUntil(this.dateOf(exam)) ?? 0;
        const parts: string[] = [];
        if (exam.examPlace !== undefined && exam.examPlace.length > 0) {
          parts.push(exam.examPlace);
        }
        if (exam.examSeatNo !== undefined && exam.examSeatNo.length > 0) {
          parts.push('座位 ' + exam.examSeatNo);
        }
        snapshot = {
          countdown: DateUtil.countdownText(this.dateOf(exam)),
          dateText: this.dateOf(exam).length >= 10 ?
            (this.dateOf(exam).substring(5, 7) + '月' + this.dateOf(exam).substring(8, 10) + '日') :
            this.dateOf(exam),
          timeText: (exam.startTime === undefined ? '' : exam.startTime) +
            (exam.endTime === undefined || exam.endTime.length === 0 ? '' :
              (exam.startTime === undefined || exam.startTime.length === 0 ? '' : '~' + exam.endTime)),
          courseName: exam.courseName,
          placeText: parts.join(' · '),
          ready: true
        };
      }
      Logger.info('写入考试卡片：' + snapshot.countdown + ' ' + snapshot.courseName);
      CardCache.saveExam(GlobalContext.getContext(), snapshot);
    } catch (error) {
      Logger.warn('写入考试卡片缓存失败：' + (error as Error).message);
    }
  }

  private dateOf(exam: Exam): string {
    if (exam.examDate !== undefined && exam.examDate.length > 0) {
      return exam.examDate;
    }
    if (exam.examTimeDescription !== undefined) {
      return exam.examTimeDescription;
    }
    return '';
  }

  /**
   * 顶部右侧学期切换栏：左为页面标题、右为当前学期胶囊按钮。
   *
   * 点胶囊展开/收起下方竖向学期列表（`termPickerPanel`）。学期名过长时单行省略，
   * 不撑破布局。按钮复用课表页学期胶囊同款「半透明玻璃底 + 下拉箭头」观感。
   */
  @Builder
  examHeader() {
    Row() {
      // 页面标题由 HdsNavDestination 的标题栏提供，页内不再重复画「考试安排」
      Blank()
      Row({ space: 4 }) {
        Text(this.termName.length > 0 ? this.termName : '选择学期')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        SymbolGlyph($r('sys.symbol.chevron_down'))
          .fontSize(12)
          .fontColor([AppColor.textTertiary])
          .rotate({ angle: this.showTermPicker ? 180 : 0 })
      }
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .borderRadius(999)
      .backdropBlur(AppMaterial.blurSmall)
      .backgroundColor(AppColor.glassSurface)
      .onClick(() => {
        this.showTermPicker = !this.showTermPicker;
      })
    }
    .width('100%')
  }

  /**
   * 学期切换面板：竖向可滚动的学期列表（学期多到超出面板时上下滑动）。
   *
   * 用 `Scroll` + `maxHeight` 限制高度，超出即可滚；每项点击即切学期。
   * 选中项打勾，与课表页学期选择面板同一套视觉。
   */
  @Builder
  termPickerPanel() {
    Scroll() {
      Column({ space: AppSize.gap }) {
        ForEach(this.terms, (item: Term) => {
          Row() {
            Text(item.itemName)
              .fontSize(AppFont.body)
              .fontColor(AppColor.textPrimary)
              .layoutWeight(1)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (item.itemCode === this.termCode) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(18)
                .fontColor([AppColor.brand])
            }
          }
          .width('100%')
          .padding(AppSize.cardPadding)
          .borderRadius(AppSize.cardRadius)
          .backgroundColor(item.itemCode === this.termCode ? AppColor.brandContainerGlass : Color.Transparent)
          .onClick(() => {
            if (item.itemCode !== this.termCode) {
              this.applyTerm(item);
            } else {
              this.showTermPicker = false;
            }
          })
        }, (item: Term) => item.itemCode)
      }
      .width('100%')
      .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding, top: 8, bottom: 8 })
    }
    .scrollBar(BarState.Off)
    .width('100%')
    // 面板最高约 5 项高，超过就竖向滚动（满足「学期可上下滑动」）
    .constraintSize({ maxHeight: 280 })
    .backgroundColor(AppColor.glassSurface)
    .borderRadius(AppSize.cardRadius)
  }

  @Builder
  examItem(exam: Exam) {
    Row({ space: AppSize.gap }) {
      Column({ space: 2 }) {
        Text(DateUtil.countdownText(this.dateOf(exam)))
          .fontSize(AppFont.caption)
          .fontColor(AppColor.brand)
        Text(this.dateOf(exam).length > 0 ? this.dateOf(exam).substring(5) : '待定')
          .fontSize(10)
          .fontColor(AppColor.textTertiary)
      }
      .width(64)
      .alignItems(HorizontalAlign.Center)

      Column({ space: 4 }) {
        Text(exam.courseName)
          .fontSize(AppFont.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (exam.examPlace !== undefined && exam.examPlace.length > 0) {
          Text(exam.examPlace)
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        if (exam.examSeatNo !== undefined && exam.examSeatNo.length > 0) {
          Text('座位 ' + exam.examSeatNo)
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textTertiary)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
  }

  build() {
    Scroll() {
      Column({ space: AppSize.gapLarge }) {
        // 顶部右侧学期切换栏（常驻，可在加载/错误态也切换学期）
        this.examHeader()
        if (this.showTermPicker) {
          this.termPickerPanel()
        }

        if (this.loadState === LoadState.LOADING) {
          LoadingView({ message: '正在获取考试安排…' })
        } else if (this.loadState === LoadState.ERROR) {
          ErrorView({
            message: this.errorMessage,
            onRetry: () => {
              this.load();
            }
          })
        } else {
          SectionCard({
            title: '已安排考试',
            subtitle: this.termName.length > 0 ? this.termName : '本学期',
            showAction: false
          }) {
            if (this.arranged.length === 0) {
              EmptyView({ message: '暂无考试安排' })
            } else {
              Column() {
                ForEach(this.arranged, (item: Exam, index: number) => {
                  this.examItem(item)
                  if (index < this.arranged.length - 1) {
                    Divider().color(AppColor.divider).strokeWidth(0.5)
                  }
                }, (item: Exam, index: number) => index.toString())
              }
              .width('100%')
            }
          }

          if (this.notArranged.length > 0) {
            SectionCard({ title: '未安排考试', subtitle: '学校尚未排定时间', showAction: false }) {
              Column() {
                ForEach(this.notArranged, (item: Exam, index: number) => {
                  Text(item.courseName)
                    .fontSize(AppFont.body)
                    .fontColor(AppColor.textSecondary)
                    .width('100%')
                    .padding({ top: 6, bottom: 6 })
                  if (index < this.notArranged.length - 1) {
                    Divider().color(AppColor.divider).strokeWidth(0.5)
                  }
                }, (item: Exam, index: number) => index.toString())
              }
              .width('100%')
            }
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
}
