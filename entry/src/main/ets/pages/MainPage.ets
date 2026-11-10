import {
  HdsNavigation,
  HdsNavigationTitleBarOptions,
  HdsNavigationTitleMode,
  HdsTabs,
  HdsTabsController,
  ScrollEffectType,
  hdsMaterial
} from '@kit.UIDesignKit';
import { KEY_BOTTOM_SAFE_HEIGHT, topSafeInsetVp } from '../common/ImmersiveUtil';
import { webview } from '@kit.ArkWeb';
import { Logger } from '../common/Logger';
import { AppColor, AppFont, AppSize } from '../components/AppTheme';
import { ScheduleDayHeader, ScheduleHeaderModel, ScheduleTermChip, ScheduleWeekChips } from '../components/ScheduleHeader';
import { routeBuilder } from './RouteBuilder';
import { WIDE_PLACEHOLDER_ROUTE } from '../common/AppRouter';
import { HomePage } from './HomePage';
import { SchedulePage } from './SchedulePage';
import { FeaturePage } from './FeaturePage';
import { MinePage } from './MinePage';
import {
  KEY_IS_WIDE_SCREEN,
  KEY_BREAKPOINT,
  KEY_NAV_SPLIT_MODE,
  navBarWidthOf
} from '../common/Breakpoint';
import { WideLayoutTokens } from '../components/WideLayoutTokens';
import { WideSideNav } from '../components/WideSideNav';

/**
 * 桌面卡片跳转用的 AppStorage key（写入方在 `EntryAbility`）。
 * - `pendingRoute`：页签标识 home / schedule / feature / mine
 * - `pendingPage`：可选，该页签内的二级路由名（exam / grade / classroom …）
 */
const KEY_PENDING_ROUTE: string = 'pendingRoute';
const KEY_PENDING_PAGE: string = 'pendingPage';

/**
 * 一级页面内容外壳。
 *
 * 只是一层「撑满 + 承载 @BuilderParam」的容器，**不再自己补模糊层**。
 *
 * 2026-09-20 起顶部模糊全部交给 HDS 自己：标题栏置了
 * `enableComponentSafeArea: true`（见 titleBar / scheduleTitleBar），HDS 把标题栏
 * 声明成组件级安全区，材质底板会一直铺到屏幕顶端（状态栏区域也盖上）。
 *
 * 之前是在这里叠一层 `Column().height(topSafeInsetVp()).backdropBlur(20)` 去盖状态栏，
 * 结果那一条的模糊强度与标题栏自带的系统材质对不上，两者交界处出现一条明显的横向
 * 断层（状态栏那一段更「糊」、下面那一段更「透」，像两块板拼接）—— 现在唯一模糊源
 * 就是标题栏自己的材质，接缝自然消失。
 *
 * 外壳本身**不加内边距**：加在外壳上的 padding 会被当成 contentInset 把滚动视口
 * 一并压低，内容就再也滑不进底板（二级页面踩过）。顶部留白改由各一级页自己的滚动
 * 内容承担（见各页 `.padding({ top: AppSize.destTopInset(topSafeInsetVp()) })`）。
 */
@Component
struct PageShell {
  @Builder
  empty() {
  }

  @BuilderParam content: () => void = this.empty;

  build() {
    Column() {
      this.content()
    }
    .width('100%')
    .height('100%')
  }
}

/**
 * 主容器：HDS 悬浮底栏 + 沉浸光感。
 *
 * 三条硬性约束（官方「页签栏悬浮样式」指南）：
 *   1. barPosition = BarPosition.End —— 页签位于容器底部
 *   2. vertical = false              —— 横向排布
 *   3. barOverlap = true             —— TabBar 叠加在 TabContent 之上
 * 满足后才允许通过 barFloatingStyle 配置悬浮样式与沉浸光感。
 *
 * 沉浸光感要点：
 *   - systemMaterialEffect.materialType = ADAPTIVE：由系统按设备算力自适应材质
 *   - systemMaterialEffect.materialLevel = ADAPTIVE：旗舰机完整效果，低端机自动降级
 *   - 标题栏走 HdsNavigation.titleBar.style 的同名参数
 * 两项能力均自 6.1.0(23) 起提供，本工程 compatibleSdkVersion 已对齐。
 */
@Component
export struct MainPage {
  @StorageProp(KEY_BOTTOM_SAFE_HEIGHT) bottomSafeHeight: number = 0;
  @State private currentIndex: number = 0;
  /** 宽屏分支开关（AppStorage 由 ImmersiveUtil 的 windowSizeChange 写入）。 */
  @StorageProp(KEY_IS_WIDE_SCREEN) private isWide: boolean = false;
  @StorageProp(KEY_BREAKPOINT) private bp: string = 'sm';
  @StorageProp(KEY_NAV_SPLIT_MODE) @Watch('onNavSplitModeChange') private navSplitMode: boolean = false;

  /**
   * 桌面卡片带过来的页签请求（`EntryAbility.onCreate` / `onNewWant` 写入 AppStorage）。
   *
   * - `@StorageLink` 而不是 `AppStorage.get`：卡片在后台点进来时 MainPage **已经存在**，
   *   需要跟着 AppStorage 的变化一起更新（@Watch 触发切页签）；
   * - 冷启动时 MainPage 是在首页恢复登录态之后才建的，AppStorage 里已经有值，
   *   所以 `aboutToAppear` 也要消费一次。
   *
   * 消费完立刻清空：否则下次任意一次 AppStorage 写回都会把用户「弹」回课表页。
   */
  @StorageLink(KEY_PENDING_ROUTE) @Watch('onPendingRoute') pendingRoute: string = '';

  /** 卡片指定的二级页面（考试/成绩/空闲教室卡会带，课表卡不带）。 */
  @StorageLink(KEY_PENDING_PAGE) pendingPage: string = '';


  onLogout: () => void = () => {};

  private controller: HdsTabsController = new HdsTabsController();

  /* 站内网页提交浮层（覆盖底栏，全屏） */
  @StorageProp('spocWebOpen') @Watch('onSpocWebOpenChange') private spocWebOpen: boolean = false;
  @StorageProp('spocWebLogin') private spocWebLogin: string = '';
  @StorageProp('spocWebDetail') private spocWebDetail: string = '';
  private mainWebCtrl: webview.WebviewController = new webview.WebviewController();
  private mainWebLoaded: boolean = false;

  onSpocWebOpenChange(): void {
    if (this.spocWebOpen) {
      this.mainWebLoaded = false;
    }
  }
  private homeStack: NavPathStack = new NavPathStack();
  private scheduleStack: NavPathStack = new NavPathStack();
  private featureStack: NavPathStack = new NavPathStack();
  private mineStack: NavPathStack = new NavPathStack();

  aboutToAppear(): void {
    // 冷启动路径：AppStorage 里已有值时，这里把它吃掉
    this.applyRoute(this.pendingRoute);
    // Split 右栏栈空时补一个占位页（仅宽屏执行）
    this.ensureWidePlaceholder();
  }

  private onPendingRoute(): void {
    this.applyRoute(this.pendingRoute);
  }

  /**
   * 按 `target` 切到对应页签（认不出就不动），再按 `page` 压入二级页面。
   *
   * `page` 只在 feature 页签有意义 —— 卡片要落的二级页面（考试/成绩/空闲教室）
   * 全都挂在功能页的 NavPathStack 下。压栈前必须先 `clear()`，
   * 否则会叠在用户之前停留的那个二级页上。
   */
  private applyRoute(target: string): void {
    if (target.length === 0) {
      return;
    }
    // 冷启动时 MainPage 可能先于 `pendingPage` 的写入？两个 key 同一次 want 里写出，
    // 这里都同步读一次即可。
    const page: string = this.pendingPage;
    AppStorage.set<string>(KEY_PENDING_ROUTE, '');
    AppStorage.set<string>(KEY_PENDING_PAGE, '');
    let index: number = -1;
    if (target === 'home') {
      index = 0;
    } else if (target === 'schedule') {
      index = 1;
    } else if (target === 'feature') {
      index = 2;
    } else if (target === 'mine') {
      index = 3;
    }
    if (index < 0) {
      Logger.warn('未知的卡片跳转目标：' + target);
      return;
    }
    // 目标页签若有二级页面在栈里，先清干净 —— 卡片进来的应该是该页签的根页面
    this.stackOf(index).clear();
    // 宽屏没有 HdsTabsController，切页签靠 currentIndex 驱动 if/else 分支
    this.currentIndex = index;
    this.controller.changeIndex(index);
    if (index === 2 && page.length > 0) {
      this.featureStack.pushPath({ name: page });
    }
  }

  /**
   * 课表页顶部「学期 / 周次」选择器的共享状态（见 ScheduleHeader.ScheduleHeaderModel）。
   *
   * MainPage 持有它、并把它渲染进课表页的标题栏；SchedulePage 拿到**同一个实例**
   * 负责写数据和挂回调 —— 两边不是父子关系，靠这个 @Observed 实例当桥。
   */
  @State private scheduleHeader: ScheduleHeaderModel = new ScheduleHeaderModel();

  /** 四个页签共用同一张路由表，各自跳转互不干扰。 */
  /**
   * 当前生效的导航栈 —— 由 `routeMap` 在被调用时按**当前页签**决定。
   *
   * ## 为什么需要这个间接层
   *
   * `navDestination` 要的是 **@Builder**（组件装饰器），不能传普通函数 ——
   * 传了普通函数（第一版我写成 `routeMapOf(stack)` 返回闭包），
   * 路由表**根本挂不上**，所有二级页全黑（真机实测）。
   *
   * 而 `navDestination` 的回调签名只有 `(name, param)`，**拿不到栈**。
   * 于是用一个 `@State` 记住「当前是哪个页签」，在 `@Builder routeMap` 里
   * 按它取对应的栈：
   *
   * ```
   * MainPage.routeMap（@Builder）
   *   → 按 currentIndex 取 stackOf(index)
   *   → routeBuilder(name, param, stack)
   *   → DestShell({ stack })
   *   → 子页组件
   * ```
   */
  @Builder
  routeMap(name: string, param: object) {
    // `currentIndex` 由 HdsTabs 的 onChange 维护 —— 就是当前页签序号，
    // 用它取对应的栈（栈的内容与页签一一对应，见 stackOf）。
    routeBuilder(name, param, this.stackOf(this.currentIndex));
  }

  /** 按页签序号取对应的导航栈（「再点一次回主页」时清空它）。 */
  private stackOf(index: number): NavPathStack {
    if (index === 0) {
      return this.homeStack;
    }
    if (index === 1) {
      return this.scheduleStack;
    }
    if (index === 2) {
      return this.featureStack;
    }
    return this.mineStack;
  }

  /** 宽屏侧栏点选：等价 HdsTabs 的 onChange + onTabBarClick 两个回调。 */
  private onWideSelect(index: number): void {
    if (index === this.currentIndex) {
      // 「再点当前项回主页」：清栈后再补占位
      this.stackOf(index).clear();
      this.ensureWidePlaceholder();
      return;
    }
    this.currentIndex = index;
    // 切到课表页时通知它刷新当前周（页签内容是常驻的，onPageShow 不触发）
    if (index === 1) {
      this.scheduleHeader.onRefresh();
    }
    this.ensureWidePlaceholder();
  }

  /** Split 右栏栈空时占位；手机端 / md 单栏档不执行，不污染导航栈。 */
  private ensureWidePlaceholder(): void {
    if (!this.isWide || !this.navSplitMode) {
      return;
    }
    const stack: NavPathStack = this.stackOf(this.currentIndex);
    if (stack.size() === 0) {
      stack.pushPath({ name: WIDE_PLACEHOLDER_ROUTE });
    }
  }

  /**
   * 断点跨过 840vp 时维护占位页：
   * - 进 Split（lg/xxl）→ 栈空则补占位，右栏不留白；
   * - 退回单栏（md）→ 把 4 个栈里的占位全移除，否则 Stack 模式会把占位页当成
   *   栈顶全屏显示（用户转回竖屏会看到「从左侧选择一个功能」而不是一级页）。
   */
  private onNavSplitModeChange(): void {
    if (this.navSplitMode) {
      this.ensureWidePlaceholder();
      return;
    }
    this.homeStack.removeByName(WIDE_PLACEHOLDER_ROUTE);
    this.scheduleStack.removeByName(WIDE_PLACEHOLDER_ROUTE);
    this.featureStack.removeByName(WIDE_PLACEHOLDER_ROUTE);
    this.mineStack.removeByName(WIDE_PLACEHOLDER_ROUTE);
  }

  /**
   * 四个一级页面共用的标题栏配置 —— **只留底板，不留文字**。
   *
   * 为什么去掉大标题：四个页面的第一屏内容本身就说明了所处位置（「晚上好，沛轩」
   * 的问候卡、课表的周次选择、功能的九宫格、我的头像卡），再挂一个「主页 / 课表」
   * 大标题既重复，又把内容硬生生压下 112vp。现在不配置 `content.title`，标题栏
   * 不再绘制任何文字，内容直接从状态栏下方开始。
   *
   * 为什么不丢渐变模糊：滚动效果与光感材质挂在 `style` 上，只要标题栏还在，内容
   * 上滑经过它下方时照样会浮出渐变模糊底板 —— 这正是要保留的效果。状态栏那一段
   * 由 PageShell 的磨砂层补齐（视口从屏幕顶开始），标题栏（MINI，56vp）之下才是
   * 内容的首行，见各页 `.padding({ top: AppSize.destTopInset(topSafeInsetVp()) })`。
   *
   * avoidLayoutSafeArea = true 是关键：置 false 会让 HdsNavigation 的整块内容
   * 上移约一个状态栏的高度（实测内容从 50vp 提到 10vp），静止状态就压在状态栏
   * 时钟上、还会一直被底板模糊 —— 试过，不可用。置 true 后标题栏被约束在安全区
   * 内，内容从状态栏下方开始，静止态干净。
   *
   * 另外 4 个 HdsNavigation 都显式置 `titleMode(HdsNavigationTitleMode.MINI)`（56vp）
   * 并 `hideBackButton(true)`。
   *
   * MINI 的原因：悬浮标题栏虽然不画文字，但**它的布局盒仍然吃触摸**。FREE 模式默认
   * 112vp，状态栏下沿到 112vp 这一整条带上的内容点不动 —— 「功能」页第一排磁贴正好
   * 落在带里（实测点瓦片中心无响应、点它的文字标签才进得去）。MINI 后死区收窄到
   * 56vp，只压住卡片的标题文字（不可点），磁贴全部可点，视觉与光感均无变化。
   *
   * hideBackButton 的原因：MINI 模式的标题栏按 HDS 规范会渲染一个返回按钮，而一级
   * 页面是根页面、没有上一级可退（实测 MINI 后左上角冒出一个孤零零的返回箭头）。
   * 隐藏后标题栏只剩那块透明底板，正好是想要的。
   *
   * enableComponentSafeArea 的原因（6.0.0(20) 起，顶部模糊无缝的关键）：
   * 置 true 后 HDS 把标题栏声明成「组件级安全区」，标题栏的材质底板会连**状态栏**
   * 一起覆盖，同时标题栏内文字/胶囊仍从状态栏下沿开始排。此前 statusBar 那一条靠
   * 外壳自叠一层 backdropBlur 兜底，与标题栏自带材质强度不一致 —— 两者交界处有一条
   * 明显横线（用户反馈的「状态栏部分的模糊和下面的不一样」）。现在只有一个模糊源。
   */
  private titleBar(): HdsNavigationTitleBarOptions {
    return {
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      style: {
        // 初始态底色显式置透明：不设的话首帧会先铺一层实心底色，
        // 与后面浮出的材质换挡，快速滚动时能看到闪一下。
        originalStyle: {
          backgroundStyle: {
            backgroundColor: Color.Transparent
          }
        },
        scrollEffectOpts: {
          enableScrollEffect: true,
          // IMMERSIVE_GRADIENT_BLUR 自 6.1.0(23) 起提供，抹得更「沉浸」：
          // 渐变过渡更长（默认 56vp），内容从底板下淡出而不是被硬切一刀。
          scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      }
    };
  }

  /**
   * 课表页标题栏主区：学期胶囊 + 「第 N 周」。
   *
   * 左右留白写在这里、不写 `HdsNavigationTitleBarOptions.padding` ——
   * 实测那个 padding 只作用于标题栏自带的标题区，对自定义 stackBuilder / bottomBuilder
   * 内容不生效（胶囊依旧贴着屏幕左边）。（此前试过，已回退。）
   */
  @Builder
  scheduleTermTitle() {
    Row() {
      ScheduleTermChip({ model: this.scheduleHeader })
    }
    .width('100%')
    .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
  }

  /** 课表页标题栏下沿：周次胶囊 + 「周几 / 日期」行（第一版：直接放在标题栏里，靠系统材质模糊）。 */
  @Builder
  scheduleWeekTitle() {
    Column() {
      ScheduleWeekChips({ model: this.scheduleHeader })
      ScheduleDayHeader({ model: this.scheduleHeader })
    }
    .width('100%')
  }

  /**
   * 课表页专用标题栏 —— 与其它三个页签同款底板与光感，但**带内容**。
   *
   * 主区（stackBuilder）挂学期选择器，下沿（bottomBuilder）挂周次选择器。这样
   * 「学期 + 周次」常驻悬浮标题栏、永远贴在状态栏下方，课表网格不再被它们往下压；
   * 而且它们属于标题栏自己的布局盒，不受「标题栏吃触摸」影响，照常可点。
   */
  private scheduleTitleBar(): HdsNavigationTitleBarOptions {
    return {
      avoidLayoutSafeArea: true,
      enableComponentSafeArea: true,
      style: {
        originalStyle: {
          backgroundStyle: {
            backgroundColor: Color.Transparent
          }
        },
        scrollEffectOpts: {
          enableScrollEffect: true,
          scrollEffectType: ScrollEffectType.IMMERSIVE_GRADIENT_BLUR
        },
        systemMaterialEffect: {
          materialType: hdsMaterial.MaterialType.ADAPTIVE,
          materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
        }
      },
      content: {
        // 注意：这里必须用箭头函数包一层，**不能**直接写 `stackBuilder: this.scheduleTermTitle`。
        // HDS 收到的是普通 options 对象，直接传方法引用时调用方是那个对象，
        // `this` 丢失 → @Builder 内生成的 `this.observeComponentCreation2` 取到 undefined，
        // 运行时抛 "Cannot read property observeComponentCreation2 of undefined" 并闪退。
        // 箭头函数捕获外层 this，@Builder 仍在 MainPage 实例上执行。
        stackBuilder: (): void => {
          this.scheduleTermTitle();
        },
        bottomBuilder: {
          builder: (): void => {
            this.scheduleWeekTitle();
          },
          // 周次胶囊 44 + 日期行 44
          height: AppSize.scheduleWeekBarHeight + 44
        }
      }
    };
  }

  /** 站内网页提交：覆盖整个屏幕（含底部页签），先登录再跳作业详情。 */
  @Builder
  spocWebOverlay() {
    Column() {
      Row() {
        Text('网页提交')
          .fontSize(AppFont.title)
          .fontWeight(FontWeight.Bold)
          .fontColor(AppColor.textPrimary)
        Blank()
        Button('关闭')
          .height(32)
          .fontSize(AppFont.body)
          .fontColor(AppColor.brand)
          .backgroundColor(AppColor.brandContainer)
          .onClick(() => {
            AppStorage.setOrCreate('spocWebOpen', false);
          })
      }
      .width('100%')
      .height(56)
      .padding({ left: AppSize.pagePadding, right: AppSize.pagePadding })
      .alignItems(VerticalAlign.Center)
      .backgroundColor(AppColor.pageBackground)

      Web({ src: this.spocWebLogin, controller: this.mainWebCtrl })
        .width('100%')
        .layoutWeight(1)
        .domStorageAccess(true)
        .javaScriptAccess(true)
        .mixedMode(MixedMode.All)
        .metaViewport(true)
        .zoomAccess(false)
        .onPageEnd(() => {
          if (!this.mainWebLoaded) {
            this.mainWebLoaded = true;
            if (this.spocWebDetail.length > 0) {
              this.mainWebCtrl.loadUrl(this.spocWebDetail);
            }
          }
        })
    }
    .width('100%')
    .height('100%')
    // 顶部让开「状态栏 + MINI 标题栏」，保留 SPOC 作业那一行；底部一直铺到屏幕底，盖住页签栏
    .padding({ top: topSafeInsetVp() + AppSize.navTitleBarMiniHeight })
  }

  /** 手机端原布局：整段逐字保留，零回归。 */
  @Builder
  narrowTabs() {
    HdsTabs({ controller: this.controller }) {
      TabContent() {
        HdsNavigation(this.homeStack) {
          PageShell() {
            HomePage({ stack: this.homeStack })
          }
        }
        .navDestination(this.routeMap)
        .titleBar(this.titleBar())
        .titleMode(HdsNavigationTitleMode.MINI)
        .hideBackButton(true)
      }
      .tabBar(new BottomTabBarStyle($r('app.media.ic_home'), $r('app.string.tab_home')))

      TabContent() {
        HdsNavigation(this.scheduleStack) {
          PageShell() {
            SchedulePage({ stack: this.scheduleStack, header: this.scheduleHeader })
          }
        }
        .navDestination(this.routeMap)
        .titleBar(this.scheduleTitleBar())
        .titleMode(HdsNavigationTitleMode.MINI)
        .hideBackButton(true)
      }
      .tabBar(new BottomTabBarStyle($r('app.media.ic_schedule'), $r('app.string.tab_schedule')))

      TabContent() {
        HdsNavigation(this.featureStack) {
          PageShell() {
            FeaturePage({ stack: this.featureStack })
          }
        }
        .navDestination(this.routeMap)
        .titleBar(this.titleBar())
        .titleMode(HdsNavigationTitleMode.MINI)
        .hideBackButton(true)
      }
      .tabBar(new BottomTabBarStyle($r('app.media.ic_apps'), $r('app.string.tab_feature')))

      TabContent() {
        HdsNavigation(this.mineStack) {
          PageShell() {
            MinePage({
              stack: this.mineStack,
              onLogout: () => {
                this.onLogout();
              }
            })
          }
        }
        .navDestination(this.routeMap)
        .titleBar(this.titleBar())
        .titleMode(HdsNavigationTitleMode.MINI)
        .hideBackButton(true)
      }
      .tabBar(new BottomTabBarStyle($r('app.media.ic_person'), $r('app.string.tab_mine')))
    }
    // ---- 悬浮三件套 ----
    .barOverlap(true)
    .barPosition(BarPosition.End)
    .vertical(false)
    // ⚠️ **关闭「左右滑动切换页签」**：用户要求 4 个底部栏不再能通过左右滑切换，
    // 把这一手势让给各页自己用（例如课表页用左右滑切教学周）。
    // 注意：这只关掉「内容区横滑切页签」，底部 TabBar 的点击切换不受影响。
    .scrollable(false)
    // ---- 悬浮样式 + 沉浸光感 ----
    .barFloatingStyle({
      // 底部间距跟随手势导航条高度，避免与系统导航条重叠
      barBottomMargin: this.bottomSafeHeight + AppSize.tabBarBottomMargin,
      gradientMask: {
        // 走资源引用，深色模式下不再出现白色渐变遮罩
        maskColor: AppColor.tabBarMask,
        maskHeight: 92
      },
      systemMaterialEffect: {
        materialType: hdsMaterial.MaterialType.ADAPTIVE,
        materialLevel: hdsMaterial.MaterialLevel.ADAPTIVE
      }
    })
    .onChange((index: number) => {
      this.currentIndex = index;
      // 切到课表页时通知它刷新当前周。
      //
      // 为什么不用 SchedulePage.onPageShow：实测在 HdsTabs 的页签切换下**不触发**
      // （切走再切回，上游请求 0 次）—— 页签内容是常驻的，页面可见性回调不跟着页签走。
      // 页签切换的权威信号是这个 onChange。
      if (index === 1) {
        this.scheduleHeader.onRefresh();
      }
    })
    // 「再点一次当前页签 → 回到该页主页」：
    // onTabBarClick 在**每次点击页签**时都会触发（含点当前页签）。如果点的是当前页签，
    // 说明用户想「回顶部/回主页」，就把这个页签的导航栈清空（栈空了会退回根页面）。
    .onTabBarClick((index: number) => {
      if (index === this.currentIndex) {
        this.stackOf(index).clear();
      }
    })
    .backgroundColor(AppColor.pageBackground)
    .width('100%')
    .height('100%')
  }

  /** 宽屏布局：侧边导航 + 当前页签的 HdsNavigation（lg / xxl 走 Split 三栏）。 */
  @Builder
  wideLayout() {
    Row() {
      WideSideNav({
        currentIndex: this.currentIndex,
        bp: this.bp,
        onSelect: (index: number) => {
          this.onWideSelect(index);
        }
      })

      if (this.currentIndex === 0) {
        HdsNavigation(this.homeStack) {
          PageShell() {
            HomePage({ stack: this.homeStack })
          }
        }
        .navDestination(this.routeMap)
        .titleBar(this.titleBar())
        .titleMode(HdsNavigationTitleMode.MINI)
        .hideBackButton(true)
        .mode(this.navSplitMode ? NavigationMode.Split : NavigationMode.Stack)
        .navBarWidth(navBarWidthOf(this.bp))
        .navBarWidthRange({
          minWidth: WideLayoutTokens.navBarMinWidth,
          maxWidth: WideLayoutTokens.navBarMaxWidth
        })
        .minContentWidth(WideLayoutTokens.minContentWidth)
        .navBarPosition(NavBarPosition.Start)
        .enableModeChangeAnimation(true)
        .layoutWeight(1)
      } else if (this.currentIndex === 1) {
        HdsNavigation(this.scheduleStack) {
          PageShell() {
            SchedulePage({ stack: this.scheduleStack, header: this.scheduleHeader })
          }
        }
        .navDestination(this.routeMap)
        .titleBar(this.scheduleTitleBar())
        .titleMode(HdsNavigationTitleMode.MINI)
        .hideBackButton(true)
        .mode(this.navSplitMode ? NavigationMode.Split : NavigationMode.Stack)
        .navBarWidth(navBarWidthOf(this.bp))
        .navBarWidthRange({
          minWidth: WideLayoutTokens.navBarMinWidth,
          maxWidth: WideLayoutTokens.navBarMaxWidth
        })
        .minContentWidth(WideLayoutTokens.minContentWidth)
        .navBarPosition(NavBarPosition.Start)
        .enableModeChangeAnimation(true)
        .layoutWeight(1)
      } else if (this.currentIndex === 2) {
        HdsNavigation(this.featureStack) {
          PageShell() {
            FeaturePage({ stack: this.featureStack })
          }
        }
        .navDestination(this.routeMap)
        .titleBar(this.titleBar())
        .titleMode(HdsNavigationTitleMode.MINI)
        .hideBackButton(true)
        .mode(this.navSplitMode ? NavigationMode.Split : NavigationMode.Stack)
        .navBarWidth(navBarWidthOf(this.bp))
        .navBarWidthRange({
          minWidth: WideLayoutTokens.navBarMinWidth,
          maxWidth: WideLayoutTokens.navBarMaxWidth
        })
        .minContentWidth(WideLayoutTokens.minContentWidth)
        .navBarPosition(NavBarPosition.Start)
        .enableModeChangeAnimation(true)
        .layoutWeight(1)
      } else {
        HdsNavigation(this.mineStack) {
          PageShell() {
            MinePage({
              stack: this.mineStack,
              onLogout: () => {
                this.onLogout();
              }
            })
          }
        }
        .navDestination(this.routeMap)
        .titleBar(this.titleBar())
        .titleMode(HdsNavigationTitleMode.MINI)
        .hideBackButton(true)
        .mode(this.navSplitMode ? NavigationMode.Split : NavigationMode.Stack)
        .navBarWidth(navBarWidthOf(this.bp))
        .navBarWidthRange({
          minWidth: WideLayoutTokens.navBarMinWidth,
          maxWidth: WideLayoutTokens.navBarMaxWidth
        })
        .minContentWidth(WideLayoutTokens.minContentWidth)
        .navBarPosition(NavBarPosition.Start)
        .enableModeChangeAnimation(true)
        .layoutWeight(1)
      }
    }
    .width('100%')
    .height('100%')
  }

  build() {
    Stack() {
      if (this.isWide) {
        this.wideLayout()
      } else {
        this.narrowTabs()
      }

      if (this.spocWebOpen) {
        this.spocWebOverlay()
      }
    }
    .width('100%')
    .height('100%')
  }
}
