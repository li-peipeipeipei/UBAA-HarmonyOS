import { AppColor, AppFont, AppSize } from '../components/AppTheme';
import { topSafeInsetVp } from '../common/ImmersiveUtil';
import { AppRouter, RouteName } from '../common/AppRouter';

/**
 * 图书馆座位 · 首页（对齐原版 `LibBookHomeScreen.kt`）。
 *
 * 两个入口卡片：**预约座位 / 我的预约**。
 * 原版用 2 列网格，这里用 `Row` 套两卡（与博雅首页同一套做法）。
 */
@Component
export struct LibBookHomePage {
  /** 页签的导航栈。 */
  stack: NavPathStack = new NavPathStack();

  build() {
    Scroll() {
      Column({ space: AppSize.gap }) {
        // 顶部说明卡
        Column({ space: 6 }) {
          Text('图书馆座位')
            .fontSize(AppFont.title)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColor.textPrimary)
          Text('预约座位、查看我的预约')
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textSecondary)
        }
        .width('100%')
        .padding(AppSize.cardPadding)
        .borderRadius(AppSize.cardRadius)
        .backgroundColor(AppColor.surface)
        .alignItems(HorizontalAlign.Start)

        // 两个入口
        Row({ space: AppSize.gap }) {
          this.entryCard('预约座位', '选择楼馆、分区和座位', '▤', RouteName.LIBBOOK_RESERVE)
          this.entryCard('我的预约', '查看座位预约与取消', '◷', RouteName.LIBBOOK_BOOKINGS)
        }
        .width('100%')

        Blank()
          .height(AppSize.gapLarge)
      }
      .width('100%')
      .padding({
        left: AppSize.pagePadding,
        right: AppSize.pagePadding,
        // 顶部让开「状态栏 + 悬浮标题栏（MINI，56vp）」。留白必须写在滚动内容里、
        // 而不是外壳上：视口仍从屏幕顶开始，内容才能滑进标题栏那一段毛玻璃底板。
        top: AppSize.destTopInset(topSafeInsetVp()),
        // 底部为悬浮底栏留白，同样留在滚动内容里（见 RouteBuilder 的说明）。
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

  /**
   * 一个入口卡片。
   *
   * 图标用**文字符号**而不是图片资源 —— 卡片里不能加载项目自带的 media 资源
   * （官方 FAQ：卡片不支持加载 media，强行加载得到 undefined 会 JS crash）。
   */
  @Builder
  entryCard(title: string, subtitle: string, icon: string, route: string) {
    Column({ space: 8 }) {
      Text(icon)
        .fontSize(26)
        .fontColor(AppColor.brand)
        .width(48)
        .height(48)
        .textAlign(TextAlign.Center)
        .borderRadius(12)
        .backgroundColor(AppColor.brandContainer)
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
      AppRouter.push(this.stack, route);
    })
  }
}
