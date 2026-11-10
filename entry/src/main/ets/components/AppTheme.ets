/**
 * 设计令牌（Design Token）。
 *
 * 取值对齐 HarmonyOS Design 基础规范：
 * - 间距：4 / 8 / 12 / 16 / 24
 * - 圆角：卡片 16vp、大卡片 24vp、胶囊 999vp
 * - 字号：跟随 fp 单位，支持系统字体缩放
 * 颜色统一走资源引用，天然支持深色模式（resources/dark）。
 */
export class AppColor {
  static readonly brand: Resource = $r('app.color.brand');
  static readonly brandDark: Resource = $r('app.color.brand_dark');
  static readonly brandLight: Resource = $r('app.color.brand_light');
  static readonly brandContainer: Resource = $r('app.color.brand_container');
  /**
   * 「选中态」品牌色底，**带透明度**（约 60%）。
   *
   * 给「沉浸光感」的选项块用：材质（systemMaterial）的绘制层级在组件自身 `backgroundColor`
   * 之**上**，所以选中态的品牌色不能写在材质承载层上（会被材质盖住），只能作为**内容层**
   * 的底色叠在材质之上。用不透明的 `brand_container` 会把材质整个盖死，故单列一个半透明版。
   */
  static readonly brandContainerGlass: Resource = $r('app.color.brand_container_glass');
  static readonly pageBackground: Resource = $r('app.color.page_background');
  static readonly pageBackgroundTop: Resource = $r('app.color.page_background_top');
  static readonly surface: Resource = $r('app.color.surface');
  static readonly surfaceSubtle: Resource = $r('app.color.surface_subtle');
  /**
   * 「沉浸光感」表面底色 —— 半透明（约 70%），**必须配合 backgroundBlurStyle 使用**。
   *
   * 为什么不能沿用实心的 surface_subtle：系统材质（system material）的本质是
   * 「磨砂 + 自适应着色」，不透明底色会把它整个盖住，看起来仍是死板色块；
   * 半透明底色 + 材质叠加，才是 HDS 上那种「玻璃上浮着一层光」的观感。
   */
  static readonly glassSurface: Resource = $r('app.color.glass_surface');
  /**
   * 圆形图标按钮（返回 / 关闭这类）的底色：**半透明叠加色**，不随底色走。
   *
   * 因为这类按钮会落在各种底上（标题栏材质、弹窗玻璃、半模态面板），不透明底色会在
   * 浅底上显得突兀；用 8%（浅色）/ 12%（深色）的叠加色，在哪种底上都是"淡一圈的圆"。
   * 尺寸对齐系统返回按钮：40×40vp 圆 + 24vp 图标。
   */
  static readonly circleButtonSurface: Resource = $r('app.color.circle_button_surface');
  static readonly textPrimary: Resource = $r('app.color.text_primary');
  static readonly textSecondary: Resource = $r('app.color.text_secondary');
  static readonly textTertiary: Resource = $r('app.color.text_tertiary');
  static readonly textOnBrand: Resource = $r('app.color.text_on_brand');
  static readonly divider: Resource = $r('app.color.divider');
  static readonly warning: Resource = $r('app.color.warning');
  static readonly danger: Resource = $r('app.color.danger');
  static readonly success: Resource = $r('app.color.success');
  /**
   * 空闲教室表格里的「空闲」格底色（柔和薄荷绿，与 UBAA 网页版表格一致）。
   *
   * 它是**浅色实底**、格子里的文字（表头节次、教室名）画在它外面，所以浅 / 深色主题共用同一个值。
   */
  static readonly classroomFree: Resource = $r('app.color.classroom_free');
  /**
   * 空闲教室表格里的「已被占用」格底色（浅红，与空闲格的薄荷绿成对）。
   *
   * 深色主题给得略沉一点（`#E39A9A`）：和薄荷绿一样是实底，太亮会在暗色表格上刺眼。
   */
  static readonly classroomBusy: Resource = $r('app.color.classroom_busy');
  /**
   * 空闲教室表格的**格线**颜色（30% 黑）。
   *
   * ⚠️ 不能用 `AppColor.divider`（深色主题是 10% 白）：`divider` 是给「深底上的分隔」用的，
   * 而格线是画在**浅色格块之上**的 —— 10% 白线压在薄荷绿上几乎看不见（用户反馈
   * 「绿色滑块之间的区分肉眼几乎不可见」）。半透明**黑**在绿格 / 红格上都看得清，
   * 浅深色主题共用同一个值。
   */
  static readonly classroomGrid: Resource = $r('app.color.classroom_grid');
  /**
   * **半透明品牌蓝**：主按钮「沉浸光感版」的底色（55% 不透明）。
   *
   * 材质画在 `backgroundColor` **之上**，所以全不透明的品牌色会把材质盖死；
   * 透明留得越大，玻璃那层光越明显、蓝越淡 —— 想更透就继续调低 alpha。
   */
  static readonly brandGlass: Resource = $r('app.color.brand_glass');
  static readonly accentYellow: Resource = $r('app.color.accent_yellow');
  static readonly accentGreen: Resource = $r('app.color.accent_green');
  static readonly accentPurple: Resource = $r('app.color.accent_purple');
  static readonly accentPink: Resource = $r('app.color.accent_pink');
  /**
   * 悬浮底栏上方的渐隐遮罩色。
   *
   * 必须走资源引用：早先写死成浅灰 #66F1F3F5，深色模式下会在页面底部
   * 糊出一片白色渐变，与黑色背景严重割裂。
   */
  static readonly tabBarMask: Resource = $r('app.color.tab_bar_mask');
}

export class AppSize {
  /**
   * 页面左右内边距。手机端 16vp（逐像素实测值，不能改）；宽屏 24vp。
   * 用 getter 而不是常量：调用点 `AppSize.pagePadding` 语法不变，30+ 页面无需改动。
   * 键名与 common/Breakpoint.ets 的 KEY_IS_WIDE_SCREEN 一致。
   */
  static get pagePadding(): number {
    return AppStorage.get<boolean>('isWideScreen') === true ? 24 : 16;
  }
  static readonly cardRadius: number = 16;
  static readonly cardRadiusLarge: number = 24;
  static readonly cardPadding: number = 16;
  /**
   * 半模态（`bindSheet`）面板的圆角。
   *
   * **必须等于系统给半模态面板的框架圆角（真机实测 32vp）**，不能比它小。
   * 原因：承载层画的系统材质自带一圈很细的**边缘高光**，如果承载层的圆角比框架更"尖"
   * （比如用卡片的 24vp），框架就会把拐角连那圈高光一起裁掉 —— 表现为高光在圆角起点处
   * 突然断掉（实测断点在 x≈1256-112=1204，正是 32vp 圆的切点）。
   * 取同一个 32vp，两者严丝合缝，高光才能顺着弧线走完整圈。
   */
  static readonly sheetRadius: number = 32;
  static readonly gapSmall: number = 8;
  static readonly gap: number = 12;
  static readonly gapLarge: number = 16;
  /** 悬浮底栏高度（与 HdsTabs 迷你栏 / 页签栏高度保持一致）。 */
  static readonly tabBarHeight: number = 56;
  /**
   * 悬浮底栏距底部避让区的额外留白。
   *
   * 取 0 的实测依据（与系统「电话」App 同机型逐像素比对）：
   *   系统「电话」胶囊底边距屏幕下沿 30.5vp，本项目原为 34.8vp（barBottomMargin=4）。
   *   置 0 后底边落在 30.6vp，与系统应用对齐 —— 底栏即「贴着手势区上沿」。
   */
  static readonly tabBarBottomMargin: number = 0;
  /** 页面底部留白：手机端 104vp（为悬浮底栏预留）；宽屏无底栏，24vp 即可。 */
  static get contentBottomInset(): number {
    return AppStorage.get<boolean>('isWideScreen') === true ? 24 : 104;
  }

  /**
   * 一级页（主页 / 功能 / 我的）内容整体上移量（vp）。
   *
   * 这三个页面的标题栏是纯透明底板（不画文字），内容首行从标题栏下沿开始，
   * 顶部视觉上有一整块「状态栏 + 56vp 标题栏」的空旷区。把内容整体上移一点，
   * 让首行更贴近标题栏、减少顶部空旷感。
   *
   * 用 `translate` 做纯视觉位移：不动布局盒，因此不影响滚动、沉浸模糊
   * （expandSafeArea 照旧）与下拉刷新（Refresh 位移的是 Scroll，不是内容列）。
   */
  static get contentTopLift(): number {
    return AppStorage.get<boolean>('isWideScreen') === true ? 0 : 8;
  }

  /**
   * 页面（一 / 二级通用）标题栏高度。
   *
   * HDS 文档：HdsNavDestinationTitleMode.MINI —— 标题栏固定 56vp；
   * 一级页面的 HdsNavigation 也显式置成 MINI（见 MainPage.titleBar），同高。
   * 两者都是「悬浮在内容之上」的沉浸式标题栏，内容需自行避让，否则第一张卡片
   * 会被毛玻璃底板压住（更要紧的是：标题栏的布局盒吃触摸，压在它下面的磁贴点不动）。
   */
  static readonly navTitleBarMiniHeight: number = 56;

  /**
   * 课表页标题栏下沿「周次选择」条的高度（vp），挂在该页 titleBar 的 bottomBuilder 上
   * （见 MainPage.scheduleTitleBar）。
   *
   * 注意：它**不需要**页面再单独避让 —— HDS 的组件安全区按标题栏的完整框架计算，
   * 这条也在其中（见 destTopInset 的实测记录）。这里只作为标题栏自身的配置值。
   */
  static readonly scheduleWeekBarHeight: number = 44;

  /**
   * HDS 是否已经替我们扣掉了顶部安全区（titleBar 的 `enableComponentSafeArea: true`）。
   *
   * 置 true 时 HDS 会把「状态栏 + 标题栏」整块从内容区里扣掉（内容区从它下沿开始），
   * 页面**不需要**再自己加顶部留白。
   */
  static readonly navSafeAreaHandledByHds: boolean = true;

  /**
   * 页面内容顶部起始留白。
   *
   * 2026-09-20：HDS 的组件安全区接管了顶部避让（见 navSafeAreaHandledByHds），
   * 返回 0。实测依据（非常重要，别再改回去）：把 home 页首个文字行做像素定位，
   * 改动前 y=339px、置 enableComponentSafeArea 后仍保留 (safe + 56vp) 的旧留白时
   * y=671px，差值 332px；本机密度 3.5（用课表网格 56vp 行距 = 196px 反推），
   * 332 / 3.5 = 94.9vp ≈ 状态栏 39vp + 标题栏 56vp —— 正好是被多扣了一整份。
   *
   * 还踩过一次的坑：留白必须写在**滚动内容**的内边距里，不能写到外壳上 —— 外壳
   * padding 会被 ArkUI 当成 contentInset，把滚动视口一并压低，内容就再也滑不进
   * 标题栏底板（二级页面踩过）。
   *
   * @param topSafeHeight KEY_TOP_SAFE_HEIGHT 提供的状态栏避让高度（vp）
   */
  static destTopInset(topSafeHeight: number): number {
    if (AppSize.navSafeAreaHandledByHds) {
      return 0;
    }
    const safe: number = topSafeHeight > 0 ? topSafeHeight : 0;
    return safe + AppSize.navTitleBarMiniHeight;
  }
}

/**
 * 页面内自绘浮起元素的模糊参数。
 *
 * 2026-09-20 从「系统材质」改成「普通高斯模糊」：原先给课表页的学期胶囊、周次胶囊、
 * 表头、十几个课程块都挂了 `backgroundBlurStyle(BlurStyle.COMPONENT_*, { adaptiveColor:
 * AVERAGE })`。系统材质每帧都要重新采样背景算自适应着色，页面上十几块同时实时取色，
 * 滚动时直接掉帧。换成 `backdropBlur(半径)` —— 只做一次固定的高斯模糊，不做取色，
 * 观感接近但开销低一个量级。
 *
 * 悬浮标题栏 / 页签栏仍走 HDS 的 systemMaterialEffect：那两块是系统组件，
 * 由系统侧合成，不受这里影响，光感照旧。
 */
export class AppMaterial {
  /** 小面积元素（胶囊、课程块）的高斯模糊半径。 */
  static readonly blurSmall: number = 12;
  /** 大面积浮起容器（课表表头）的高斯模糊半径。 */
  static readonly blurLarge: number = 20;

  /*
   * ⚠️ 「标题区渐变模糊带」已废弃（2026-09-23），别再按参考图去加：
   * 1. `backdropBlur` 会把**材质自带的边缘高光一起抹平** —— 带子压在上两角时，
   *    圆角的亮边在带子范围内变淡、与其余部分对不上（用户反馈「上方圆角光效不匹配」）；
   * 2. 多层不同半径叠出来的「渐变」是**阶梯**，有文字滑过时能看到横向条纹光栅感；
   * 3. 更要命的是它在我们这两个面板里**静止时根本不可见**（头部下方是空白段，没东西可糊），
   *    面板内容也滚不动，压根不会滑到标题下面 —— 参考图里能看到效果是因为它的列表正在标题下。
   * 所以：想要这层质感就用材质（`MaterialCardLayer`），不要用模糊带模拟。
   */
  /* ---------------------- 沉浸式系统材质（弹窗用） ---------------------- */

  /**
   * 弹窗的沉浸材质**不在这里** —— 见 `common/SystemMaterial.ets`。
   *
   * 关键限制（踩过）：**普通 `Column` / `Row` 在内容区挂 `systemMaterial` 是静默不渲染的**，
   * 只有「按钮 / 选择类」组件能在页面内全部区域生效。所以材质必须由一块不可交互的
   * `ToggleType.Button` 画布承载（`components/MaterialCardLayer.ets`），
   * 内容叠在它之上。本类只保留页面内自绘元素的高斯模糊参数。
   */
}

export class AppFont {
  static readonly display: number = 32;
  static readonly titleLarge: number = 24;
  static readonly title: number = 20;
  static readonly subtitle: number = 16;
  static readonly body: number = 14;
  static readonly caption: number = 12;
}

/** 业务模块的主题色，用于功能入口图标底色。 */
export class ModuleColor {
  static schedule(): Resource {
    return AppColor.brand;
  }

  static exam(): Resource {
    return AppColor.accentPurple;
  }

  static grade(): Resource {
    return AppColor.accentGreen;
  }

  static classroom(): Resource {
    return AppColor.accentYellow;
  }

  static bykc(): Resource {
    return AppColor.accentPink;
  }
}
