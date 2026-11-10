import { AppColor, AppFont, AppSize } from './AppTheme';

/**
 * 成绩概览里的一格（数值 + 标签）。
 *
 * 必须做成 @Component（@Prop），不能再写成带参数的 @Builder：
 * @Builder 的普通参数按值传递、不参与状态刷新 —— 首帧算出的「统计中」会一直
 * 留在界面上，即使后台早已汇总完成（真机踩过：全部成绩永远显示「统计中」）。
 */
@Component
export struct SummaryValueCell {
  @Prop label: string = '';
  @Prop value: string = '';

  build() {
    Column({ space: 2 }) {
      Text(this.value)
        .fontSize(AppFont.titleLarge)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
      Text(this.label)
        .fontSize(AppFont.caption)
        .fontColor(AppColor.textSecondary)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }
}
/**
 * 成绩概览卡（全部成绩 / 本学期）。
 *
 * 数值全部以字符串传入（由页面按 GradeStats 的算法算好后格式化），组件只负责排版；
 * loading 为 true 时三个指标显示「统计中」（与原版一致）。
 */
@Component
export struct GradeSummaryCard {
  @Prop title: string = '';
  @Prop showCourseAndCredits: boolean = false;
  @Prop loading: boolean = false;
  @Prop courseCountText: string = '';
  @Prop creditsText: string = '';
  @Prop gpaText: string = '';
  @Prop weightedText: string = '';
  @Prop arithmeticText: string = '';

  build() {
    Column({ space: AppSize.gapSmall }) {
      Text(this.title)
        .fontSize(AppFont.subtitle)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.textPrimary)

      if (this.showCourseAndCredits) {
        Row() {
          SummaryValueCell({ label: '课程数', value: this.courseCountText })
            .layoutWeight(1)
          SummaryValueCell({ label: '总学分', value: this.creditsText })
            .layoutWeight(1)
        }
        .width('100%')
      }

      Row() {
        SummaryValueCell({ label: 'GPA', value: this.loading ? '统计中' : this.gpaText })
          .layoutWeight(1)
        SummaryValueCell({ label: '加权平均分', value: this.loading ? '统计中' : this.weightedText })
          .layoutWeight(1)
        SummaryValueCell({ label: '算数平均分', value: this.loading ? '统计中' : this.arithmeticText })
          .layoutWeight(1)
      }
      .width('100%')
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
    .padding(AppSize.pagePadding)
    .borderRadius(AppSize.cardRadius)
    .backgroundColor(AppColor.brandContainer)
  }
}
