/**
 * 宽屏专用尺寸令牌。
 *
 * 与 AppTheme.AppSize 分开：AppSize 的既有常量是手机端逐像素实测值，
 * 一个都不能改（手机端零回归）；宽屏专属数值集中放这里，只被宽屏分支读取。
 */
export class WideLayoutTokens {
  /** md 档侧边导航宽度（只放图标）。 */
  static readonly sideNavWidthMd: number = 72;
  /** lg / xxl 档侧边导航宽度（图标 + 文字）。 */
  static readonly sideNavWidthLg: number = 240;

  /** Split 列表栏宽度范围。 */
  static readonly navBarMinWidth: number = 320;
  static readonly navBarMaxWidth: number = 400;
  /** Split 详情栏最小宽度，低于它系统会退回 Stack。 */
  static readonly minContentWidth: number = 360;

  /** 宽屏下二级页内容左右内边距。 */
  static readonly destSidePadding: number = 24;
  /** 宽屏下滚动内容左右内边距（AppSize.pagePadding 的宽屏值）。 */
  static readonly widePagePadding: number = 24;
  /** 宽屏下滚动内容底部留白（无悬浮底栏，不必留 104vp）。 */
  static readonly wideContentBottomInset: number = 24;
}
