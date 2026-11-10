import { LoadState } from '../common/AppRouter';
import { Logger } from '../common/Logger';
import { Toast } from '../common/Toast';
import { ApiError } from '../network/ApiError';
import { ApiService } from '../network/ApiService';
import { AppColor, AppFont, AppSize } from '../components/AppTheme';
import { topSafeInsetVp } from '../common/ImmersiveUtil';
import { EmptyView, ErrorView, LoadingView } from '../components/CommonViews';
import { BykcChosenCourse } from '../model/ApiTypes';

/**
 * 博雅课程 · 我的课程（对齐原版 `BykcChosenCoursesScreen.kt`）。
 *
 * 卡片结构与原版一致：
 * - 课程名（粗）；
 * - 逐行「教师: / 地点: / 时间: / 退选截止:」；
 * - 分类胶囊；
 * - **底部一栏三块**：考勤状态 / 考核状态 / 分数。
 *
 * 写操作（选课 / 退选 / 签到 / 签退）**在详情页**做，这里只展示。
 */
@Component
export struct BykcChosenPage {
  @State private loadState: LoadState = LoadState.LOADING;
  @State private errorMessage: string = '';
  @State private chosen: BykcChosenCourse[] = [];

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.loadState = LoadState.LOADING;
    try {
      this.chosen = await ApiService.fetchBykcChosen();
      this.loadState = LoadState.SUCCESS;
    } catch (error) {
      this.errorMessage = error instanceof ApiError ?
        (error as ApiError).friendlyMessage() : '已选课程加载失败';
      this.loadState = LoadState.ERROR;
      Logger.error('博雅已选课程加载失败：' + (error as Error).message);
    }
  }

  /**
   * 考勤状态文案（对齐原版 `getCheckinStatus`）。
   *
   * `checkin` 的取值含义来自上游：0/null=待考勤，1=通过，2=迟到，3=早退，4=缺勤，
   * 5~11 是各种「签到/签退」组合（都算还没完成考勤）。
   */
  private checkinText(checkin: number): string {
    if (checkin === 1) {
      return '考勤通过';
    }
    if (checkin === 2) {
      return '迟到';
    }
    if (checkin === 3) {
      return '早退';
    }
    if (checkin === 4) {
      return '缺勤';
    }
    if (checkin === 5) {
      return '已签到、未签退';
    }
    if (checkin === 6) {
      return '已签到(异常)、未签退';
    }
    if (checkin === 7) {
      return '未签到、已签退';
    }
    if (checkin === 8) {
      return '未签到、已签退(异常)';
    }
    if (checkin === 9) {
      return '已签到(异常)、已签退';
    }
    if (checkin === 10) {
      return '已签到、已签退(异常)';
    }
    if (checkin === 11) {
      return '已签到(异常)、已签退(异常)';
    }
    return '待考勤';
  }

  /** 考勤状态配色：通过=品牌色，异常=危险色，其余=弱化色。 */
  private checkinColor(checkin: number): Resource {
    if (checkin === 1) {
      return AppColor.brand;
    }
    if (checkin >= 2 && checkin <= 4) {
      return AppColor.danger;
    }
    if (checkin >= 5 && checkin <= 11) {
      return AppColor.warning;
    }
    return AppColor.textTertiary;
  }

  /** 考核状态（`pass`：1=通过，0=未通过，null=待考核）。 */
  private passText(pass: number | undefined): string {
    if (pass === 1) {
      return '考核通过';
    }
    if (pass === 0) {
      return '考核未通过';
    }
    return '待考核';
  }

  private passColor(pass: number | undefined): Resource {
    if (pass === 1) {
      return AppColor.brand;
    }
    if (pass === 0) {
      return AppColor.danger;
    }
    return AppColor.textTertiary;
  }

  @Builder
  infoRow(label: string, value: string | undefined) {
    if (value !== undefined && value.length > 0) {
      Row({ space: 2 }) {
        Text(label + ': ')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textSecondary)
        Text(value)
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textPrimary)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
  }

  @Builder
  tag(text: string) {
    Text(text)
      .fontSize(11)
      .fontColor(AppColor.textSecondary)
      .padding({ left: 8, right: 8, top: 3, bottom: 3 })
      .borderRadius(4)
      .backgroundColor(AppColor.surfaceSubtle)
  }

  @Builder
  courseCard(item: BykcChosenCourse) {
    Column({ space: 6 }) {
      Text(item.courseName.length > 0 ? item.courseName : '未命名课程')
        .fontSize(AppFont.body)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.textPrimary)
        .width('100%')
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })

      this.infoRow('教师', item.teacher)
      this.infoRow('地点', item.position)
      this.infoRow('时间', this.rangeText(item.startDate, item.endDate))
      this.infoRow('退选截止', item.cancelEndDate)

      if (item.subCategory !== undefined && item.subCategory.length > 0) {
        Row({ space: 4 }) {
          this.tag(item.subCategory)
        }
        .width('100%')
      }

      Divider()
        .color(AppColor.divider)
        .strokeWidth(0.5)
        .margin({ top: 6, bottom: 6 })

      // 底部一栏三块：考勤 / 考核 / 分数
      Row({ space: 4 }) {
        Text('▤ ' + this.checkinText(item.checkin))
          .fontSize(AppFont.caption)
          .fontColor(this.checkinColor(item.checkin))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        Text(this.passIcon(item.pass) + ' ' + this.passText(item.pass))
          .fontSize(AppFont.caption)
          .fontColor(this.passColor(item.pass))
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })

        if (item.score !== undefined) {
          Text('★ ' + item.score.toString() + ' 分')
            .fontSize(AppFont.caption)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColor.brand)
            .layoutWeight(1)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
    }
    .width('100%')
    .padding(16)
    .borderRadius(12)
    .backgroundColor(AppColor.surface)
    .alignItems(HorizontalAlign.Start)
  }

  /** 考核通过是 ✓，未通过是 !，待考核是 ·。 */
  private passIcon(pass: number | undefined): string {
    if (pass === 1) {
      return '✓';
    }
    if (pass === 0) {
      return '!';
    }
    return '·';
  }

  private rangeText(start: string | undefined, end: string | undefined): string {
    const from: string = start === undefined ? '' : start;
    const to: string = end === undefined ? '' : end;
    if (from.length === 0 && to.length === 0) {
      return '';
    }
    if (from.length > 0 && to.length > 0) {
      return from + ' - ' + to;
    }
    return from.length > 0 ? from : to;
  }

  build() {
    Scroll() {
      Column({ space: AppSize.gap }) {
        if (this.loadState === LoadState.LOADING) {
          LoadingView({ message: '正在获取已选课程…' })
        } else if (this.loadState === LoadState.ERROR) {
          ErrorView({
            message: this.errorMessage,
            onRetry: () => {
              this.load();
            }
          })
        } else if (this.chosen.length === 0) {
          EmptyView({ message: '还没有选择博雅课程' })
        } else {
          ForEach(this.chosen, (item: BykcChosenCourse) => {
            this.courseCard(item)
          }, (item: BykcChosenCourse) => item.chosenId.toString())
        }

        Blank()
          .height(AppSize.gapLarge)
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
