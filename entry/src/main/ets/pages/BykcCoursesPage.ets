import { AppRouter, LoadState, RouteName } from '../common/AppRouter';
import { Logger } from '../common/Logger';
import { Toast } from '../common/Toast';
import { ApiError } from '../network/ApiError';
import { ApiService } from '../network/ApiService';
import { AppColor, AppFont, AppMaterial, AppSize } from '../components/AppTheme';
import { MaterialCardLayer } from '../components/MaterialCardLayer';
import { immersiveMaterialActive } from '../common/SystemMaterial';
import curves from '@ohos.curves';
import { topSafeInsetVp } from '../common/ImmersiveUtil';
import { EmptyView, ErrorView, LoadingView } from '../components/CommonViews';
import { BykcCourse } from '../model/ApiTypes';
import { BykcNav } from '../components/BykcNav';
import {
  BykcFilters,
  BYKC_CATEGORY_ORDER,
  BYKC_STATUS_LABEL,
  BYKC_STATUS_ORDER,
  buildBykcFilterOptions,
  bykcIsDisplayedAsFull,
  bykcRequiresAllCourses,
  defaultBykcFilters,
  filterBykcCourses,
  toggleBykcCampus,
  toggleBykcCategory,
  toggleBykcStatus
} from '../common/BykcFilters';

const PAGE_SIZE: number = 20;

/**
 * 博雅课程 · 选择课程（对齐原版 `BykcCoursesScreen.kt`）。
 *
 * 顶部一行「课程筛选」入口（点开是**筛选面板**：状态 / 类别 / 校区三个维度多选，
 * 取交集），下面是课程列表（分页加载更多）。
 *
 * 卡片结构与原版一致：
 * - 首行：课程名（粗、两行）+ 右上角状态徽标；
 * - 逐行「教师: / 地点: / 时间: / 开始选课:」；
 * - 分类胶囊（+ 有签到点时加「自主签到」）；
 * - 报名进度条 + 「已报名 N / M」。
 */
/**
 * 单个筛选胶囊（独立组件）。
 *
 * ⚠️ 不能用带参 `@Builder` 渲染：`@Builder` 的参数是「值传递 + 不参与刷新」，
 * 选中态变化后胶囊不会重绘（列表内容却会变，看起来就是「点了没反馈」）。
 * 用 `@Component` + `@Prop selected` 才能跟着 `filters` 一起更新。
 */
@Component
struct BykcFilterChip {
  label: string = '';
  /** 打开面板时的初始选中态。 */
  initialSelected: boolean = false;
  /** 组件内部状态：点击后自己重绘，不依赖父级重建（父级被 bindSheet 缓存）。 */
  @State selected: boolean = false;
  onTap: () => void = () => {
  };

  aboutToAppear(): void {
    this.selected = this.initialSelected;
  }

  build() {
    Row() {
      // ✓ 常驻，只动画宽度 / 间距 / 透明度 —— 这样胶囊自身的宽度变化是连续的
      SymbolGlyph($r('sys.symbol.checkmark'))
        .fontSize(12)
        .fontColor([AppColor.brand])
        .width(this.selected ? 12 : 0)
        .height(12)
        .margin({ right: this.selected ? 4 : 0 })
        .opacity(this.selected ? 1 : 0)
      Text(this.label)
        .fontSize(AppFont.caption)
        .fontColor(this.selected ? AppColor.brand : AppColor.textSecondary)
    }
    .padding({ left: 10, right: 10, top: 6, bottom: 6 })
    .margin({ right: 8, bottom: 4 })
    .borderRadius(16)
    .backgroundColor(this.selected ? AppColor.brandContainerGlass : Color.Transparent)
    .border({
      width: 1,
      color: this.selected ? Color.Transparent : AppColor.divider
    })
    .onClick(() => {
      animateTo({ curve: curves.responsiveSpringMotion(0.25, 0.7) }, () => {
        this.selected = !this.selected;
      });
      this.onTap();
    })
  }
}

/**
 * 筛选面板内容（状态 / 类别 / 校区）。
 *
 * ⚠️ `@Link filters`：面板必须直接观察筛选状态。之前把面板写在页面的 `@Builder` 里，
 * 参数是值传递，`filters` 更新后胶囊不会重建 —— 表现为「内容变了、勾选不变、再点也取消不掉」。
 */
@Component
export struct BykcFilterPanel {
  /** 打开面板时的初始筛选条件（面板内部自己维护一份，保证能重建）。 */
  @Prop initialFilters: BykcFilters = defaultBykcFilters();
  /** 面板内部状态：胶囊选中态直接读它，切换后必然重建。 */
  @State filters: BykcFilters = defaultBykcFilters();
  /** 条件变化 → 通知页面同步列表。 */
  onChanged: (filters: BykcFilters) => void = () => {
  };
  /** 校区可选项（由页面按课程列表算好传进来）。 */
  campusOptions: string[] = [];
  onClose: () => void = () => {
  };
  private readonly materialActive: boolean = immersiveMaterialActive();

  aboutToAppear(): void {
    this.filters = this.initialFilters;
  }

  build() {
    Stack() {
      if (this.materialActive) {
        MaterialCardLayer({ layerRadius: AppSize.cardRadiusLarge })
      }

      Column() {
        // 标题行（与课程详情弹窗同一套尺寸）
        Row() {
          Text('筛选课程')
            .fontSize(AppFont.title)
            .fontWeight(FontWeight.Bold)
            .fontColor(AppColor.textPrimary)
            .maxLines(1)

          Stack() {
            if (this.materialActive) {
              MaterialCardLayer({ layerRadius: 20, layerShadow: false })
            } else {
              Column()
                .width('100%')
                .height('100%')
                .borderRadius(20)
                .backgroundColor(AppColor.circleButtonSurface)
            }
            Button({ type: ButtonType.Normal, stateEffect: false }) {
              SymbolGlyph($r('sys.symbol.xmark'))
                .fontSize(24)
                .fontColor([AppColor.textPrimary])
            }
            .width(40)
            .height(40)
            .borderRadius(20)
            .backgroundColor(Color.Transparent)
            .onClick(() => {
              this.onClose();
            })
          }
          .width(40)
          .height(40)
        }
        .width('100%')
        .justifyContent(FlexAlign.SpaceBetween)
        .alignItems(VerticalAlign.Center)
        .margin({ bottom: 8 })

        Divider()
          .color(AppColor.divider)
          .strokeWidth(0.5)

        // 分组区域：与课程详情弹窗一样限高滚动
        Scroll() {
          Column({ space: AppSize.gap }) {
            this.section('状态', '全部取消则表示状态不限', BYKC_STATUS_ORDER,
              this.filters.statuses, (status: string) => {
                this.filters = toggleBykcStatus(this.filters, status);
                this.onChanged(this.filters);
              }, (status: string) => BYKC_STATUS_LABEL[status])

            this.section('类别', '可任选多项', BYKC_CATEGORY_ORDER,
              this.filters.categories, (category: string) => {
                this.filters = toggleBykcCategory(this.filters, category);
                this.onChanged(this.filters);
              }, (category: string) => category)

            this.section('校区', '未指定即教师未设置开课地点所在校区', this.campusOptions,
              this.filters.campuses, (campus: string) => {
                this.filters = toggleBykcCampus(this.filters, campus);
                this.onChanged(this.filters);
              }, (campus: string) => campus)
          }
          .width('100%')
        }
        .width('100%')
        .scrollBar(BarState.Off)
        .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
        .constraintSize({ maxHeight: 380 })
        .margin({ top: 4 })

        // 完成按钮：与详情弹窗的「确定」同款材质 + 品牌蓝
        Stack() {
          if (this.materialActive) {
            MaterialCardLayer({ layerRadius: 22, layerShadow: false })
          }
          Button('完成')
            .width('100%')
            .height(44)
            .fontSize(AppFont.subtitle)
            .fontColor(AppColor.textOnBrand)
            .backgroundColor(this.materialActive ? AppColor.brandGlass : AppColor.brand)
            .onClick(() => {
              this.onClose();
            })
        }
        .width('100%')
        .height(44)
        .borderRadius(22)
        .margin({ top: 16 })
      }
      .width('100%')
      .padding(AppSize.cardPadding + 4)
      .alignItems(HorizontalAlign.Start)
    }
    .width('86%')
    .constraintSize({ maxWidth: 400 })
    .borderRadius(AppSize.cardRadiusLarge)
    .backgroundColor(Color.Transparent)
  }

  @Builder
  section(title: string, hint: string, options: string[], selected: string[],
    onToggle: (value: string) => void, labelOf: (value: string) => string) {
    Stack() {
      if (this.materialActive) {
        MaterialCardLayer({ layerRadius: AppSize.cardRadiusLarge, layerShadow: false })
      }

      Column({ space: 6 }) {
        // 不再显示说明文字（三行提示已去掉），标题略微右移与圆角对齐
        Text(title)
          .fontSize(AppFont.body)
          .fontWeight(FontWeight.Medium)
          .fontColor(AppColor.textPrimary)
          .padding({ left: 10 })

        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(options, (option: string) => {
            BykcFilterChip({
              label: labelOf(option),
              initialSelected: selected.indexOf(option) >= 0,
              onTap: () => {
                onToggle(option);
              }
            })
          }, (option: string) => title + '-' + option + (selected.indexOf(option) >= 0 ? '-on' : '-off'))
        }
        .width('100%')
      }
      .width('100%')
      .padding(10)      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .borderRadius(AppSize.cardRadiusLarge)
    .backgroundColor(this.materialActive ? Color.Transparent : AppColor.surface)
  }
}

@Component
export struct BykcCoursesPage {
  /** 页签的导航栈（由 RouteBuilder → DestShell 传入），用于跳详情页。 */
  stack: NavPathStack = new NavPathStack();
  @State private loadState: LoadState = LoadState.LOADING;
  @State private errorMessage: string = '';
  /** 拉回来的**原始**列表（筛选在本地做 —— 原版也是前端筛）。 */
  @State private allCourses: BykcCourse[] = [];
  @State private filters: BykcFilters = defaultBykcFilters();
  @State private totalPages: number = 1;
  @State private loadingMore: boolean = false;
  @State private filterPanelOpen: boolean = false;
  /** 宽屏分支（键名与 common/Breakpoint.ets 的 KEY_IS_WIDE_SCREEN 一致）。 */
  @StorageProp('isWideScreen') private isWide: boolean = false;

  /** 系统沉浸材质是否可用（不可用时退回玻璃底，保证观感不塌）。 */
  private readonly materialActive: boolean = immersiveMaterialActive();

  /**
   * 已经拉到第几页。
   *
   * ⚠️ **不能用「已显示条数 / 每页条数」反推**（本项目的老坑）：
   * 筛选后数组长度小于实际拉取条数，反推会算回同一页 → 「加载更多」出一堆重复课程。
   */
  private loadedPage: number = 1;

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.loadState = LoadState.LOADING;
    try {
      // 需要「已结束 / 已过期」时才把 includeExpired 打开（原版 requiresAllCourses）
      const all: boolean = bykcRequiresAllCourses(this.filters);
      const page = await ApiService.fetchBykcCourses(1, PAGE_SIZE, all);
      this.allCourses = page.courses;
      this.totalPages = page.totalPages;
      this.loadedPage = 1;
      this.loadState = LoadState.SUCCESS;
    } catch (error) {
      this.errorMessage = error instanceof ApiError ?
        (error as ApiError).friendlyMessage() : '博雅课程加载失败';
      this.loadState = LoadState.ERROR;
      Logger.error('博雅课程加载失败：' + (error as Error).message);
    }
  }

  private async loadMore(): Promise<void> {
    if (this.loadingMore) {
      return;
    }
    this.loadingMore = true;
    try {
      const nextPage: number = this.loadedPage + 1;
      const all: boolean = bykcRequiresAllCourses(this.filters);
      const page = await ApiService.fetchBykcCourses(nextPage, PAGE_SIZE, all);
      const merged: BykcCourse[] = this.allCourses.slice();
      for (let i = 0; i < page.courses.length; i++) {
        if (!this.containsCourse(merged, page.courses[i].id)) {
          merged.push(page.courses[i]);
        }
      }
      this.allCourses = merged;
      this.totalPages = page.totalPages;
      this.loadedPage = nextPage;
    } catch (error) {
      Toast.show(error instanceof ApiError ?
        (error as ApiError).friendlyMessage() : '加载更多失败');
    } finally {
      this.loadingMore = false;
    }
  }

  private containsCourse(list: BykcCourse[], courseId: number): boolean {
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === courseId) {
        return true;
      }
    }
    return false;
  }

  /** 筛选后的可见列表。 */
  private visibleCourses(): BykcCourse[] {
    return filterBykcCourses(this.allCourses, this.filters);
  }

  private hasMore(): boolean {
    return this.loadedPage < this.totalPages;
  }

  /** 可选校区列表（课程里出现过的 + 已选中的）。 */
  private campusOptions(): string[] {
    return buildBykcFilterOptions(this.allCourses, this.filters.campuses);
  }

  /**
   * 点课程 → **跳详情页**（原版就是独立详情页，不是弹窗）。
   *
   * 详情数据由详情页自己拉 —— 这里只把课程 id 传过去。
   */
  private openDetail(course: BykcCourse): void {
    // 写入共享模型 → 详情页从那里读 id（见 BykcNav 注释）
    BykcNav.shared.courseId = course.id;
    AppRouter.push(this.stack, RouteName.BYKC_DETAIL);
  }

  /* ------------------------------ 筛选面板 ------------------------------ */

  /**
   * 半模态筛选面板：头部在页面里画，内容交给 `BykcFilterPanel`。
   *
   * 面板内容必须是一个**独立组件**并 `@Link filters` —— 直接写在 `@Builder` 里的话，
   * 胶囊的选中态取的是构建时的值，`filters` 变了不会重建（列表会变、勾选不变）。
   */
  /** 筛选浮层：遮罩 + 底部固定面板（不走 bindSheet，避免上拖露底）。 */
  @Builder
  filterOverlay() {
    if (this.filterPanelOpen) {
      Stack({ alignContent: Alignment.Center }) {
        BykcFilterPanel({
          initialFilters: this.filters,
          campusOptions: this.campusOptions(),
          onChanged: (next: BykcFilters) => {
            this.filters = next;
          },
          onClose: () => {
            this.filterPanelOpen = false;
          }
        })
        // 手机端补偿回视觉正中；宽屏 Split 右栏不补偿
        .offset({ y: this.isWide ? 0 : -80 })
        // 与课程详情弹窗一致的出场方式：淡入 + 0.92 缩放，弹簧收尾
        .transition(
          TransitionEffect.OPACITY
            .combine(TransitionEffect.scale({ x: 0.92, y: 0.92 }))
            .animation({ curve: curves.responsiveSpringMotion(0.32, 0.88) })
        )
      }
      .width('100%')
      .height('100%')
      // 整屏遮罩 + 吞掉空白区的点击（不关闭面板，避免打开时的抬手误触）
      .backgroundColor('#66000000')
      .onClick(() => {
      })
    }
  }

  @Builder
  filterSheet() {
    BykcFilterPanel({
      initialFilters: this.filters,
      campusOptions: this.campusOptions(),
      onChanged: (next: BykcFilters) => {
        this.filters = next;
      },
      onClose: () => {
        this.filterPanelOpen = false;
      }
    })
  }

  /* ------------------------------ 课程卡片 ------------------------------ */

  /** 状态徽标的配色（与原版 `CourseStatusChip` 一致）。 */
  private statusChipColor(course: BykcCourse): Resource {
    if (course.selected) {
      return AppColor.brand;
    }
    if (course.status === 'AVAILABLE' && !bykcIsDisplayedAsFull(course)) {
      return AppColor.success;
    }
    if (course.status === 'FULL' || course.status === 'ENDED' || course.status === 'EXPIRED') {
      return AppColor.danger;
    }
    return AppColor.textTertiary;
  }

  @Builder
  courseCard(item: BykcCourse) {
    Column({ space: 8 }) {
      // 课程名 + 状态徽标
      Row({ space: 8 }) {
        Text(item.courseName.length > 0 ? item.courseName : '未命名课程')
          .fontSize(AppFont.body)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.textPrimary)
          .layoutWeight(1)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(item.selected ? '✓ 已选' : BYKC_STATUS_LABEL[item.status])
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textOnBrand)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .borderRadius(12)
          .backgroundColor(this.statusChipColor(item))
      }
      .width('100%')
      .alignItems(VerticalAlign.Top)

      // 教师 / 地点 / 时间 / 开始选课
      this.infoRow('教师', item.teacher)
      this.infoRow('地点', item.position)
      this.infoRow('时间', this.rangeText(item.startDate, item.endDate))
      this.infoRow('开始选课', this.rangeText(item.selectStartDate, item.selectEndDate))

      // 分类胶囊
      if (item.subCategory !== undefined && item.subCategory.length > 0) {
        Row({ space: 4 }) {
          this.tag(item.subCategory)
          if (item.hasSignPoints) {
            this.tag('自主签到')
          }
        }
        .width('100%')
      }

      // 报名进度条
      Column({ space: 4 }) {
        Progress({
          value: this.progressOf(item),
          total: 1,
          type: ProgressType.Linear
        })
          .width('100%')
          .height(4)
          .color(AppColor.brand)
          .backgroundColor(AppColor.surfaceSubtle)
        Text(item.currentCount === undefined ?
          ('人数上限 ' + item.maxCount.toString()) :
          ('已报名 ' + item.currentCount.toString() + ' / ' + item.maxCount.toString()))
          .fontSize(AppFont.caption)
          .fontColor(AppColor.textSecondary)
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)

    }
    .width('100%')
    .padding(16)
    .borderRadius(12)
    .backgroundColor(AppColor.surface)
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.openDetail(item);
    })
  }

  /** 报名进度（0~1）。 */
  private progressOf(item: BykcCourse): number {
    if (item.currentCount === undefined || item.maxCount <= 0) {
      return 0;
    }
    const p: number = item.currentCount / item.maxCount;
    return p > 1 ? 1 : (p < 0 ? 0 : p);
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
    Stack({ alignContent: Alignment.Center }) {
    Scroll() {
      Column({ space: AppSize.gap }) {
        if (this.loadState === LoadState.LOADING) {
          LoadingView({ message: '正在获取博雅课程…' })
        } else if (this.loadState === LoadState.ERROR) {
          ErrorView({
            message: this.errorMessage,
            onRetry: () => {
              this.load();
            }
          })
        } else {
          // 筛选入口（原版顶部那张「筛选课程」卡）
          Row({ space: 12 }) {
            Text('☰')
              .fontSize(20)
              .fontColor(AppColor.brand)
              .width(40)
              .height(40)
              .textAlign(TextAlign.Center)
              .borderRadius(12)
              .backgroundColor(AppColor.brandContainer)
            Column({ space: 2 }) {
              Text('筛选课程')
                .fontSize(AppFont.body)
                .fontWeight(FontWeight.Medium)
                .fontColor(AppColor.textPrimary)
              Text('多选后按状态、类别、校区交叉过滤')
                .fontSize(AppFont.caption)
                .fontColor(AppColor.textSecondary)
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .padding(12)
          .borderRadius(16)
          .backgroundColor(AppColor.surface)
          .onClick(() => {
            this.filterPanelOpen = true;
          })

          // 已选条件摘要：与筛选弹窗里的胶囊同款（同尺寸、同交互，点一下即取消该条件）
          if (this.filters.statuses.length > 0 || this.filters.categories.length > 0 || this.filters.campuses.length > 0) {
            // 一行放不下时横向滚动，不再换行堆叠
            Scroll() {
              Row() {
              ForEach(this.filters.statuses, (status: string) => {
                BykcFilterChip({
                  label: BYKC_STATUS_LABEL[status],
                  initialSelected: true,
                  onTap: () => {
                    animateTo({ curve: curves.responsiveSpringMotion(0.25, 0.7) }, () => {
                      this.filters = toggleBykcStatus(this.filters, status);
                    });
                  }
                })
              }, (status: string) => 's-' + status)
              ForEach(this.filters.categories, (category: string) => {
                BykcFilterChip({
                  label: category,
                  initialSelected: true,
                  onTap: () => {
                    animateTo({ curve: curves.responsiveSpringMotion(0.25, 0.7) }, () => {
                      this.filters = toggleBykcCategory(this.filters, category);
                    });
                  }
                })
                .transition(
                  TransitionEffect.OPACITY
                    .combine(TransitionEffect.scale({ x: 0.85, y: 0.85 }))
                    .animation({ curve: curves.responsiveSpringMotion(0.25, 0.7) })
                )
              }, (category: string) => 'c-' + category)
              ForEach(this.filters.campuses, (campus: string) => {
                BykcFilterChip({
                  label: campus,
                  initialSelected: true,
                  onTap: () => {
                    animateTo({ curve: curves.responsiveSpringMotion(0.25, 0.7) }, () => {
                      this.filters = toggleBykcCampus(this.filters, campus);
                    });
                  }
                })
                .transition(
                  TransitionEffect.OPACITY
                    .combine(TransitionEffect.scale({ x: 0.85, y: 0.85 }))
                    .animation({ curve: curves.responsiveSpringMotion(0.25, 0.7) })
                )
              }, (campus: string) => 'p-' + campus)
              }
              .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
              // 宽度随内容（不写 100%），超出视口才能横向滚动
            }
            .width('100%')
            // 抵消页面左右内边距：胶囊可以直接滑到屏幕边缘
            .margin({ left: -AppSize.pagePadding, right: -AppSize.pagePadding })
            .scrollable(ScrollDirection.Horizontal)
            .scrollBar(BarState.Off)
            .edgeEffect(EdgeEffect.Spring, { alwaysEnabled: true })
            .align(Alignment.Start)
            .clip(false)
          }

          if (this.visibleCourses().length === 0) {
            EmptyView({ message: '没有符合条件的课程' })
          } else {
            Column({ space: AppSize.gap }) {
              ForEach(this.visibleCourses(), (item: BykcCourse) => {
                this.courseCard(item)
              }, (item: BykcCourse) => item.id.toString())
            }
            .width('100%')

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

      if (this.filterPanelOpen) {
        this.filterOverlay()
      }
    }
    .width('100%')
    .height('100%')
    // 页面根 Stack 也铺到安全区，遮罩与居中以整屏为准
    .expandSafeArea()
  }
}
