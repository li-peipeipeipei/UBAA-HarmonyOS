import { promptAction, uiMaterial } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { Logger } from './Logger';
import { getImmersiveMaterial, isApi26OrAbove, isSystemMaterialDisabled } from './SystemMaterial';

/**
 * 轻量提示封装（**系统 Toast**）。
 *
 * ## 沉浸光感
 *
 * `ShowToastOptions.systemMaterial`（API 26 起）可以把**系统沉浸材质**直接交给 Toast
 * —— 类型就是 `uiMaterial.Material`（SDK 里 `declare type SystemUiMaterial = uiMaterial.Material`）。
 * 于是「欢迎回来，xxx」这类小条形提示也跟面板 / 卡片用同一套光感，不用自己造一个浮层。
 *
 * ⚠️ 三条注意：
 * 1. 材质**必须惰性取**（`getImmersiveMaterial()` 内部已经做了惰性构造 + 缓存）——
 *    写成模块级常量会在低版本设备上启动即闪退；
 * 2. 拿不到材质（API < 26 / 应用级 DISABLE）时**不要传** `systemMaterial`，让系统用默认底色 ——
 *    否则提示会变成一片透明的空壳；
 * 3. 材质可用时把 `backgroundColor` 显式设为透明：材质的绘制层级在底**之下**，
 *    留着不透明底色会把材质整个盖住（与卡片那条规则同源）。
 */
export class Toast {
  /** 弹出一条文本提示。默认时长 2000ms。 */
  static show(message: string, duration: number = 2000): void {
    const material: uiMaterial.Material | null = Toast.material();
    const options: promptAction.ShowToastOptions = material === null
      ? { message: message, duration: duration }
      : {
        message: message,
        duration: duration,
        systemMaterial: material,
        backgroundColor: Color.Transparent
      };
    promptAction.openToast(options)
      .catch((error: BusinessError) => {
        Logger.warn('提示显示失败：' + error.message);
      });
  }

  /** 取沉浸材质；不可用返回 `null`（调用方据此走系统默认外观）。 */
  private static material(): uiMaterial.Material | null {
    if (!isApi26OrAbove() || isSystemMaterialDisabled()) {
      return null;
    }
    return getImmersiveMaterial(false);
  }
}
