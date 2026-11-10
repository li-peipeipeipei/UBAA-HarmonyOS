import { AppRouter } from '../common/AppRouter';
import { Toast } from '../common/Toast';
import { AppColor, AppFont, AppSize } from '../components/AppTheme';
import { topSafeInsetVp } from '../common/ImmersiveUtil';
import { FeatureTile, SectionCard } from '../components/CommonViews';
import { FeatureItem, advancedFeatures, basicFeatures } from '../components/FeatureRegistry';

/**
 * 功能聚合页。
 *
 * 沿用 UBAA 的「普通功能 / 高级功能」两级分组，
 * 每个入口以网格磁贴呈现，图标与配色与 UBAA 保持一致。
 */
@Component
export struct FeaturePage {
  stack: NavPathStack = new NavPathStack();

  private open(item: FeatureItem): void {
    if (item.route.length === 0) {
      Toast.show(item.title + ' · 敬请期待');
      return;
    }
    AppRouter.push(this.stack, item.route);
  }

  @Builder
  featureGrid(items: FeatureItem[]) {
    Grid() {
      ForEach(items, (item: FeatureItem) => {
        GridItem() {
          FeatureTile({
            title: item.title,
            icon: item.icon,
            color: item.color,
            onTileClick: () => {
              this.open(item);
            }
          })
        }
      }, (item: FeatureItem) => item.title)
    }
    .columnsTemplate('1fr 1fr 1fr 1fr')
    .columnsGap(AppSize.gapSmall)
    .rowsGap(AppSize.gap)
    .width('100%')
  }

  build() {
    Scroll() {
      Column({ space: AppSize.gapLarge }) {
        SectionCard({ title: '普通功能', subtitle: '课业相关的高频服务' }) {
          this.featureGrid(basicFeatures())
        }

        SectionCard({ title: '高级功能', subtitle: '按需开放' }) {
          this.featureGrid(advancedFeatures())
        }

        Blank()
          .height(AppSize.contentBottomInset)
      }
      .width('100%')
      .padding({
        left: AppSize.pagePadding,
        right: AppSize.pagePadding,
        // 顶部让开「状态栏 + 悬浮标题栏（MINI，56vp）」。状态栏那一段的模糊由
        // PageShell 的磨砂层补上，视口必须从屏幕顶开始（见 MainPage.PageShell）；
        // 留白只能写在这里，写到外壳上会把视口压低、内容就滑不进磨砂层了。
        top: AppSize.destTopInset(topSafeInsetVp()),
        bottom: 0
      })
      .constraintSize({ minHeight: '100%' })
      // 一级页内容整体上移一点（纯视觉位移，见 AppSize.contentTopLift）
      .translate({ y: -AppSize.contentTopLift })
    }
    .scrollBar(BarState.Off)
    // 顶/底拖到边界时回弹（内容不足一屏也生效）
    .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
    // 沉浸光感「三件套」之二 / 之三（配合 titleBar 的 enableComponentSafeArea）：
    //   clip(false)      —— 允许内容画到自身布局矩形之外；
    //   expandSafeArea() —— 绘制区延伸进标题栏声明的组件安全区。
    // 缺了这两个，磁贴上滑时不会从标题栏底下钻进去，渐变模糊「没东西可糊」。
    .clip(false)
    .expandSafeArea()
    .width('100%')
    .height('100%')
    // 顶部留白不写在 Scroll 上 —— ArkUI 会把 Scroll 的 padding 当 contentInset，
    // 把滚动内容整体上移（实测反而顶到时钟上）；留白写在滚动内容的内边距里。
    .backgroundColor(AppColor.pageBackground)
  }
}
