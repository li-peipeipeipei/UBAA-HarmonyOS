import { AppRouter, LoadState, RouteName } from '../common/AppRouter';
import { JudgeNav } from '../common/JudgeNav';
import { Logger } from '../common/Logger';
import { Toast } from '../common/Toast';
import { ApiError } from '../network/ApiError';
import { ApiService } from '../network/ApiService';
import { AppColor, AppFont, AppSize } from '../components/AppTheme';
import { topSafeInsetVp } from '../common/ImmersiveUtil';
import { EmptyView, ErrorView, LoadingView } from '../components/CommonViews';
import { JudgeAssignmentSummary, JudgeStatus } from '../model/ApiTypes';

function pad2(value: number): string {
  return value < 10 ? '0' + value.toString() : value.toString();
}

/** 当前时间（与详情页里的时间字符串同格式，便于直接比较）。 */
function nowText(): string {
  const date = new Date();
  return date.getFullYear() + '-' + pad2(date.getMonth() + 1) + '-' + pad2(date.getDate()) +
    ' ' + pad2(date.getHours()) + ':' + pad2(date.getMinutes()) + ':' + pad2(date.getSeconds());
}

/**
 * 希冀作业列表。
 *
 * 交互对齐原版：默认只看「未完成」（未提交 / 进行中），可搜索，可切「显示已截止」
 * （切换会重新拉取——历史作业要靠上游的 includeExpired 模式才返回）；点某条进详情。
 *
 * ⚠️ 加载可能偏慢：希冀把「当前课程」存在服务端会话里，每门课都要先选课、再抓作业、
 * 再逐条抓详情，因此这里是**串行**请求（并发会互相把课程切走）。
 */
@Component
export struct JudgePage {
  stack: NavPathStack = new NavPathStack();

  @State private loadState: LoadState = LoadState.LOADING;
  @State private errorMessage: string = '';
  @State private assignments: JudgeAssignmentSummary[] = [];
  @State private visible: JudgeAssignmentSummary[] = [];
  @State private query: string = '';
  @State private onlyUnfinished: boolean = true;
  @State private includeExpired: boolean = false;
  @State private loadingHint: string = '正在获取希冀作业…';

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.loadState = LoadState.LOADING;
    this.loadingHint = this.includeExpired
      ? '正在获取全部作业（含已截止）…' : '正在获取希冀作业…';
    try {
      const response = await ApiService.fetchJudgeAssignments(this.includeExpired);
      this.assignments = response.assignments;
      this.rebuild();
      this.loadState = LoadState.SUCCESS;
    } catch (error) {
      this.errorMessage = error instanceof ApiError
        ? (error as ApiError).friendlyMessage() : '希冀作业加载失败';
      this.loadState = LoadState.ERROR;
      Logger.error('希冀作业加载失败：' + (error as Error).message);
    }
  }

  /** 按「只看未完成 + 关键词」过滤出可见列表。 */
  private rebuild(): void {
    const list: JudgeAssignmentSummary[] = [];
    const keyword = this.query.trim().toLowerCase();
    for (let i = 0; i < this.assignments.length; i++) {
      const item = this.assignments[i];
      if (this.onlyUnfinished && item.submissionStatus === JudgeStatus.SUBMITTED) {
        continue;
      }
      if (keyword.length > 0) {
        const haystack = (item.title + ' ' + item.courseName).toLowerCase();
        if (haystack.indexOf(keyword) < 0) {
          continue;
        }
      }
      list.push(item);
    }
    this.visible = list;
  }

  private unfinishedCount(): number {
    let count = 0;
    for (let i = 0; i < this.assignments.length; i++) {
      if (this.assignments[i].submissionStatus !== JudgeStatus.SUBMITTED) {
        count++;
      }
    }
    return count;
  }

  private toggleIncludeExpired(): void {
    this.includeExpired = !this.includeExpired;
    if (this.includeExpired) {
      this.onlyUnfinished = false;
    }
    this.load();
  }

  private openDetail(item: JudgeAssignmentSummary): void {
    JudgeNav.set(item.courseId, item.assignmentId, item.courseName, item.title);
    AppRouter.push(this.stack, RouteName.JUDGE_DETAIL);
  }

  private dueText(item: JudgeAssignmentSummary): string {
    if (item.dueTime === undefined || item.dueTime.length === 0) {
      return '截止时间待定';
    }
    return '截止 ' + item.dueTime;
  }

  private isOverdue(item: JudgeAssignmentSummary): boolean {
    if (item.dueTime === undefined || item.dueTime.length === 0) {
      return false;
    }
    return item.dueTime < nowText();
  }

  private statusColor(item: JudgeAssignmentSummary): Resource {
    if (item.submissionStatus === JudgeStatus.SUBMITTED) {
      return AppColor.success;
    }
    if (item.submissionStatus === JudgeStatus.PARTIAL) {
      return AppColor.warning;
    }
    return AppColor.danger;
  }

  /* ------------------------------ 组件 ------------------------------ */

  @Builder
  summaryBar() {
    Column({ space: 8 }) {
      Row() {
        Column({ space: 2 }) {
          Text('希冀作业')
            .fontSize(AppFont.subtitle)
            .fontWeight(FontWeight.Medium)
            .fontColor(AppColor.textPrimary)
          Text('共 ' + this.assignments.length + ' 条 · 未完成 ' + this.unfinishedCount() + ' 条')
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textTertiary)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Text('刷新')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.brand)
          .padding({ left: 14, right: 14, top: 6, bottom: 6 })
          .backgroundColor(AppColor.brandContainer)
          .borderRadius(999)
          .onClick(() => {
            this.load();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Search({ value: this.query, placeholder: '搜索作业名 / 课程名' })
        .width('100%')
        .height(36)
        .backgroundColor(AppColor.surfaceSubtle)
        .placeholderColor(AppColor.textTertiary)
        .textFont({ size: AppFont.body })
        .onChange((value: string) => {
          this.query = value;
          this.rebuild();
        })

      Row({ space: AppSize.gapSmall }) {
        this.filterChip('只看未完成', this.onlyUnfinished, () => {
          this.onlyUnfinished = !this.onlyUnfinished;
          this.rebuild();
        })
        this.filterChip(this.includeExpired ? '已含历史作业' : '显示已截止', this.includeExpired, () => {
          this.toggleIncludeExpired();
        })
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
  filterChip(label: string, active: boolean, onTap: () => void) {
    Text(label)
      .fontSize(AppFont.caption)
      .fontColor(active ? Color.White : AppColor.textSecondary)
      .padding({ left: 12, right: 12, top: 6, bottom: 6 })
      .backgroundColor(active ? AppColor.brand : AppColor.surfaceSubtle)
      .borderRadius(999)
      .onClick(() => {
        onTap();
      })
  }

  @Builder
  assignmentRow(item: JudgeAssignmentSummary) {
    Column({ space: 6 }) {
      Row({ space: AppSize.gapSmall }) {
        Text(item.title)
          .fontSize(AppFont.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)

        Text(item.submissionStatusText)
          .fontSize(11)
          .fontColor(this.statusColor(item))
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(6)
          .backgroundColor(AppColor.surfaceSubtle)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Row({ space: AppSize.gapSmall }) {
        Text(item.courseName)
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textSecondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(this.dueText(item))
          .fontSize(AppFont.caption)
          .fontColor(this.isOverdue(item) ? AppColor.danger : AppColor.textTertiary)
      }
      .width('100%')

      if (item.totalProblems > 0 || (item.myScore !== undefined && item.myScore.length > 0)) {
        Row({ space: AppSize.gapSmall }) {
          if (item.totalProblems > 0) {
            Text('题目 ' + item.submittedCount + '/' + item.totalProblems)
              .fontSize(11)
              .fontColor(AppColor.textTertiary)
          }
          if (item.myScore !== undefined && item.myScore.length > 0) {
            Text('得分 ' + item.myScore +
              (item.maxScore === undefined ? '' : ('/' + item.maxScore)))
              .fontSize(11)
              .fontColor(AppColor.textTertiary)
          }
        }
        .width('100%')
      }
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.openDetail(item);
    })
  }

  build() {
    Scroll() {
      Column({ space: AppSize.gap }) {
        this.summaryBar()

        if (this.loadState === LoadState.LOADING) {
          LoadingView({ message: this.loadingHint })
        } else if (this.loadState === LoadState.ERROR) {
          ErrorView({
            message: this.errorMessage,
            onRetry: () => {
              this.load();
            }
          })
        } else if (this.visible.length === 0) {
          EmptyView({
            message: this.assignments.length === 0
              ? '暂无希冀作业（可在上方打开「显示已截止」看历史作业）'
              : '没有符合筛选条件的作业'
          })
        } else {
          Column() {
            ForEach(this.visible, (item: JudgeAssignmentSummary, index: number) => {
              this.assignmentRow(item)
              if (index < this.visible.length - 1) {
                Divider()
                  .color(AppColor.divider)
                  .strokeWidth(0.5)
              }
            }, (item: JudgeAssignmentSummary) => item.courseId + '-' + item.assignmentId)
          }
          .width('100%')
          .padding({ left: AppSize.cardPadding, right: AppSize.cardPadding })
          .borderRadius(AppSize.cardRadius)
          .backgroundColor(AppColor.surface)
        }

        Text('希冀（judge.buaa.edu.cn）是网页系统，列表需要逐门选课后抓取，' +
          '首次加载可能较慢；已截止作业默认不展示。')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textTertiary)
          .width('100%')
          .padding({ left: 4, right: 4 })

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
