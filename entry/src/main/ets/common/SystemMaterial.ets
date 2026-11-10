import { deviceInfo } from '@kit.BasicServicesKit';
import { uiMaterial } from '@kit.ArkUI';
import { Logger } from './Logger';

/**
 * 沉浸光感（沉浸式系统材质 `systemMaterial`）接入层。
 *
 * ## 一、生效范围：普通容器在内容区挂材质是「静默不渲染」的
 *
 * 官方《组件适配沉浸光感》把组件分成两类：
 *
 * | 类别 | 生效范围 |
 * | --- | --- |
 * | 按钮与选择类：`Button` / `Select` / `Toggle` / `Slider` / `ChipGroup` / `SegmentButton` | 页面内**全部区域** |
 * | 其余组件：`Column` / `Row` / `Text` … | 只在 **Navigation / NavDestination 标题栏**，或 `barPosition: BarPosition.End` 的**底部 TabBar** |
 *
 * 所以在内容区这样写**不会渲染、也不报错不警告**（本项目的课程详情弹窗一度整块透明、
 * 文字直接浮在课表网格上，就是踩了这条）：
 *
 * ```ts
 * Column().systemMaterial(material)   // ✗ 内容区的布局容器不生效
 * ```
 *
 * 解法：用 `ToggleType.Button` 当**不可交互的画布**去画材质，内容叠在它上面 ——
 * 见 `components/MaterialCardLayer.ets`。
 *
 * ## 二、和底部页签栏是同一套光感
 *
 * 底栏是 HDS 组件，走 `hdsMaterial.MaterialType.ADAPTIVE` + `MaterialLevel.ADAPTIVE`
 * （系统按设备算力在 EXQUISITE / GENTLE / SMOOTH 三档里挑）。普通 ArkUI 组件用不了
 * hdsMaterial，对应的是 ArkUI 的 `uiMaterial.ImmersiveMaterial` —— 同一套沉浸光感体系，
 * 最终观感同样由「系统设置里的光感强度 + 设备算力档 + 应用级材质开关」共同决定。
 *
 * ## 三、三条被踩过的硬规则
 *
 * 1. 材质的视觉层级位于 `backgroundColor` / `backgroundBlurStyle` **之下** ——
 *    承载层必须显式 `Color.Transparent`，任何不透明底色都会把材质盖住；
 * 2. `systemMaterial` 要放在其他样式属性**之后**设置；
 * 3. 应用级 `disable` 时材质一律不渲染，这不是代码能绕过的，只能改 `module.json5` 重装 ——
 *    所以兜底判断里要看一眼状态，否则卡片会变成一块全透明的空壳。
 */

/**
 * 当前系统 API 是否 ≥ 26。
 *
 * `uiMaterial` 自 API 26.0.0 起提供；低于此版本取不到材质，调用方走毛玻璃兜底。
 */
export function isApi26OrAbove(): boolean {
  try {
    return deviceInfo.sdkApiVersion >= 26;
  } catch (error) {
    return false;
  }
}

/** 系统材质状态；只查一次并缓存（它来自安装包里的配置，运行期不会变化）。 */
let stateCache: uiMaterial.MaterialState | null = null;
let stateResolved: boolean = false;

export function systemMaterialState(): uiMaterial.MaterialState | null {
  if (!stateResolved) {
    stateResolved = true;
    try {
      stateCache = uiMaterial.getMaterialInfo().state;
    } catch (error) {
      stateCache = null;
    }
  }
  return stateCache;
}

/**
 * 应用的沉浸材质是否被全局关闭（`module.json5` 里配了 `ohos.arkui.UIMaterial.state = disable`）。
 *
 * 只用来决定「要不要走毛玻璃兜底」，**不作为渲染开关** —— 状态是 DISABLE 时材质确实画不出来，
 * 但那是配置问题（要改 `module.json5` 重装），不是应用该主动放弃渲染的理由。
 */
export function isSystemMaterialDisabled(): boolean {
  if (!isApi26OrAbove()) {
    return false;
  }
  return systemMaterialState() === uiMaterial.MaterialState.DISABLE;
}

/**
 * 材质档位。
 *
 * **必须惰性求值，不能写成模块级常量。** 写成 `export const STYLE = uiMaterial.ImmersiveStyle.THIN`
 * 会在**模块加载期**就解引用 API 26 才有的接口，低版本设备上抛出的异常发生在任何
 * try/catch 之外，直接让模块加载失败、应用启动即闪退。
 */
function materialStyle(): uiMaterial.ImmersiveStyle {
  // REGULAR（系统默认档）：既能看出通透的玻璃感，又不会像 THIN 那样在本应用的
  // 纯黑 / 纯白底上「几乎看不见」。想要更实或更透，只改这一处。
  return uiMaterial.ImmersiveStyle.REGULAR;
}

/**
 * 构造材质。刻意**只传 style 与 applyShadow**：
 * `materialColor` 会把卡片叠成灰色（通透感来自材质自身的滤镜）；
 * `interactive: true` 配一个空的 `lightEffect` 实测会让材质**完全不渲染**。
 */
function buildImmersiveMaterial(withShadow: boolean): uiMaterial.Material | null {
  try {
    return new uiMaterial.ImmersiveMaterial({
      style: materialStyle(),
      applyShadow: withShadow
    });
  } catch (error) {
    Logger.warn('沉浸材质构造失败：' + (error as Error).message);
    return null;
  }
}

let materialCache: uiMaterial.Material | null = null;
let materialResolved: boolean = false;
let flatMaterialCache: uiMaterial.Material | null = null;
let flatMaterialResolved: boolean = false;

/**
 * 取沉浸材质（惰性构造 + 缓存）。
 *
 * 构造失败或 API < 26 返回 `null` —— 调用方据此降级为毛玻璃。
 * **绝不返回 `Material.empty`**：那等于「显式不画」，会把失败伪装成静默失效。
 *
 * @param withShadow 是否保留材质自带的投影（`applyShadow` 默认 true）
 */
export function getImmersiveMaterial(withShadow: boolean = true): uiMaterial.Material | null {
  if (!isApi26OrAbove()) {
    return null;
  }
  if (!withShadow) {
    if (!flatMaterialResolved) {
      flatMaterialResolved = true;
      flatMaterialCache = buildImmersiveMaterial(false);
    }
    logDiagnosticsOnce();
    return flatMaterialCache;
  }
  if (!materialResolved) {
    materialResolved = true;
    materialCache = buildImmersiveMaterial(true);
  }
  logDiagnosticsOnce();
  return materialCache;
}

/**
 * 沉浸材质当前是否可用：API ≥ 26、应用级没被 DISABLE、材质构造成功。
 *
 * 三个条件任意一条不成立，承载层都画不出东西，必须走毛玻璃兜底。
 */
export function immersiveMaterialActive(withShadow: boolean = true): boolean {
  return isApi26OrAbove() && !isSystemMaterialDisabled() && getImmersiveMaterial(withShadow) !== null;
}

/**
 * 把沉浸材质挂到承载组件上。
 *
 * ⚠️ **承载组件必须是按钮 / 选择类**（本项目统一用 `ToggleType.Button`），
 * 挂在 `Column` / `Row` 上不生效且不报错 —— 见文件头说明。
 *
 * @param instance 承载组件的属性实例（`attributeModifier` 里拿到的那个）
 * @param fallbackBlur 材质不可用时是否补一层毛玻璃兜底
 * @param withShadow 是否保留材质自带投影
 */
export function applyMaterialCarrier(
  instance: CommonAttribute,
  fallbackBlur: boolean = true,
  withShadow: boolean = true
): void {
  const material: uiMaterial.Material | null = getImmersiveMaterial(withShadow);
  if (material !== null && !isSystemMaterialDisabled()) {
    instance.systemMaterial(material);
  } else if (fallbackBlur) {
    instance.backgroundBlurStyle(BlurStyle.Thin);
  }
}

/**
 * 给**系统弹层**取材质（`AlertDialog` / `ActionSheet` / 选择器 / `Select` 菜单…）。
 *
 * 这些弹层的底板由系统绘制，我们塞不进承载层，只能把材质**传进去**：
 * - `AlertDialogParam.systemMaterial`（API 26 起）
 * - `SelectAttribute.menuSystemMaterial`
 * - Toast 的 `ShowToastOptions.systemMaterial`
 *
 * 三者用的是同一份材质实例（同一个档位），所以观感一致；取不到时返回 `undefined` =
 * 保留系统原本外观（**不要**返回 `Material.empty()`，那等于显式声明「不画」，弹层会变透明）。
 */
export function dialogMaterial(): uiMaterial.Material | undefined {
  return selectMenuMaterial();
}

/** 诊断文案只打一次，避免每帧刷屏。 */
let diagnosticsLogged: boolean = false;

/**
 * 给 `Select` 的**下拉菜单**取材质（`SelectAttribute.menuSystemMaterial`，API 26 起）。
 *
 * 与卡片那套的区别：菜单由系统弹出，我们**没法塞承载层进去**，但系统给 `Select` 留了
 * 这个口子 —— 传材质后菜单的底色 / 边框 / 阴影都换成同一套沉浸光感。
 *
 * ⚠️ 取不到材质要返回 `undefined`（= 保留系统原本的菜单外观），
 * **不要**返回 `Material.empty()` —— 那等于显式声明「什么都不画」，菜单会变成透明空壳。
 * 一样要惰性求值（见 `materialStyle()` 的说明）。
 */
export function selectMenuMaterial(): uiMaterial.Material | undefined {
  if (!isApi26OrAbove() || isSystemMaterialDisabled()) {
    return undefined;
  }
  const material: uiMaterial.Material | null = getImmersiveMaterial(false);
  return material === null ? undefined : material;
}

/**
 * 往 hilog 打一行沉浸光感的判定条件，真机上排查「为什么没生效」时看它。
 * 形如：`沉浸光感 API=26 状态=非DISABLE 材质=已构造 承载=可用`。
 *
 * 只读缓存、不回调 `getImmersiveMaterial()` —— 否则两者互相调用，容易把自己绕进去。
 */
function logDiagnosticsOnce(): void {
  if (diagnosticsLogged) {
    return;
  }
  diagnosticsLogged = true;
  const state: uiMaterial.MaterialState | null = systemMaterialState();
  let stateText: string = 'null(接口不可用)';
  if (state !== null) {
    stateText = state === uiMaterial.MaterialState.DISABLE ? 'DISABLE(全局关闭)' : '非DISABLE';
  }
  const built: boolean = materialResolved && materialCache !== null;
  const carrier: boolean = built && state !== uiMaterial.MaterialState.DISABLE;
  Logger.info('沉浸光感 API=' + deviceInfo.sdkApiVersion + ' 状态=' + stateText +
    ' 材质=' + (built ? '已构造' : '构造失败') + ' 承载=' + (carrier ? '可用' : '降级毛玻璃'));
}
