import { AppColor, AppFont, AppSize } from './AppTheme';

/**
 * Split 双栏下「右栏栈空」时的占位内容。
 *
 * 注意：不在这里自绘标题栏 —— HdsNavDestination 自带标题栏且铺满整栏，
 * 内部再画一条会变成双标题栏（本项目踩过）。
 */
@Component
export struct WidePlaceholder {
  build() {
    Column({ space: AppSize.gap }) {
      Image($r('app.media.ic_apps'))
        .width(56)
        .height(56)
        .fillColor(AppColor.textTertiary)
      Text('从左侧选择一个功能')
        .fontSize(AppFont.subtitle)
        .fontColor(AppColor.textSecondary)
      Text('详情会显示在这里')
        .fontSize(AppFont.caption)
        .fontColor(AppColor.textTertiary)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(AppColor.pageBackground)
  }
}
