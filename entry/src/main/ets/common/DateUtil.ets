/**
 * 日期工具。
 *
 * 服务端返回的日期均为本地日期字符串（yyyy-MM-dd），
 * 这里只做「按天」计算，避免时区带来的偏差。
 */
export class DateUtil {
  private static readonly DAY_MILLIS: number = 86400000;

  static pad(value: number): string {
    return value < 10 ? '0' + value.toString() : value.toString();
  }

  static format(date: Date): string {
    return date.getFullYear().toString() + '-' +
      DateUtil.pad(date.getMonth() + 1) + '-' +
      DateUtil.pad(date.getDate());
  }

  static today(): string {
    return DateUtil.format(new Date());
  }

  static addDays(date: Date, days: number): Date {
    const next = new Date(date.getTime());
    next.setDate(next.getDate() + days);
    return next;
  }

  /** 解析 yyyy-MM-dd；也兼容 "2026-06-15 08:00" 这类带时间的前缀。 */
  static parse(text: string): Date | null {
    if (text.length < 10) {
      return null;
    }
    const year = parseInt(text.substring(0, 4));
    const month = parseInt(text.substring(5, 7));
    const day = parseInt(text.substring(8, 10));
    if (Number.isNaN(year) || Number.isNaN(month) || Number.isNaN(day)) {
      return null;
    }
    return new Date(year, month - 1, day);
  }

  /** 距离目标日期还有几天（负数表示已过去）。 */
  static daysUntil(text: string): number | null {
    const target = DateUtil.parse(text);
    if (target === null) {
      return null;
    }
    const now = new Date();
    const today = new Date(now.getFullYear(), now.getMonth(), now.getDate());
    return Math.round((target.getTime() - today.getTime()) / DateUtil.DAY_MILLIS);
  }

  /** 倒计时文案。 */
  static countdownText(text: string): string {
    const days = DateUtil.daysUntil(text);
    if (days === null) {
      return '待定';
    }
    if (days < 0) {
      return '已结束';
    }
    if (days === 0) {
      return '今天';
    }
    return days.toString() + ' 天后';
  }

  static weekdayNames(): string[] {
    return ['周一', '周二', '周三', '周四', '周五', '周六', '周日'];
  }

  /** 当前是周几（1 = 周一，7 = 周日）。 */
  static currentWeekday(): number {
    const day = new Date().getDay();
    return day === 0 ? 7 : day;
  }

  /** 节次区间文案，如「3-4 节」。 */
  static sectionRange(begin: number, end: number): string {
    if (begin <= 0) {
      return '';
    }
    if (end > begin) {
      return begin.toString() + '-' + end.toString() + ' 节';
    }
    return begin.toString() + ' 节';
  }
}
