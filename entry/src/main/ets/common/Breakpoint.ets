/**
 * 响应式断点（窗口宽度，单位 vp）。
 *
 * 只做纯计算与键名定义：**不 import 任何 UI / Ability 模块**，
 * 以便 AppTheme（被 30+ 页面引用）与 ImmersiveUtil 都能安全依赖它。
 *
 * 阈值依据：
 * - 600vp：NavigationMode.Auto / SideBarContainerType.AUTO 的系统断点；
 * - 840vp：GridRow 默认 lg 断点；
 * - 1200vp：2in1 / 超大平板横屏。
 *
 * 实测设备（2026-11-09）：
 * - 手机 PLR-AL50：1316×2832 / 3.5 → 376vp → sm
 * - 平板 MLR-AL10（MatePad Mini）：1600×2560 / 2.375 → 673vp → md
 *   横屏 2560×1600 → 1077vp → lg
 */

/** AppStorage 键：窗口宽度（vp）。 */
export const KEY_WINDOW_WIDTH_VP: string = 'windowWidthVp';
/** AppStorage 键：窗口高度（vp）。 */
export const KEY_WINDOW_HEIGHT_VP: string = 'windowHeightVp';
/** AppStorage 键：当前断点名 sm / md / lg / xxl。 */
export const KEY_BREAKPOINT: string = 'breakpoint';
/** AppStorage 键：是否走宽屏分支（bp !== 'sm'）。 */
export const KEY_IS_WIDE_SCREEN: string = 'isWideScreen';
/** AppStorage 键：是否启用 HdsNavigation Split 双栏。 */
export const KEY_NAV_SPLIT_MODE: string = 'navSplitMode';

export const BP_SM_MAX: number = 600;
export const BP_MD_MAX: number = 840;
export const BP_LG_MAX: number = 1200;

/** 宽度（vp）→ 断点名。纯函数，便于日志核对。 */
export function widthToBreakpoint(wVp: number): string {
  if (wVp < BP_SM_MAX) {
    return 'sm';
  }
  if (wVp < BP_MD_MAX) {
    return 'md';
  }
  if (wVp < BP_LG_MAX) {
    return 'lg';
  }
  return 'xxl';
}

export function isWideBreakpoint(bp: string): boolean {
  return bp !== 'sm';
}

export function isSplitBreakpoint(bp: string): boolean {
  return bp === 'lg' || bp === 'xxl';
}

/** 侧边导航宽度（vp）：md 只放图标，lg/xxl 带文字。 */
export function sideNavWidthOf(bp: string): number {
  return bp === 'md' ? 72 : 240;
}

/** 列表栏（navBar）宽度（vp）。 */
export function navBarWidthOf(bp: string): number {
  return bp === 'xxl' ? 400 : 360;
}
