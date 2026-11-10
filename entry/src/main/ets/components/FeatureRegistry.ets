import { AppColor } from './AppTheme';
import { RouteName } from '../common/AppRouter';

/**
 * 校园功能入口清单。
 *
 * `route` 为空串表示尚未打通（点击只会给「敬请期待」提示）。**没实现的入口不再挂出来**：
 * 希冀平台 / 研讨室预约在原版 UBAA 里也只是占位，先在注册表里移除，
 * 等真有实现再连同 `route` 一起加回来 —— 半成品入口比没有入口更伤体验。
 * （图书馆座位已于 2026-10-25 实现并挂回注册表。）
 * 图标沿用 UBAA 的 Material 图标风格（app.media.ic_*）。
 */
export interface FeatureItem {
  title: string;
  desc: string;
  icon: Resource;
  color: Resource;
  /** 目标路由名；为空表示暂未实现。 */
  route: string;
  /** 一级分组。 */
  group: string;
}

const GROUP_BASIC: string = '普通功能';
const GROUP_ADVANCED: string = '高级功能';

export function basicFeatures(): FeatureItem[] {
  return [
    {
      title: '考试安排',
      desc: '查看本学期考试时间与座位',
      icon: $r('app.media.ic_event'),
      color: AppColor.accentPurple,
      route: RouteName.EXAM,
      group: GROUP_BASIC
    },
    {
      title: '成绩查询',
      desc: '按学期查看成绩与学分',
      icon: $r('app.media.ic_grade'),
      color: AppColor.accentGreen,
      route: RouteName.GRADE,
      group: GROUP_BASIC
    },
    {
      title: '空闲教室',
      desc: '按日期查询空闲教室',
      icon: $r('app.media.ic_meeting_room'),
      color: AppColor.accentYellow,
      route: RouteName.CLASSROOM,
      group: GROUP_BASIC
    },
    // 希冀作业（RouteName.JUDGE）暂不挂入口：2026-10-26 真机实测 judge 已改版为 SPA，
    // courselist.jsp 会被 302 回 main.jsp，旧 HTML 解析拿不到课程列表；等新接口摸清后再挂回。
    {
      title: '个人资料',
      desc: '学籍信息与联系方式',
      icon: $r('app.media.ic_person'),
      color: AppColor.brand,
      route: RouteName.USER_INFO,
      group: GROUP_BASIC
    }
  ];
}

export function advancedFeatures(): FeatureItem[] {
  return [
    {
      title: '课堂签到',
      desc: '查看今日课堂并一键签到',
      icon: $r('app.media.ic_schedule'),
      color: AppColor.accentPink,
      route: RouteName.SIGNIN,
      group: GROUP_ADVANCED
    },
    {
      title: '博雅课程',
      desc: '博雅课程查询与选课',
      icon: $r('app.media.ic_menu_book'),
      color: AppColor.accentPink,
      route: RouteName.BYKC,
      group: GROUP_ADVANCED
    },
    {
      title: '图书馆座位',
      desc: '预约座位与查看我的预约',
      icon: $r('app.media.ic_schedule'),
      color: AppColor.accentPurple,
      route: RouteName.LIBBOOK_HOME,
      group: GROUP_ADVANCED
    },
    {
      title: 'SPOC',
      desc: '在线课程作业与提交状态',
      icon: $r('app.media.ic_school'),
      color: AppColor.brandLight,
      route: RouteName.SPOC,
      group: GROUP_ADVANCED
    },
    {
      title: '自动评教',
      desc: '一键完成待评课程的评教',
      icon: $r('app.media.ic_assignment'),
      color: AppColor.accentGreen,
      route: RouteName.EVALUATION,
      group: GROUP_ADVANCED
    },
    {
      title: 'iHome',
      desc: '校园诉求、回复与处理进度',
      icon: $r('app.media.ic_person'),
      color: AppColor.accentYellow,
      route: RouteName.IHOME,
      group: GROUP_ADVANCED
    },
    {
      title: '阳光打卡',
      desc: '查看学期打卡次数与记录',
      icon: $r('app.media.ic_home'),
      color: AppColor.accentPink,
      route: RouteName.YGDK,
      group: GROUP_ADVANCED
    }
  ];
}

/** 排序用的临时结构（功能项 + 默认次序 + 使用次数）。 */
interface FeatureSlot {
  item: FeatureItem;
  order: number;
  count: number;
}

/**
 * 首页「快捷入口」：取 8 个，**按使用次数降序**（常用的浮到前面）。
 *
 * 次数相同的保持注册表里的默认顺序（稳定排序），所以「一次没用过」时与原来完全一致。
 * 用次数而不是时间：同一个功能反复用才说明它常用，只看最近一次会让顺序频繁抖动。
 */
export function quickFeatures(usage: Record<string, number>): FeatureItem[] {
  const all: FeatureItem[] = basicFeatures().concat(advancedFeatures());
  const slots: FeatureSlot[] = [];
  for (let i = 0; i < all.length; i++) {
    const count: number | undefined = usage[all[i].title];
    slots.push({
      item: all[i],
      order: i,
      count: count === undefined || count === null ? 0 : count
    });
  }
  slots.sort((a: FeatureSlot, b: FeatureSlot): number => {
    if (a.count !== b.count) {
      return b.count - a.count;
    }
    return a.order - b.order;
  });

  const result: FeatureItem[] = [];
  for (let i = 0; i < slots.length && i < QUICK_FEATURE_COUNT; i++) {
    result.push(slots[i].item);
  }
  return result;
}

/** 首页快捷入口个数（4 列 × 2 行）。 */
const QUICK_FEATURE_COUNT: number = 8;

export function groupName(group: string): string {
  return group;
}
