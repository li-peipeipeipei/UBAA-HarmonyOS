import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x1234;
const TAG: string = 'UBAA';

/** 统一日志封装，避免业务代码直接依赖 hilog 的 domain 常量。 */
export class Logger {
  static debug(message: string): void {
    hilog.debug(DOMAIN, TAG, '%{public}s', message);
  }

  static info(message: string): void {
    hilog.info(DOMAIN, TAG, '%{public}s', message);
  }

  static warn(message: string): void {
    hilog.warn(DOMAIN, TAG, '%{public}s', message);
  }

  static error(message: string): void {
    hilog.error(DOMAIN, TAG, '%{public}s', message);
  }

  /** 脱敏手机号 / 学号，仅保留首尾字符。 */
  static mask(value: string): string {
    if (value.length <= 2) {
      return '**';
    }
    if (value.length <= 6) {
      return value.substring(0, 1) + '****' + value.substring(value.length - 1);
    }
    return value.substring(0, 3) + '****' + value.substring(value.length - 3);
  }
}
