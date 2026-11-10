# UI 设计

## 设计取向

不做「安卓界面搬到鸿蒙」，而是按 HarmonyOS 设计规范重写：

- **材质优先**：标题栏与底栏用系统材质（HDS），内容靠层级与留白区分，不堆阴影和分割线。
- **沉浸**：内容延伸到状态栏与导航条之下，只靠安全区避让，不使用整块色带。
- **一套令牌**：颜色、间距、圆角、字号全部走 `components/AppTheme.ets`，页面不写字面量。

## 悬浮底栏

`pages/MainPage.ets` 用官方 `HdsTabs`，满足悬浮底栏的三条前置约束：

```ts
HdsTabs({ controller: this.controller }) { /* 4 个 TabContent */ }
  .barOverlap(true)              // ① 页签叠加在内容之上
  .barPosition(BarPosition.End)  // ② 位于容器底部
  .vertical(false)               // ③ 横向排布
  .barFloatingStyle({
    barBottomMargin: this.bottomSafeHeight + 12,
    gradientMask: { maskColor: '#66F1F3F5', maskHeight: 92 },
    systemMaterialEffect: { materialType: ADAPTIVE, materialLevel: ADAPTIVE }
  })
```

- 底栏距底 = 导航条避让高度 + 12vp，避开系统手势条。
- 内容区统一预留 `AppSize.contentBottomInset`（手机 104vp），否则末项会被底栏压住。

## 沉浸光感

| 位置 | 载体 | 参数 |
| --- | --- | --- |
| 标题栏 | `HdsNavigation.titleBar.style` | `scrollEffectType: GRADIENT_BLUR` + `systemMaterialEffect: ADAPTIVE` |
| 底部页签 | `HdsTabs.barFloatingStyle` | `systemMaterialEffect: ADAPTIVE` |
| 卡片 / 弹层 | `components/MaterialCardLayer.ets` | 当前档位 `REGULAR` |

`ADAPTIVE` 是系统自适应档位：旗舰机给完整材质，低端机自动降级，不用自己分档。

**为什么需要 `MaterialCardLayer`**：普通 `Column` / `Row` 挂材质在内容区静默不渲染，
只有按钮、选择类组件、Navigation 标题栏和 `barPosition: End` 底栏全域生效。
所以自绘卡片用一层不可交互的 `ToggleType.Button` 当画布：

```ts
Button({ type: ToggleType.Button }) { /* 空 */ }
  .enabled(false).focusable(false)
  .hitTestBehavior(HitTestMode.None)
  .attributeModifier(materialModifier)  // 属性链最末
```

内容作为 Stack 兄弟叠在上面，品牌色只能写在内容层（材质在 `backgroundColor` 之上）。
`common/SystemMaterial.ets` 必须**惰性求值**，否则取不到系统材质实例。

> 性能：滚动页不要给十几个元素挂材质，会掉帧。长列表用 `backdropBlur` + 半透明底色替代。

## 设计令牌

| 令牌 | 内容 | 位置 |
| --- | --- | --- |
| `AppColor` | 品牌蓝、语义色、文字三级、表面色 | 颜色走 `resources/base|dark/element/color.json` |
| `AppSize` | `pagePadding`(16) / `contentBottomInset`(104) / `sheetRadius`(32) / `contentTopLift`(8) | `static get`，随断点变化 |
| `AppFont` | 标题 / 正文 / 说明字号与行高 | — |
| `AppMaterial` | 材质档位与圆角 | — |

- **深色模式**：不硬编码颜色，`dark/element/color.json` 提供深色色板；
  状态栏内容色跟随深浅色，避免「白底白字」。
- **圆形按钮**：`Button 40×40` + `borderRadius(20)` + 24vp 图标 + `circleButtonSurface`，
  **不要**加 `backdropBlur`、不要再垫材质层（会变成黑圆点）。

## 二级页骨架

二级页是注册到路由的 `HdsNavDestination`（自铺满、自带标题栏，**内部绝不再自绘标题栏**），
标准骨架四件套缺一不可：

```ts
Scroll(this.scroller) { /* 内容 */ }
  .padding({ top: destTopInset(topSafeInsetVp()), bottom: AppSize.contentBottomInset })
  .clip(false)
  .expandSafeArea()
```

配合 `titleBar({ avoidLayoutSafeArea: true, enableComponentSafeArea: true })`，
内容才能滚到标题栏与底栏之下而不被裁。一级页用 `titleMode(MINI)` + `hideBackButton(true)`。

## 平板分栏

`ImmersiveUtil` 监听 `windowSizeChange`，把断点写进 AppStorage
（常量在 `common/Breakpoint.ets`）：

| 断点 | 宽度 | 布局 |
| --- | --- | --- |
| `sm` | < 600vp | 手机：`HdsTabs` 底部页签 |
| `md` | 600–840vp | 72vp 图标侧栏 + 全宽 NavBar |
| `lg` | 840–1200vp | 240vp 侧栏 + 双栏拆分（`NavigationMode.Split`） |
| `xxl` | ≥ 1200vp | 240vp 侧栏 + 400vp 列表栏 + 双栏拆分 |

手机（`sm`）分支的 `HdsTabs` 代码保持原样不动，宽屏走独立分支，保证手机零回归。

> 注意：`module.json5` 的静态 `orientation: portrait` **优先于**运行时
> `setPreferredOrientation`。要真正横屏全屏需改静态方向，会影响手机竖屏锁定。

## 动效

- **跟手翻周**（课表）：SDK 的 Swiper 翻页阈值固定为半页宽、不可调，所以
  `disableSwipe(true)` + 自接管 `PanGesture` + `translate`：阈值 `页宽 × 0.22`，
  `|vx| > 350vp/s` 也翻页，到头 0.3 橡皮筋，松手挪 `dx ± 页宽` 再弹回。
- **回弹**：`curves.responsiveSpringMotion(0.38, 0.90)`，不受 `.duration()` 控制。
- **半模态面板**（`bindSheet`）：`height: FIT_CONTENT` + `detents: [FIT_CONTENT]` 单档位，
  材质生效时 `blurStyle: BlurStyle.NONE`、`backgroundColor: Color.Transparent`，
  头部自绘（标题左 16vp、关闭按钮 40vp 圆按钮右 16vp、`Row.height(64)`）。

## 动效与交互红线（实测踩坑）

| 现象 | 原因 | 做法 |
| --- | --- | --- |
| 滑到一半闪黑 | `.cachedCount(2, true)` 邻页 `isShown` 默认 false，不进渲染树 | 关掉该参数或预载渲染 |
| 甩一次连跳 5 周 | `.index()` 绑了 `currentWeek` 形成回环 | `.index()` 只定初始常量，之后走 `changeIndex()` |
| 表头被网格压住 | `clip(false)` 的代价 | 已知遗留，唤醒重拉有 1~2 帧 |
| 加载态整页替换导致表头消失 | 用 `LoadingView` 替换整页 | 状态收进网格下方 30vp 状态行 |
| `List` 嵌在 `Scroll` 里白屏 | 嵌套滚动冲突且无日志 | 改 `Flex({ wrap: Wrap })` 换行 |
