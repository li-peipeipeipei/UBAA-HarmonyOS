import { AppColor, AppFont, AppSize } from '../components/AppTheme';
import { topSafeInsetVp } from '../common/ImmersiveUtil';
import { AppRouter, RouteName } from '../common/AppRouter';

/**
 * 博雅课程 · 首页（对齐原版 `BykcHomeScreen.kt`）。
 *
 * 三个入口卡片：**选择课程 / 我的课程 / 课程统计**，
 * 与原版一样用 2×2 网格（第三个占左侧一格）。
 *
 * 原版首页不预加载数据（点击进子页时才拉），这里也保持一致 ——
 * 三个接口都走加密网关，一次并发三个请求慢且没必要。
 */
@Component
export struct BykcHomePage {
  /** 页签的导航栈 —— 三个入口各自 push 一个子页路由。 */
  stack: NavPathStack = new NavPathStack();

  build() {
    Scroll() {
      Column({ space: AppSize.gap }) {
        // 顶部说明卡（与原版首页一致：一句话说明这是什么）
        Column({ space: 6 }) {
          Text('博雅课程')
            .fontSize(AppFont.title)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColor.textPrimary)
          Text('选课、签到与学分统计都在这里')
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textSecondary)
        }
        .width('100%')
        .padding(AppSize.cardPadding)
        .borderRadius(AppSize.cardRadius)
        .backgroundColor(AppColor.surface)
        .alignItems(HorizontalAlign.Start)

        // 三个入口（原版是 2×2 网格，这里用 Row 套两行）
        Row({ space: AppSize.gap }) {
          this.entryCard('选择课程', '浏览可选博雅课程', 'list', 0)
          this.entryCard('我的课程', '查看已选/签到签退', 'bookmark', 0)
        }
        .width('100%')

        Row({ space: AppSize.gap }) {
          this.entryCard('课程统计', '查看学时统计', 'chart', 0)
          // 占位格，保持 2×2 布局（与原版一致）
          Blank()
            .layoutWeight(1)
        }
        .width('100%')

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

  /**
   * 一个入口卡片。
   *
   * 图标用**文字符号**而不是图片资源 —— 卡片里不能加载项目自带的 media 资源
   * （官方 FAQ：卡片不支持加载 media，强行加载得到 undefined 会 JS crash），
   * 而这几个符号用 `Text` 就能画出来，无需额外资源。
   */
  @Builder
  entryCard(title: string, subtitle: string, icon: string, key: number) {
    Column({ space: 8 }) {
      // 图标：菜单（默认）用三条实心圆角横杠手绘，几何居中；其余仍是符号字形
      Stack() {
        if (icon === 'list' || icon === 'menu') {
          Column({ space: 3 }) {
            Row()
              .width(16)
              .height(2.5)
              .borderRadius(1.25)
              .backgroundColor(AppColor.brand)
            Row()
              .width(16)
              .height(2.5)
              .borderRadius(1.25)
              .backgroundColor(AppColor.brand)
            Row()
              .width(16)
              .height(2.5)
              .borderRadius(1.25)
              .backgroundColor(AppColor.brand)
          }
        } else if (icon === 'bookmark') {
          // 手绘旗子：旗杆必须是竖直的（系统 flag 符号是斜杆/飘动状）
          Row() {
            Row()
              .width(2)
              .height(20)
              .borderRadius(1)
              .backgroundColor(AppColor.brand)

            Polygon({ width: 14, height: 10 })
              .points([[0, 0], [14, 5], [0, 10]])
              .fill(AppColor.brand)
              .margin({ left: 1 })
          }
          .height(20)
          .alignItems(VerticalAlign.Top)
        } else {
          Text(this.iconText(icon))
            .fontSize(26)
            .fontColor(AppColor.brand)
        }
      }
      .width(48)
      .height(48)
      .borderRadius(12)
      .backgroundColor(AppColor.brandContainer)
      .alignContent(Alignment.Center)
      Text(title)
        .fontSize(AppFont.body)
        .fontWeight(FontWeight.Medium)
        .fontColor(AppColor.textPrimary)
      Text(subtitle)
        .fontSize(AppFont.caption)
        .fontColor(AppColor.textSecondary)
        .maxLines(2)
        .textAlign(TextAlign.Center)
    }
    .layoutWeight(1)
    .padding(AppSize.cardPadding)
    .borderRadius(AppSize.cardRadius)
    .backgroundColor(AppColor.surface)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => {
      AppRouter.push(this.stack, this.routeOf(title));
    })
  }

  /** 图标符号（无资源依赖）。 */
  private iconText(icon: string): string {
    if (icon === 'bookmark') {
      return '⚑';
    }
    if (icon === 'chart') {
      return '▥';
    }
    return '☰';
  }

  private routeOf(title: string): string {
    if (title === '我的课程') {
      return RouteName.BYKC_CHOSEN;
    }
    if (title === '课程统计') {
      return RouteName.BYKC_STATISTICS;
    }
    return RouteName.BYKC_COURSES;
  }
}
