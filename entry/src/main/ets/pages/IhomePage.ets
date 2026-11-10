import { AppRouter, LoadState, RouteName } from '../common/AppRouter';
import { IhomeNav } from '../common/IhomeNav';
import { Logger } from '../common/Logger';
import { Toast } from '../common/Toast';
import { ApiError } from '../network/ApiError';
import { ApiService } from '../network/ApiService';
import { AppColor, AppFont, AppSize } from '../components/AppTheme';
import { topSafeInsetVp } from '../common/ImmersiveUtil';
import { EmptyView, ErrorView, LoadingView } from '../components/CommonViews';
import {
  IhomeAppeal,
  IhomeCategory,
  IhomeEntry,
  IhomeFilter,
  IhomeNotice,
  IhomeScope
} from '../model/ApiTypes';

/**
 * iHome（接诉即办）。
 *
 * 五个视图与上游一致：诉求广场 / 我的发起 / 我的关注 / 我的评价 / 公告。
 * - 广场支持关键词搜索与分类筛选（搜索由上游执行，匹配正文与官方回复）；
 * - 我的发起额外支持按回复状态、回复时间筛选；
 * - 公告点开就地展开正文（纯文本，不执行上游脚本，也不还原表格 / 图片）。
 *
 * ⚠️ 写操作（关注 / 支持）在详情页，按「目标状态」提交，不在这里做。
 */
@Component
export struct IhomePage {
  stack: NavPathStack = new NavPathStack();

  @State private loadState: LoadState = LoadState.LOADING;
  @State private errorMessage: string = '';
  @State private scope: IhomeScope = IhomeScope.PUBLIC;
  @State private entries: IhomeEntry[] = [];
  @State private notices: IhomeNotice[] = [];
  @State private page: number = 1;
  @State private lastPage: number = 1;
  @State private total: number = 0;
  @State private keyword: string = '';
  @State private filter: IhomeFilter = IhomeFilter.ALL;
  @State private categoryId: number = 0;
  @State private categories: IhomeCategory[] = [];
  @State private loadingMore: boolean = false;
  @State private expandedNoticeId: number = 0;

  aboutToAppear(): void {
    this.loadConfig();
    this.load(true);
  }

  private async loadConfig(): Promise<void> {
    try {
      const config = await ApiService.fetchIhomeConfig();
      this.categories = config.categories;
    } catch (error) {
      // 分类字典取不到不影响列表，只是少一个筛选项
      Logger.warn('iHome 配置加载失败：' + (error as Error).message);
    }
  }

  private async load(reset: boolean): Promise<void> {
    if (this.scope === IhomeScope.NOTICE) {
      await this.loadNotices();
      return;
    }
    if (reset) {
      this.loadState = LoadState.LOADING;
      this.entries = [];
      this.page = 1;
    }
    try {
      const result = await ApiService.fetchIhomePage(
        this.scope, this.page, this.keyword, this.filter, this.categoryId);
      this.entries = reset ? result.entries : this.entries.concat(result.entries);
      this.page = result.page > 0 ? result.page : this.page;
      this.lastPage = result.lastPage > 0 ? result.lastPage : 1;
      this.total = result.total;
      this.loadState = LoadState.SUCCESS;
    } catch (error) {
      this.errorMessage = error instanceof ApiError
        ? (error as ApiError).friendlyMessage() : 'iHome 加载失败';
      this.loadState = LoadState.ERROR;
      Logger.error('iHome 加载失败：' + (error as Error).message);
    }
  }

  private async loadNotices(): Promise<void> {
    this.loadState = LoadState.LOADING;
    try {
      this.notices = await ApiService.fetchIhomeNotices();
      this.loadState = LoadState.SUCCESS;
    } catch (error) {
      this.errorMessage = error instanceof ApiError
        ? (error as ApiError).friendlyMessage() : '公告加载失败';
      this.loadState = LoadState.ERROR;
    }
  }

  private async loadMore(): Promise<void> {
    if (this.loadingMore || this.page >= this.lastPage) {
      return;
    }
    this.loadingMore = true;
    this.page = this.page + 1;
    try {
      const result = await ApiService.fetchIhomePage(
        this.scope, this.page, this.keyword, this.filter, this.categoryId);
      this.entries = this.entries.concat(result.entries);
      this.page = result.page > 0 ? result.page : this.page;
      this.lastPage = result.lastPage > 0 ? result.lastPage : this.page;
      this.total = result.total;
    } catch (error) {
      const message = error instanceof ApiError
        ? (error as ApiError).friendlyMessage() : '加载更多失败';
      Toast.show(message);
      this.page = this.page - 1;
    } finally {
      this.loadingMore = false;
    }
  }

  private switchScope(scope: IhomeScope): void {
    if (this.scope === scope) {
      return;
    }
    this.scope = scope;
    this.keyword = '';
    this.filter = IhomeFilter.ALL;
    this.categoryId = 0;
    this.expandedNoticeId = 0;
    this.load(true);
  }

  private switchFilter(filter: IhomeFilter): void {
    if (this.filter === filter) {
      return;
    }
    this.filter = filter;
    this.load(true);
  }

  private openDetail(entry: IhomeEntry): void {
    IhomeNav.set(entry.appeal.id, this.scope === IhomeScope.MINE || entry.appeal.isMine);
    AppRouter.push(this.stack, RouteName.IHOME_DETAIL);
  }

  private scopeLabel(scope: IhomeScope): string {
    if (scope === IhomeScope.MINE) {
      return '我的发起';
    }
    if (scope === IhomeScope.FOLLOWED) {
      return '我的关注';
    }
    if (scope === IhomeScope.APPRAISED) {
      return '我的评价';
    }
    if (scope === IhomeScope.NOTICE) {
      return '公告';
    }
    return '诉求广场';
  }

  /** 当前列表支持的筛选（与上游参数能力一一对应）。 */
  private filterOptions(): IhomeFilter[] {
    if (this.scope === IhomeScope.PUBLIC) {
      return [
        IhomeFilter.ALL, IhomeFilter.NEWEST, IhomeFilter.OLDEST,
        IhomeFilter.REPLIED, IhomeFilter.UNREPLIED
      ];
    }
    if (this.scope === IhomeScope.MINE) {
      return [
        IhomeFilter.ALL, IhomeFilter.NEWEST, IhomeFilter.REPLIED,
        IhomeFilter.UNREPLIED, IhomeFilter.REPLY_TIME
      ];
    }
    return [];
  }

  private filterLabel(filter: IhomeFilter): string {
    if (filter === IhomeFilter.NEWEST) {
      return '最新';
    }
    if (filter === IhomeFilter.OLDEST) {
      return '最早';
    }
    if (filter === IhomeFilter.REPLIED) {
      return '已回复';
    }
    if (filter === IhomeFilter.UNREPLIED) {
      return '未回复';
    }
    if (filter === IhomeFilter.REPLY_TIME) {
      return '按回复时间';
    }
    return '全部';
  }

  private categoryLabel(): string {
    if (this.categoryId === 0) {
      return '全部分类';
    }
    for (let i = 0; i < this.categories.length; i++) {
      if (this.categories[i].id === this.categoryId) {
        return this.categories[i].name;
      }
    }
    return '全部分类';
  }

  private categoryOptions(): SelectOption[] {
    const options: SelectOption[] = [{ value: '全部分类' }];
    for (let i = 0; i < this.categories.length; i++) {
      options.push({ value: this.categories[i].name });
    }
    return options;
  }

  private onCategorySelect(index: number): void {
    this.categoryId = index <= 0 ? 0 : this.categories[index - 1].id;
    this.load(true);
  }

  /* ------------------------------ 组件 ------------------------------ */

  @Builder
  scopeBar() {
    Scroll() {
      Row({ space: AppSize.gapSmall }) {
        ForEach([
          IhomeScope.PUBLIC, IhomeScope.MINE, IhomeScope.FOLLOWED,
          IhomeScope.APPRAISED, IhomeScope.NOTICE
        ], (item: IhomeScope) => {
          Text(this.scopeLabel(item))
            .fontSize(AppFont.caption)
            .fontColor(this.scope === item ? Color.White : AppColor.textSecondary)
            .padding({ left: 14, right: 14, top: 8, bottom: 8 })
            .backgroundColor(this.scope === item ? AppColor.brand : AppColor.surface)
            .borderRadius(999)
            .onClick(() => {
              this.switchScope(item);
            })
        }, (item: IhomeScope) => item)
      }
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
  }

  @Builder
  searchBar() {
    Column({ space: AppSize.gapSmall }) {
      Search({ value: this.keyword, placeholder: '搜索诉求内容 / 官方回复' })
        .width('100%')
        .height(36)
        .backgroundColor(AppColor.surfaceSubtle)
        .placeholderColor(AppColor.textTertiary)
        .textFont({ size: AppFont.body })
        .onChange((value: string) => {
          this.keyword = value;
        })
        .onSubmit(() => {
          this.load(true);
        })

      Row({ space: AppSize.gapSmall }) {
        Select(this.categoryOptions())
          .selected(this.categoryId === 0 ? 0 : this.indexOfCategory())
          .value(this.categoryLabel())
          .font({ size: AppFont.caption })
          .layoutWeight(1)
          .onSelect((index: number) => {
            this.onCategorySelect(index);
          })
        Text('搜索')
          .fontSize(AppFont.caption)
          .fontColor(Color.White)
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .backgroundColor(AppColor.brand)
          .borderRadius(999)
          .onClick(() => {
            this.load(true);
          })
      }
      .width('100%')
    }
    .width('100%')
  }

  private indexOfCategory(): number {
    for (let i = 0; i < this.categories.length; i++) {
      if (this.categories[i].id === this.categoryId) {
        return i + 1;
      }
    }
    return 0;
  }

  @Builder
  filterBar() {
    Scroll() {
      Row({ space: AppSize.gapSmall }) {
        ForEach(this.filterOptions(), (item: IhomeFilter) => {
          Text(this.filterLabel(item))
            .fontSize(AppFont.caption)
            .fontColor(this.filter === item ? AppColor.brand : AppColor.textSecondary)
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .backgroundColor(this.filter === item ? AppColor.brandContainer : AppColor.surfaceSubtle)
            .borderRadius(999)
            .onClick(() => {
              this.switchFilter(item);
            })
        }, (item: IhomeFilter) => item)
      }
    }
    .scrollable(ScrollDirection.Horizontal)
    .scrollBar(BarState.Off)
    .width('100%')
  }

  @Builder
  entryCard(entry: IhomeEntry) {
    Column({ space: 8 }) {
      Row({ space: AppSize.gapSmall }) {
        Text(entry.appeal.content)
          .fontSize(AppFont.body)
          .fontColor(AppColor.textPrimary)
          .maxLines(3)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(entry.appeal.status.length > 0 ? entry.appeal.status : '处理中')
          .fontSize(11)
          .fontColor(AppColor.brand)
          .padding({ left: 8, right: 8, top: 3, bottom: 3 })
          .borderRadius(6)
          .backgroundColor(AppColor.brandContainer)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      Row({ space: AppSize.gapSmall }) {
        if (entry.appeal.category.length > 0) {
          Text(entry.appeal.category)
            .fontSize(11)
            .fontColor(AppColor.textTertiary)
        }
        Text(entry.appeal.publishedAt)
          .fontSize(11)
          .fontColor(AppColor.textTertiary)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (entry.appeal.departments.length > 0) {
          Text(entry.appeal.departments.join('、'))
            .fontSize(11)
            .fontColor(AppColor.textTertiary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .constraintSize({ maxWidth: 140 })
        }
      }
      .width('100%')

      if (entry.evaluation !== undefined) {
        Row({ space: AppSize.gapSmall }) {
          Text('评价 ' + entry.evaluation.speed + '/' + entry.evaluation.satisfaction + '/' +
            entry.evaluation.degree)
            .fontSize(11)
            .fontColor(AppColor.textSecondary)
          Text('速度 / 满意度 / 解决程度')
            .fontSize(10)
            .fontColor(AppColor.textTertiary)
        }
        .width('100%')
      }

      Row({ space: AppSize.gap }) {
        if (entry.appeal.replies.length > 0) {
          Text('回复 ' + entry.appeal.replies.length)
            .fontSize(11)
            .fontColor(AppColor.textTertiary)
        }
        if (entry.appeal.followCount !== undefined) {
          Text('关注 ' + entry.appeal.followCount)
            .fontSize(11)
            .fontColor(AppColor.textTertiary)
        }
        if (entry.appeal.supportCount !== undefined) {
          Text('支持 ' + entry.appeal.supportCount)
            .fontSize(11)
            .fontColor(AppColor.textTertiary)
        }
      }
      .width('100%')
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.openDetail(entry);
    })
  }

  @Builder
  noticeRow(item: IhomeNotice) {
    Column({ space: 6 }) {
      Row({ space: AppSize.gapSmall }) {
        Text(item.title)
          .fontSize(AppFont.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text(item.date)
          .fontSize(11)
          .fontColor(AppColor.textTertiary)
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      if (this.expandedNoticeId === item.id) {
        Text(item.content.length > 0 ? item.content : '（无正文）')
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textSecondary)
          .width('100%')
          .padding({ top: 4 })
      }
    }
    .width('100%')
    .padding({ top: 12, bottom: 12 })
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.expandedNoticeId = this.expandedNoticeId === item.id ? 0 : item.id;
    })
  }

  @Builder
  footer() {
    if (this.scope !== IhomeScope.NOTICE && this.page < this.lastPage) {
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

  build() {
    Scroll() {
      Column({ space: AppSize.gap }) {
        this.scopeBar()

        if (this.scope === IhomeScope.PUBLIC) {
          this.searchBar()
        }

        if (this.loadState === LoadState.LOADING) {
          LoadingView({ message: '正在加载 iHome…' })
        } else if (this.loadState === LoadState.ERROR) {
          ErrorView({
            message: this.errorMessage,
            onRetry: () => {
              this.load(true);
            }
          })
        } else if (this.scope === IhomeScope.NOTICE) {
          if (this.notices.length === 0) {
            EmptyView({ message: '暂无公告' })
          } else {
            Column() {
              ForEach(this.notices, (item: IhomeNotice, index: number) => {
                this.noticeRow(item)
                if (index < this.notices.length - 1) {
                  Divider()
                    .color(AppColor.divider)
                    .strokeWidth(0.5)
                }
              }, (item: IhomeNotice) => item.id.toString())
            }
            .width('100%')
            .padding({ left: AppSize.cardPadding, right: AppSize.cardPadding })
            .borderRadius(AppSize.cardRadius)
            .backgroundColor(AppColor.surface)
          }
        } else {
          if (this.filterOptions().length > 0) {
            this.filterBar()
          }
          if (this.entries.length === 0) {
            EmptyView({ message: '暂无诉求' })
          } else {
            Column() {
              ForEach(this.entries, (item: IhomeEntry, index: number) => {
                this.entryCard(item)
                if (index < this.entries.length - 1) {
                  Divider()
                    .color(AppColor.divider)
                    .strokeWidth(0.5)
                }
              }, (item: IhomeEntry) => item.appeal.id.toString())
            }
            .width('100%')
            .padding({ left: AppSize.cardPadding, right: AppSize.cardPadding })
            .borderRadius(AppSize.cardRadius)
            .backgroundColor(AppColor.surface)
            this.footer()
          }
          Text('共 ' + this.total + ' 条诉求 · 第 ' + this.page + '/' + this.lastPage + ' 页')
            .fontSize(AppFont.caption)
            .fontColor(AppColor.textTertiary)
            .width('100%')
            .textAlign(TextAlign.Center)
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
