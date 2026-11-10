import { LoadState } from '../common/AppRouter';
import { Logger } from '../common/Logger';
import { Toast } from '../common/Toast';
import { ApiError } from '../network/ApiError';
import { ApiService } from '../network/ApiService';
import { AppColor, AppFont, AppSize } from '../components/AppTheme';
import { topSafeInsetVp } from '../common/ImmersiveUtil';
import { selectMenuMaterial } from '../common/SystemMaterial';
import { EmptyView, ErrorView, LoadingView } from '../components/CommonViews';
import { YgdkClockinInput, YgdkItem, YgdkRecord, YgdkSummary } from '../model/ApiTypes';

const PAGE_SIZE: number = 20;

function emptySummary(): YgdkSummary {
  return { termCount: 0 };
}

/**
 * 阳光打卡页。
 *
 * 数据链路：oauth 跳转链取 code → 换 uid+token → 分类 / 项目 / 统计 → 打卡记录。
 * 全部逻辑在 `LocalYgdkService`（照抄原 UBAA 的 ygdk 模块）。
 *
 * ## 打卡（写操作）
 *
 * 两条路：
 * - **一键打卡**：入参全空，服务端（本地服务层）自动填写 —— 默认运动项目（名字含「跑」的）、
 *   当前时间往前 1 小时的时段、默认地点「操场」、1×1 透明占位图；
 * - **按上面的选项提交**：只覆盖运动项目 / 地点 / 是否分享，时段仍走自动
 *   （原版也只支持「同一天内 1 小时」，没有让人手填时段的入口）。
 *
 * ⚠️ 打卡是**真实写操作**，会在学校记录里生成一条。
 */
@Component
export struct YgdkPage {
  stack: NavPathStack = new NavPathStack();

  @State private loadState: LoadState = LoadState.LOADING;
  @State private errorMessage: string = '';
  @State private summary: YgdkSummary = emptySummary();
  @State private classifyName: string = '';
  @State private records: YgdkRecord[] = [];
  @State private total: number = 0;
  @State private loadingMore: boolean = false;
  /** 可选运动项目（来自概览）。 */
  @State private items: YgdkItem[] = [];
  @State private itemIndex: number = 0;
  @State private place: string = '';
  @State private shareToSquare: boolean = false;
  @State private submitting: boolean = false;
  /** 自动填写会用的时间段文案（展示用，与提交时用的是同一份）。 */
  @State private defaultTimeText: string = '';

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.loadState = LoadState.LOADING;
    try {
      const overview = await ApiService.fetchYgdkOverview();
      this.summary = overview.summary;
      this.classifyName = overview.classifyName;
      this.items = overview.items;
      this.defaultTimeText = overview.defaultTimeText;
      this.itemIndex = this.indexOfItem(overview.defaultItemId);
      if (this.place.length === 0) {
        this.place = '操场';
      }
      const page = await ApiService.fetchYgdkRecords(1, PAGE_SIZE);
      this.records = page.records;
      this.total = page.total;
      this.loadState = LoadState.SUCCESS;
    } catch (error) {
      this.errorMessage = error instanceof ApiError ?
        (error as ApiError).friendlyMessage() : '阳光打卡加载失败';
      this.loadState = LoadState.ERROR;
      Logger.error('阳光打卡加载失败：' + (error as Error).message);
    }
  }

  private indexOfItem(itemId: number): number {
    for (let i = 0; i < this.items.length; i++) {
      if (this.items[i].itemId === itemId) {
        return i;
      }
    }
    return 0;
  }

  /**
   * 提交打卡。
   *
   * @param auto true = 一键打卡（**入参全空**，项目 / 时段 / 地点 / 图片全部自动填写）；
   *             false = 用界面上选的运动项目、地点与分享开关。
   */
  private async doClockin(auto: boolean): Promise<void> {
    if (this.submitting) {
      return;
    }
    this.submitting = true;
    try {
      const input: YgdkClockinInput = auto ? {} : {
        itemId: this.items.length > 0 ? this.items[this.itemIndex].itemId : undefined,
        place: this.place,
        share: this.shareToSquare
      };
      const result = await ApiService.submitYgdkClockin(input);
      this.summary = result.summary;
      Toast.show('打卡成功');
      await this.load();
    } catch (error) {
      const message = error instanceof ApiError ?
        (error as ApiError).friendlyMessage() : '打卡失败';
      Toast.show(message);
      Logger.error('阳光打卡提交失败：' + (error as Error).message);
    } finally {
      this.submitting = false;
    }
  }

  /* ------------------------------ 打卡 ------------------------------ */

  private itemOptions(): SelectOption[] {
    const list: SelectOption[] = [];
    for (let i = 0; i < this.items.length; i++) {
      list.push({ value: this.items[i].name });
    }
    return list;
  }

  private itemLabel(): string {
    if (this.items.length === 0 || this.itemIndex >= this.items.length) {
      return '运动';
    }
    return this.items[this.itemIndex].name;
  }

  @Builder
  clockinCard() {
    Column({ space: AppSize.gap }) {
      Row() {
        Text('打卡')
          .fontSize(AppFont.subtitle)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .layoutWeight(1)
        Text('时段自动：' + this.defaultTimeText)
          .fontSize(11)
          .fontColor(AppColor.textTertiary)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Button(this.submitting ? '提交中…' : '一键打卡（自动填写）')
        .width('100%')
        .height(46)
        .fontSize(AppFont.body)
        .backgroundColor(AppColor.brand)
        .enabled(!this.submitting)
        .onClick(() => {
          this.doClockin(true);
        })

      Text('自动填写：运动项目取「跑步」，时段为当前时间往前 1 小时，地点「操场」，图片用占位图')
        .fontSize(11)
        .fontColor(AppColor.textTertiary)
        .width('100%')

      Row({ space: AppSize.gapSmall }) {
        Text('运动项目')
          .fontSize(AppFont.body)
          .fontColor(AppColor.textSecondary)
          .width(64)
        Select(this.itemOptions())
          .selected(this.itemIndex)
          .value(this.itemLabel())
          // 下拉菜单也走同一套沉浸光感（见 SystemMaterial.selectMenuMaterial）
          .menuSystemMaterial(selectMenuMaterial())
          .font({ size: AppFont.body })
          .layoutWeight(1)
          .onSelect((index: number) => {
            this.itemIndex = index;
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row({ space: AppSize.gapSmall }) {
        Text('地点')
          .fontSize(AppFont.body)
          .fontColor(AppColor.textSecondary)
          .width(64)
        TextInput({ text: this.place, placeholder: '操场' })
          .fontSize(AppFont.body)
          .layoutWeight(1)
          .onChange((value: string) => {
            this.place = value;
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Row({ space: AppSize.gapSmall }) {
        Text('分享到广场')
          .fontSize(AppFont.body)
          .fontColor(AppColor.textSecondary)
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.shareToSquare })
          .onChange((isOn: boolean) => {
            this.shareToSquare = isOn;
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      Button(this.submitting ? '提交中…' : '按上面的选项提交')
        .width('100%')
        .height(42)
        .fontSize(AppFont.body)
        .fontColor(AppColor.brand)
        .backgroundColor(AppColor.surfaceSubtle)
        .enabled(!this.submitting)
        .onClick(() => {
          this.doClockin(false);
        })
    }
    .width('100%')
    .padding(AppSize.cardPadding)
    .borderRadius(AppSize.cardRadius)
    .backgroundColor(AppColor.surface)
    .alignItems(HorizontalAlign.Start)
  }

  /** 追加下一页记录。 */
  private async loadMore(): Promise<void> {
    if (this.loadingMore) {
      return;
    }
    this.loadingMore = true;
    try {
      const nextPage: number = Math.floor(this.records.length / PAGE_SIZE) + 1;
      const page = await ApiService.fetchYgdkRecords(nextPage, PAGE_SIZE);
      const merged: YgdkRecord[] = this.records.slice();
      for (let i = 0; i < page.records.length; i++) {
        merged.push(page.records[i]);
      }
      this.records = merged;
      this.total = page.total;
    } catch (error) {
      const message = error instanceof ApiError ?
        (error as ApiError).friendlyMessage() : '加载更多失败';
      Toast.show(message);
    } finally {
      this.loadingMore = false;
    }
  }

  private hasMore(): boolean {
    return this.records.length < this.total;
  }

  /* ------------------------------ 概览 ------------------------------ */

  @Builder
  statCell(label: string, value: string) {
    Column({ space: 2 }) {
      Text(value)
        .fontSize(AppFont.title)
        .fontWeight(FontWeight.Bold)
        .fontColor(AppColor.textPrimary)
      Text(label)
        .fontSize(AppFont.caption)
        .fontColor(AppColor.textTertiary)
    }
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  overviewCard() {
    Column({ space: AppSize.gap }) {
      Row() {
        Text(this.classifyName.length > 0 ? this.classifyName : '阳光打卡')
          .fontSize(AppFont.subtitle)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .layoutWeight(1)
        if (this.summary.termName !== undefined && this.summary.termName.length > 0) {
          Text(this.summary.termName)
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textTertiary)
        }
      }
      .width('100%')

      Row() {
        this.statCell('学期有效', this.ratioText(this.summary.termCount, this.summary.termTarget))
        this.statCell('本周', this.ratioText(this.number(this.summary.weekCount),
          this.summary.weekTarget))
        this.statCell('本月', this.ratioText(this.number(this.summary.monthCount),
          this.summary.monthTarget))
      }
      .width('100%')

      Text('目标为学校要求次数（学期 / 周 / 月），显示为「已完成 / 目标」')
        .fontSize(11)
        .fontColor(AppColor.textTertiary)
        .width('100%')
    }
    .width('100%')
    .padding(AppSize.cardPadding)
    .borderRadius(AppSize.cardRadius)
    .backgroundColor(AppColor.surface)
    .alignItems(HorizontalAlign.Start)
  }

  private number(value: number | undefined): number {
    return value === undefined || value === null ? 0 : value;
  }

  private ratioText(count: number, target: number | undefined): string {
    if (target === undefined || target === null || target <= 0) {
      return count.toString();
    }
    return count.toString() + ' / ' + target.toString();
  }

  /* ------------------------------ 记录 ------------------------------ */

  @Builder
  recordItem(item: YgdkRecord) {
    Row({ space: AppSize.gap }) {
      Column() {
        Text(item.itemName !== undefined && item.itemName.length > 0 ? item.itemName : '运动')
          .fontSize(11)
          .fontColor(Color.White)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width(48)
      .height(36)
      .borderRadius(10)
      .backgroundColor(AppColor.accentPink)
      .justifyContent(FlexAlign.Center)

      Column({ space: 2 }) {
        Text(this.recordTime(item))
          .fontSize(AppFont.body)
          .fontColor(AppColor.textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (item.place !== undefined && item.place.length > 0) {
          Text(item.place)
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textTertiary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (item.isOpen) {
        Text('已分享')
          .fontSize(11)
          .fontColor(AppColor.brand)
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .borderRadius(6)
          .backgroundColor(AppColor.brandContainer)
      }
    }
    .width('100%')
    .padding({ top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Center)
  }

  private recordTime(item: YgdkRecord): string {
    const start: string = item.startTime === undefined ? '' : item.startTime;
    const end: string = item.endTime === undefined ? '' : item.endTime;
    if (start.length === 0 && end.length === 0) {
      return '时间未知';
    }
    // 同一天只显示后面的时间部分，更省横向空间
    if (start.length >= 16 && end.length >= 16 && start.substring(0, 10) === end.substring(0, 10)) {
      return start.substring(0, 10) + ' ' + start.substring(11) + '-' + end.substring(11);
    }
    return start + ' ~ ' + end;
  }

  /* ------------------------------ 主体 ------------------------------ */

  build() {
    Scroll() {
      Column({ space: AppSize.gap }) {
        if (this.loadState === LoadState.LOADING) {
          LoadingView({ message: '正在获取阳光打卡…' })
        } else if (this.loadState === LoadState.ERROR) {
          ErrorView({
            message: this.errorMessage,
            onRetry: () => {
              this.load();
            }
          })
        } else {
          this.clockinCard()
          this.overviewCard()

          Text('打卡记录' + (this.total > 0 ? '（共 ' + this.total.toString() + ' 条）' : ''))
            .fontSize(AppFont.body)
            .fontWeight(FontWeight.Medium)
            .fontColor(AppColor.textPrimary)
            .width('100%')

          if (this.records.length === 0) {
            EmptyView({ message: '还没有打卡记录' })
          } else {
            Column() {
              ForEach(this.records, (item: YgdkRecord, index: number) => {
                this.recordItem(item)
                if (index < this.records.length - 1) {
                  Divider().color(AppColor.divider).strokeWidth(0.5)
                }
              }, (item: YgdkRecord) => item.recordId.toString())
            }
            .width('100%')
            .padding({ left: AppSize.cardPadding, right: AppSize.cardPadding })
            .borderRadius(AppSize.cardRadius)
            .backgroundColor(AppColor.surface)

            if (this.hasMore()) {
              Button(this.loadingMore ? '加载中…' : '加载更多')
                .width('100%')
                .height(40)
                .fontSize(AppFont.body)
                .fontColor(AppColor.brand)
                .backgroundColor(AppColor.surfaceSubtle)
                .enabled(!this.loadingMore)
                .onClick(() => {
                  this.loadMore();
                })
            }
          }
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
