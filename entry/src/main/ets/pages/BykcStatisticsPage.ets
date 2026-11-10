import { LoadState } from '../common/AppRouter';
import { Logger } from '../common/Logger';
import { ApiError } from '../network/ApiError';
import { ApiService } from '../network/ApiService';
import { AppColor, AppFont, AppSize } from '../components/AppTheme';
import { topSafeInsetVp } from '../common/ImmersiveUtil';
import { ErrorView, LoadingView } from '../components/CommonViews';
import { BykcCategoryStat } from '../model/ApiTypes';

/**
 * 博雅课程 · 课程统计（对齐原版 `BykcStatisticsScreen.kt`）。
 *
 * 版式与原版一致：
 * - 顶部一张**大数字卡**（紫底）：「总体净有效次数」+ 数字；
 * - 下面一张**分类统计表**：三列（课程小类 / 通过-指标 / 达标情况），
 *   达标显示「✓ 达标」，未达标显示「⚠ 未达标」。
 */
@Component
export struct BykcStatisticsPage {
  @State private loadState: LoadState = LoadState.LOADING;
  @State private errorMessage: string = '';
  @State private validCount: number = 0;
  @State private categories: BykcCategoryStat[] = [];

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.loadState = LoadState.LOADING;
    try {
      const stats = await ApiService.fetchBykcStatistics();
      this.validCount = stats.validCount;
      this.categories = stats.categories;
      this.loadState = LoadState.SUCCESS;
    } catch (error) {
      this.errorMessage = error instanceof ApiError ?
        (error as ApiError).friendlyMessage() : '课程统计加载失败';
      this.loadState = LoadState.ERROR;
      Logger.error('博雅统计加载失败：' + (error as Error).message);
    }
  }

  /** 这一类是否达标（通过数 ≥ 要求数）。 */
  private isQualified(item: BykcCategoryStat): boolean {
    return item.passed >= item.required;
  }

  build() {
    Scroll() {
      Column({ space: AppSize.gap }) {
        if (this.loadState === LoadState.LOADING) {
          LoadingView({ message: '正在获取课程统计…' })
        } else if (this.loadState === LoadState.ERROR) {
          ErrorView({
            message: this.errorMessage,
            onRetry: () => {
              this.load();
            }
          })
        } else {
          // 大数字卡（紫底）
          Column({ space: 4 }) {
            Text('总体净有效次数')
              .fontSize(AppFont.body)
              .fontColor('#FFFFFFFF')
              .opacity(0.9)
            Text(this.validCount.toString())
              .fontSize(44)
              .fontWeight(FontWeight.Bold)
              .fontColor(Color.White)
          }
          .width('100%')
          .padding({ top: 24, bottom: 24 })
          .borderRadius(16)
          .backgroundColor(AppColor.brand)
          .alignItems(HorizontalAlign.Center)

          // 分类统计表
          Column() {
            // 表头
            Row() {
              Text('课程小类')
                .fontSize(AppFont.caption)
                .fontWeight(FontWeight.Medium)
                .fontColor(AppColor.textPrimary)
                .layoutWeight(2)
              Text('通过/指标')
                .fontSize(AppFont.caption)
                .fontWeight(FontWeight.Medium)
                .fontColor(AppColor.textPrimary)
                .layoutWeight(1)
              Text('达标情况')
                .fontSize(AppFont.caption)
                .fontWeight(FontWeight.Medium)
                .fontColor(AppColor.textPrimary)
                .layoutWeight(1)
            }
            .width('100%')
            .padding({ top: 12, bottom: 12, left: 12, right: 12 })
            .backgroundColor(AppColor.surfaceSubtle)

            if (this.categories.length === 0) {
              Text('暂无统计数据')
                .fontSize(AppFont.caption)
                .fontColor(AppColor.textTertiary)
                .width('100%')
                .padding(20)
                .textAlign(TextAlign.Center)
            } else {
              ForEach(this.categories, (item: BykcCategoryStat, index: number) => {
                Row() {
                  Column({ space: 2 }) {
                    Text(item.subCategoryName)
                      .fontSize(AppFont.caption)
                      .fontWeight(FontWeight.Medium)
                      .fontColor(AppColor.textPrimary)
                      .maxLines(1)
                      .textOverflow({ overflow: TextOverflow.Ellipsis })
                    Text(item.categoryName)
                      .fontSize(10)
                      .fontColor(AppColor.textTertiary)
                      .maxLines(1)
                  }
                  .layoutWeight(2)
                  .alignItems(HorizontalAlign.Start)

                  Text(item.passed.toString() + ' / ' + item.required.toString())
                    .fontSize(AppFont.caption)
                    .fontColor(AppColor.textPrimary)
                    .layoutWeight(1)
                    .textAlign(TextAlign.Center)

                  Text(this.isQualified(item) ? '✓ 达标' : '⚠ 未达标')
                    .fontSize(AppFont.caption)
                    .fontColor(this.isQualified(item) ? AppColor.brand : AppColor.warning)
                    .layoutWeight(1)
                    .textAlign(TextAlign.End)
                }
                .width('100%')
                .padding({ top: 12, bottom: 12, left: 12, right: 12 })
                .backgroundColor(index % 2 === 0 ? AppColor.surface : AppColor.surfaceSubtle)
              }, (item: BykcCategoryStat) => item.categoryName + '-' + item.subCategoryName)
            }
          }
          .width('100%')
          .borderRadius(12)
          .backgroundColor(AppColor.surface)
          .clip(true)
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
