import { LoadState } from '../common/AppRouter';
import { Logger } from '../common/Logger';
import { Toast } from '../common/Toast';
import { ApiError } from '../network/ApiError';
import { ApiService } from '../network/ApiService';
import { AppColor, AppFont, AppSize } from '../components/AppTheme';
import { topSafeInsetVp } from '../common/ImmersiveUtil';
import { EmptyView, ErrorView, LoadingView } from '../components/CommonViews';
import { EvaluationCourse, EvaluationProgress, EvaluationResult } from '../model/ApiTypes';

/**
 * 自动评教。
 *
 * 交互对齐原版：未评教课程**默认全选**，已评教课程的勾选框置灰并标「已评教」；
 * 点「一键评教」后逐门提交，顶部实时显示「正在评教 x/y」，结束后列出每门的结果。
 *
 * ⚠️ 评教是**不可撤销的写操作**：提交的是问卷的默认选项（每题第一项，随机一题
 * 选第二项以避免整卷雷同），因此按钮上必须写清楚后果，并给二次确认。
 */
@Component
export struct EvaluationPage {
  @State private loadState: LoadState = LoadState.LOADING;
  @State private errorMessage: string = '';
  @State private courses: EvaluationCourse[] = [];
  @State private progress: EvaluationProgress = {
    totalCourses: 0,
    evaluatedCourses: 0,
    pendingCourses: 0
  };
  /** 已勾选的课程 id。 */
  @State private selected: string[] = [];
  @State private submitting: boolean = false;
  @State private finishedCount: number = 0;
  @State private submitTotal: number = 0;
  @State private results: EvaluationResult[] = [];

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.loadState = LoadState.LOADING;
    try {
      const data = await ApiService.fetchEvaluations();
      this.courses = data.courses;
      this.progress = data.progress;
      this.selected = this.defaultSelection(data.courses);
      this.loadState = LoadState.SUCCESS;
    } catch (error) {
      this.errorMessage = error instanceof ApiError
        ? (error as ApiError).friendlyMessage() : '评教课程加载失败';
      this.loadState = LoadState.ERROR;
      Logger.error('评教课程加载失败：' + (error as Error).message);
    }
  }

  /** 未评教的默认全选，已评教的一律不选。 */
  private defaultSelection(courses: EvaluationCourse[]): string[] {
    const ids: string[] = [];
    for (let i = 0; i < courses.length; i++) {
      if (!courses[i].isEvaluated) {
        ids.push(courses[i].id);
      }
    }
    return ids;
  }

  private isSelected(id: string): boolean {
    return this.selected.indexOf(id) >= 0;
  }

  private toggle(course: EvaluationCourse): void {
    if (course.isEvaluated) {
      return;
    }
    const next: string[] = [];
    let removed = false;
    for (let i = 0; i < this.selected.length; i++) {
      if (this.selected[i] === course.id) {
        removed = true;
      } else {
        next.push(this.selected[i]);
      }
    }
    if (!removed) {
      next.push(course.id);
    }
    this.selected = next;
  }

  private selectedCourses(): EvaluationCourse[] {
    const out: EvaluationCourse[] = [];
    for (let i = 0; i < this.courses.length; i++) {
      if (this.isSelected(this.courses[i].id) && !this.courses[i].isEvaluated) {
        out.push(this.courses[i]);
      }
    }
    return out;
  }

  private requestSubmit(): void {
    if (this.submitting) {
      return;
    }
    const count = this.selectedCourses().length;
    if (count === 0) {
      Toast.show('请先勾选需要评教的课程');
      return;
    }
    AlertDialog.show({
      title: '确认一键评教',
      message: '将对已选的 ' + count + ' 门课程按问卷默认选项提交评教。' +
        '评教一经提交无法撤销，请确认无误。',
      autoCancel: true,
      primaryButton: {
        value: '取消',
        action: () => {
        }
      },
      secondaryButton: {
        value: '开始评教',
        fontColor: AppColor.danger,
        action: () => {
          this.doSubmit();
        }
      }
    });
  }

  /**
   * 逐门提交。
   *
   * 为什么要一门一门提交：上游一次提交多门时，中途失败无法定位是哪一门；
   * 逐门提交还能让进度条精确到「第几门」。
   */
  private async doSubmit(): Promise<void> {
    const targets = this.selectedCourses();
    if (targets.length === 0) {
      return;
    }
    this.submitting = true;
    this.results = [];
    this.finishedCount = 0;
    this.submitTotal = targets.length;

    const collected: EvaluationResult[] = [];
    for (let i = 0; i < targets.length; i++) {
      const result = await ApiService.submitEvaluation(targets[i]);
      collected.push(result);
      this.results = collected.slice();
      this.finishedCount = i + 1;
    }

    this.submitting = false;
    const successCount = this.countSuccess(collected);
    Toast.show('评教完成：成功 ' + successCount + ' 门，失败 ' +
      (collected.length - successCount) + ' 门');
    // 提交后重新拉一遍进度（已评教的会变成不可选）
    await this.load();
  }

  private countSuccess(results: EvaluationResult[]): number {
    let count = 0;
    for (let i = 0; i < results.length; i++) {
      if (results[i].success) {
        count++;
      }
    }
    return count;
  }

  /* ------------------------------ 组件 ------------------------------ */

  @Builder
  hintCard() {
    Column({ space: 6 }) {
      Text('勾选需要自动评教的课程，未评教的默认全选。')
        .fontSize(AppFont.body)
        .fontColor(AppColor.textPrimary)
        .width('100%')
      Text('评教按问卷默认选项自动填写并提交，提交后无法撤销；请确认无误再操作。')
        .fontSize(AppFont.caption)
        .fontColor(AppColor.textTertiary)
        .width('100%')
    }
    .width('100%')
    .padding(AppSize.cardPadding)
    .borderRadius(AppSize.cardRadius)
    .backgroundColor(AppColor.surface)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  progressCard() {
    Column({ space: 8 }) {
      Row() {
        Text(this.progress.pendingCourses === 0 && this.progress.totalCourses > 0
          ? '评教已完成' : '评教进度')
          .fontSize(AppFont.subtitle)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .layoutWeight(1)
        Text(this.progress.evaluatedCourses + ' / ' + this.progress.totalCourses)
          .fontSize(AppFont.subtitle)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.progress.pendingCourses === 0 ? AppColor.success : AppColor.brand)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Progress({
        value: this.progress.evaluatedCourses,
        total: this.progress.totalCourses > 0 ? this.progress.totalCourses : 1,
        type: ProgressType.Linear
      })
        .width('100%')
        .height(6)
        .color(this.progress.pendingCourses === 0 ? AppColor.success : AppColor.brand)
        .backgroundColor(AppColor.surfaceSubtle)

      Row() {
        Text('已完成 ' + this.progress.evaluatedCourses + ' 门')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.success)
          .layoutWeight(1)
        Text('待评教 ' + this.progress.pendingCourses + ' 门')
          .fontSize(AppFont.caption)
          .fontColor(this.progress.pendingCourses > 0 ? AppColor.danger : AppColor.textTertiary)
      }
      .width('100%')
    }
    .width('100%')
    .padding(AppSize.cardPadding)
    .borderRadius(AppSize.cardRadius)
    .backgroundColor(AppColor.surface)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  actionBar() {
    Row({ space: AppSize.gap }) {
      Column({ space: 2 }) {
        Text('已选 ' + this.selectedCourses().length + ' 门')
          .fontSize(AppFont.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
        Text('全选 / 取消可点上方课程')
          .fontSize(11)
          .fontColor(AppColor.textTertiary)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Button('一键评教')
        .height(40)
        .fontSize(AppFont.body)
        .fontColor(Color.White)
        .backgroundColor(AppColor.brand)
        .borderRadius(999)
        .padding({ left: 20, right: 20 })
        .enabled(!this.submitting && this.selectedCourses().length > 0)
        .onClick(() => {
          this.requestSubmit();
        })
    }
    .width('100%')
    .padding(AppSize.cardPadding)
    .borderRadius(AppSize.cardRadius)
    .backgroundColor(AppColor.surface)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  courseRow(course: EvaluationCourse) {
    Row({ space: AppSize.gap }) {
      if (course.isEvaluated) {
        SymbolGlyph($r('sys.symbol.checkmark_circle'))
          .fontSize(22)
          .fontColor([AppColor.success])
      } else {
        Checkbox({ name: course.id, group: 'evaluation' })
          .select(this.isSelected(course.id))
          .selectedColor(AppColor.brand)
          .onChange(() => {
            this.toggle(course);
          })
      }

      Column({ space: 3 }) {
        Text(course.kcmc)
          .fontSize(AppFont.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(course.isEvaluated ? AppColor.textTertiary : AppColor.textPrimary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text('教师：' + (course.bpmc.length > 0 ? course.bpmc : '未知'))
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textTertiary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (course.isEvaluated) {
        Text('已评教')
          .fontSize(11)
          .fontColor(AppColor.success)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(6)
          .backgroundColor(AppColor.surfaceSubtle)
      }
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
    .alignItems(VerticalAlign.Center)
    .opacity(course.isEvaluated ? 0.65 : 1)
  }

  @Builder
  resultCard() {
    Column({ space: 8 }) {
      Text('评教结果')
        .fontSize(AppFont.subtitle)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.textPrimary)
        .width('100%')

      ForEach(this.results, (item: EvaluationResult, index: number) => {
        Row({ space: AppSize.gapSmall }) {
          SymbolGlyph(item.success ? $r('sys.symbol.checkmark_circle') : $r('sys.symbol.exclamationmark_circle'))
            .fontSize(16)
            .fontColor([item.success ? AppColor.success : AppColor.danger])
          Column({ space: 2 }) {
            Text(item.courseName)
              .fontSize(AppFont.body)
              .fontColor(AppColor.textPrimary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            Text(item.message)
              .fontSize(AppFont.caption)
              .fontColor(AppColor.textTertiary)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)
        }
        .width('100%')
        .padding({ top: 4, bottom: 4 })
        .alignItems(VerticalAlign.Center)
      }, (item: EvaluationResult, index: number) => item.courseName + '-' + index.toString())

      Divider()
        .color(AppColor.divider)
        .strokeWidth(0.5)

      Text('成功 ' + this.countSuccess(this.results) + ' 门，失败 ' +
        (this.results.length - this.countSuccess(this.results)) + ' 门')
        .fontSize(AppFont.caption)
        .fontColor(AppColor.textSecondary)
        .width('100%')
    }
    .width('100%')
    .padding(AppSize.cardPadding)
    .borderRadius(AppSize.cardRadius)
    .backgroundColor(AppColor.surface)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  submitMask() {
    Column({ space: AppSize.gap }) {
      Text('正在评教 ' + this.finishedCount + ' / ' + this.submitTotal)
        .fontSize(AppFont.subtitle)
        .fontWeight(FontWeight.Bold)
        .fontColor(Color.White)
      Progress({
        value: this.finishedCount,
        total: this.submitTotal > 0 ? this.submitTotal : 1,
        type: ProgressType.Linear
      })
        .width(220)
        .height(8)
        .color(AppColor.brand)
        .backgroundColor('#40FFFFFF')
      Text('请勿关闭应用，稍候…')
        .fontSize(AppFont.caption)
        .fontColor('#CCFFFFFF')
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor('#99000000')
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      Scroll() {
        Column({ space: AppSize.gap }) {
          this.hintCard()

          if (this.loadState === LoadState.LOADING) {
            LoadingView({ message: '正在获取评教课程…' })
          } else if (this.loadState === LoadState.ERROR) {
            ErrorView({
              message: this.errorMessage,
              onRetry: () => {
                this.load();
              }
            })
          } else {
            if (this.progress.totalCourses > 0) {
              this.progressCard()
            }
            if (this.progress.totalCourses > 0) {
              this.actionBar()
            }
            if (this.results.length > 0) {
              this.resultCard()
            }

            if (this.courses.length === 0) {
              EmptyView({ message: '暂无评教课程' })
            } else {
              Column() {
                ForEach(this.courses, (item: EvaluationCourse, index: number) => {
                  this.courseRow(item)
                  if (index < this.courses.length - 1) {
                    Divider()
                      .color(AppColor.divider)
                      .strokeWidth(0.5)
                  }
                }, (item: EvaluationCourse) => item.id + '-' + item.isEvaluated.toString())
              }
              .width('100%')
              .padding({ left: AppSize.cardPadding, right: AppSize.cardPadding })
              .borderRadius(AppSize.cardRadius)
              .backgroundColor(AppColor.surface)
            }
          }

          Blank()
            .height(AppSize.contentBottomInset)
        }
        .width('100%')
        .padding({
          left: AppSize.pagePadding,
          right: AppSize.pagePadding,
          top: AppSize.destTopInset(topSafeInsetVp()),
          bottom: 0
        })
        .constraintSize({ minHeight: '100%' })
      }
      .scrollBar(BarState.Off)
      .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
      .clip(false)
      .expandSafeArea()
      .width('100%')
      .height('100%')

      if (this.submitting) {
        this.submitMask()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(AppColor.pageBackground)
  }
}
