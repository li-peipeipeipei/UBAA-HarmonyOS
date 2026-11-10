import { LoadState } from '../common/AppRouter';
import { JudgeNav } from '../common/JudgeNav';
import { Logger } from '../common/Logger';
import { ApiError } from '../network/ApiError';
import { ApiService } from '../network/ApiService';
import { AppColor, AppFont, AppSize } from '../components/AppTheme';
import { topSafeInsetVp } from '../common/ImmersiveUtil';
import { ErrorView, LoadingView } from '../components/CommonViews';
import { JudgeAssignmentDetail, JudgeProblem, JudgeStatus } from '../model/ApiTypes';

/**
 * 希冀作业详情。
 *
 * 展示作业时间、满分 / 我的得分、逐题的提交状态与得分。入参来自 JudgeNav（见其注释）。
 * 详情接口本身也会把「题目表」解析好，所以这里不再做任何解析，只负责展示。
 */
@Component
export struct JudgeDetailPage {
  @State private loadState: LoadState = LoadState.LOADING;
  @State private errorMessage: string = '';
  @State private detail: JudgeAssignmentDetail | null = null;

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.loadState = LoadState.LOADING;
    try {
      this.detail = await ApiService.fetchJudgeDetail(JudgeNav.courseId, JudgeNav.assignmentId);
      this.loadState = LoadState.SUCCESS;
    } catch (error) {
      this.errorMessage = error instanceof ApiError
        ? (error as ApiError).friendlyMessage() : '希冀作业详情加载失败';
      this.loadState = LoadState.ERROR;
      Logger.error('希冀作业详情加载失败：' + (error as Error).message);
    }
  }

  private statusColor(status: JudgeStatus): Resource {
    if (status === JudgeStatus.SUBMITTED) {
      return AppColor.success;
    }
    if (status === JudgeStatus.PARTIAL) {
      return AppColor.warning;
    }
    if (status === JudgeStatus.UNSUBMITTED) {
      return AppColor.danger;
    }
    return AppColor.textTertiary;
  }

  private scoreText(): string {
    const detail = this.detail;
    if (detail === null) {
      return '—';
    }
    if (detail.myScore === undefined || detail.myScore.length === 0) {
      return '未出分';
    }
    if (detail.maxScore === undefined || detail.maxScore.length === 0) {
      return detail.myScore;
    }
    return detail.myScore + ' / ' + detail.maxScore;
  }

  private timeText(): string {
    const detail = this.detail;
    if (detail === null) {
      return '—';
    }
    const start = detail.startTime === undefined ? '' : detail.startTime;
    const due = detail.dueTime === undefined ? '' : detail.dueTime;
    if (start.length === 0 && due.length === 0) {
      return '—';
    }
    return (start.length > 0 ? start : '?') + ' 至 ' + (due.length > 0 ? due : '?');
  }

  @Builder
  metaRow(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(AppFont.caption)
        .fontColor(AppColor.textSecondary)
        .width(72)
      Text(value.length > 0 ? value : '—')
        .fontSize(AppFont.body)
        .fontColor(AppColor.textPrimary)
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .alignItems(VerticalAlign.Top)
    .padding({ top: 6, bottom: 6 })
  }

  @Builder
  headerCard() {
    Column({ space: 6 }) {
      Row({ space: AppSize.gapSmall }) {
        Text(this.detail === null ? JudgeNav.title : this.detail.title)
          .fontSize(AppFont.title)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.textPrimary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        if (this.detail !== null) {
          Text(this.detail.submissionStatusText)
            .fontSize(11)
            .fontColor(this.statusColor(this.detail.submissionStatus))
            .padding({ left: 8, right: 8, top: 3, bottom: 3 })
            .borderRadius(6)
            .backgroundColor(AppColor.surfaceSubtle)
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      if (this.detail !== null) {
        Text(this.detail.courseName)
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textSecondary)
          .width('100%')
      }
    }
    .width('100%')
    .padding(AppSize.cardPadding)
    .borderRadius(AppSize.cardRadius)
    .backgroundColor(AppColor.surface)
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  infoCard() {
    Column() {
      this.metaRow('作业时间', this.timeText())
      this.metaRow('得分', this.scoreText())
      if (this.detail !== null && this.detail.totalProblems > 0) {
        this.metaRow('完成题目', this.detail.submittedCount + ' / ' + this.detail.totalProblems)
      }
    }
    .width('100%')
    .padding(AppSize.cardPadding)
    .borderRadius(AppSize.cardRadius)
    .backgroundColor(AppColor.surface)
  }

  @Builder
  problemRow(item: JudgeProblem, index: number) {
    Row({ space: AppSize.gap }) {
      Text((index + 1).toString())
        .fontSize(AppFont.caption)
        .fontColor(AppColor.textTertiary)
        .width(20)
        .textAlign(TextAlign.Center)

      Column({ space: 3 }) {
        Text(item.name)
          .fontSize(AppFont.body)
          .fontColor(AppColor.textPrimary)
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Row({ space: AppSize.gapSmall }) {
          Text(item.statusText)
            .fontSize(11)
            .fontColor(this.statusColor(item.status))
          if (item.maxScore !== undefined && item.maxScore.length > 0) {
            Text('得分 ' + (item.score === undefined ? '—' : item.score) + '/' + item.maxScore)
              .fontSize(11)
              .fontColor(AppColor.textTertiary)
          }
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  problemsCard() {
    Column({ space: 4 }) {
      Text('题目')
        .fontSize(AppFont.subtitle)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.textPrimary)
        .width('100%')

      if (this.detail !== null && this.detail.problems.length > 0) {
        ForEach(this.detail.problems, (item: JudgeProblem, index: number) => {
          this.problemRow(item, index)
          if (index < (this.detail === null ? 0 : this.detail.problems.length - 1)) {
            Divider()
              .color(AppColor.divider)
              .strokeWidth(0.5)
          }
        }, (item: JudgeProblem, index: number) => item.name + '-' + index.toString())
      } else {
        Text('没有解析到题目列表，可在希冀网页查看题目明细。')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textTertiary)
          .width('100%')
          .padding({ top: 6, bottom: 6 })
      }
    }
    .width('100%')
    .padding(AppSize.cardPadding)
    .borderRadius(AppSize.cardRadius)
    .backgroundColor(AppColor.surface)
    .alignItems(HorizontalAlign.Start)
  }

  build() {
    Scroll() {
      Column({ space: AppSize.gap }) {
        if (this.loadState === LoadState.LOADING) {
          LoadingView({ message: '正在获取作业详情…' })
        } else if (this.loadState === LoadState.ERROR) {
          ErrorView({
            message: this.errorMessage,
            onRetry: () => {
              this.load();
            }
          })
        } else {
          this.headerCard()
          this.infoCard()
          this.problemsCard()
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
    .backgroundColor(AppColor.pageBackground)
  }
}
