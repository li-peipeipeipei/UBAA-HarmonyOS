import { common } from '@kit.AbilityKit';

/**
 * 持有 UIAbilityContext 的全局单例。
 *
 * ArkTS 中没有全局变量机制，Preferences 等需要 Context 的能力
 * 统一从 EntryAbility.onCreate 注入到这里。
 */
export class GlobalContext {
  private static context: common.UIAbilityContext | null = null;

  static setContext(context: common.UIAbilityContext): void {
    GlobalContext.context = context;
  }

  static getContext(): common.UIAbilityContext {
    if (GlobalContext.context === null) {
      throw new Error('GlobalContext 尚未初始化，请确认 EntryAbility 已调用 setContext');
    }
    return GlobalContext.context;
  }

  static isReady(): boolean {
    return GlobalContext.context !== null;
  }
}
