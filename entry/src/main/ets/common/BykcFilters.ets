import { BykcCourse } from '../model/ApiTypes';

/**
 * 博雅课程筛选（对齐原版 `BykcCourseFilters.kt`）。
 *
 * 三个维度：**状态 / 类别 / 校区**，各自多选，**取交集**。
 *
 * ## 为什么要按「枚举名」而不是中文文案筛
 *
 * `statusText` 是展示用的中文（「可选」「已选」…），逻辑上不可靠 ——
 * 筛选必须按 `status` 枚举名（`AVAILABLE` / `SELECTED` / `PREVIEW` / `FULL` / `ENDED` / `EXPIRED`）。
 */

/** 状态显示顺序（与原版 `bykcStatusOrder` 一致）。 */
export const BYKC_STATUS_ORDER: string[] =
  ['PREVIEW', 'AVAILABLE', 'FULL', 'SELECTED', 'ENDED', 'EXPIRED'];

/** 状态枚举名 → 展示文案。 */
export const BYKC_STATUS_LABEL: Record<string, string> = {
  'PREVIEW': '预告',
  'AVAILABLE': '可选',
  'FULL': '人数已满',
  'SELECTED': '已选',
  'ENDED': '选课结束',
  'EXPIRED': '已过期'
};

/** 类别（小类）固定顺序：德育 → 美育 → 劳动教育 → 安全健康 → 其他方面。 */
export const BYKC_CATEGORY_ORDER: string[] = ['德育', '美育', '劳动教育', '安全健康', '其他方面'];

/** 校区排序 rank：学院路 → 沙河 → 杭州 → 未指定校区 → 其他。 */
export function bykcCampusRank(label: string): number {
  if (label.indexOf('学院路') === 0) {
    return 0;
  }
  if (label.indexOf('沙河') === 0) {
    return 1;
  }
  if (label.indexOf('杭州') === 0) {
    return 2;
  }
  if (label === '未指定校区') {
    return 3;
  }
  return 4;
}

/** 筛选条件。空集合 = **不限**（不是「什么都不选」）。 */
export interface BykcFilters {
  /** 状态枚举名集合。 */
  statuses: string[];
  /** 类别（小类中文名）集合。 */
  categories: string[];
  /** 校区集合。 */
  campuses: string[];
}

/** 默认筛选：已选 + 预告 + 人数已满 + 可选（**不含**选课结束 / 已过期）。 */
export function defaultBykcFilters(): BykcFilters {
  return {
    statuses: ['SELECTED', 'PREVIEW', 'FULL', 'AVAILABLE'],
    categories: [],
    campuses: []
  };
}

/** 空筛选（三个维度都不限）。 */
export function emptyBykcFilters(): BykcFilters {
  return { statuses: [], categories: [], campuses: [] };
}

/** 有没有任何一项被选中（区分于「不限」）。 */
export function bykcHasActiveSelections(filters: BykcFilters): boolean {
  return filters.statuses.length > 0 || filters.categories.length > 0 || filters.campuses.length > 0;
}

/**
 * 是否需要把「已结束 / 已过期」的课也拉回来。
 *
 * 状态不限、或显式选了 `ENDED` / `EXPIRED` 时都要 ——
 * 否则上游默认把那批课过滤掉，用户选了却看不到。
 */
export function bykcRequiresAllCourses(filters: BykcFilters): boolean {
  if (filters.statuses.length === 0) {
    return true;
  }
  return filters.statuses.indexOf('EXPIRED') >= 0 || filters.statuses.indexOf('ENDED') >= 0;
}

/**
 * 课程在列表里是不是显示成「人数已满」。
 *
 * 上游的 `status` 可能是 `AVAILABLE` 但名额实际已满（统计与状态不同步），
 * 这时要按「人数已满」显示与筛选。
 */
export function bykcIsDisplayedAsFull(course: BykcCourse): boolean {
  const current: number = course.currentCount === undefined ? 0 : course.currentCount;
  const full: boolean = current > 0 && course.maxCount > 0 && current >= course.maxCount;
  return course.status === 'FULL' || (course.status === 'AVAILABLE' && full);
}

/** 状态匹配（两个状态有特殊规则，见原版 `matchesStatus`）。 */
export function bykcMatchesStatus(course: BykcCourse, status: string): boolean {
  if (status === 'FULL') {
    return !course.selected && bykcIsDisplayedAsFull(course);
  }
  if (status === 'AVAILABLE') {
    return course.status === 'AVAILABLE' && !bykcIsDisplayedAsFull(course);
  }
  return course.status === status;
}

/** 类别匹配用的标签：**小类优先**，没有小类才用大类。 */
export function bykcCategoryLabel(course: BykcCourse): string {
  if (course.subCategory !== undefined && course.subCategory.length > 0) {
    return course.subCategory;
  }
  if (course.category !== undefined && course.category.length > 0) {
    return course.category;
  }
  return '';
}

/** 一门课是否命中当前筛选（三个维度取交集）。 */
export function bykcMatchesFilters(course: BykcCourse, filters: BykcFilters): boolean {
  if (filters.statuses.length > 0) {
    let hit = false;
    for (let i = 0; i < filters.statuses.length; i++) {
      if (bykcMatchesStatus(course, filters.statuses[i])) {
        hit = true;
        break;
      }
    }
    if (!hit) {
      return false;
    }
  }
  if (filters.categories.length > 0) {
    if (filters.categories.indexOf(bykcCategoryLabel(course)) < 0) {
      return false;
    }
  }
  if (filters.campuses.length > 0) {
    let hit = false;
    for (let i = 0; i < course.campuses.length; i++) {
      if (filters.campuses.indexOf(course.campuses[i]) >= 0) {
        hit = true;
        break;
      }
    }
    if (!hit) {
      return false;
    }
  }
  return true;
}

/** 过滤课程列表。 */
export function filterBykcCourses(courses: BykcCourse[], filters: BykcFilters): BykcCourse[] {
  const out: BykcCourse[] = [];
  for (let i = 0; i < courses.length; i++) {
    if (bykcMatchesFilters(courses[i], filters)) {
      out.push(courses[i]);
    }
  }
  return out;
}

/**
 * 从课程列表里提取筛选面板的可选项。
 *
 * - **类别**：固定五个（不管当前列表里有没有）；
 * - **校区**：课程里出现过的 + 已选中的（已选的即使当前列表没有也要留着）。
 */
export function buildBykcFilterOptions(courses: BykcCourse[], selectedCampuses: string[]): string[] {
  const all: string[] = [];
  for (let i = 0; i < courses.length; i++) {
    for (let j = 0; j < courses[i].campuses.length; j++) {
      const text: string = courses[i].campuses[j].trim();
      if (text.length > 0 && all.indexOf(text) < 0) {
        all.push(text);
      }
    }
  }
  for (let i = 0; i < selectedCampuses.length; i++) {
    const text: string = selectedCampuses[i].trim();
    if (text.length > 0 && all.indexOf(text) < 0) {
      all.push(text);
    }
  }
  all.sort((a: string, b: string) => {
    const ra: number = bykcCampusRank(a);
    const rb: number = bykcCampusRank(b);
    if (ra !== rb) {
      return ra - rb;
    }
    return a.localeCompare(b);
  });
  return all;
}

/** 切换某个状态的选中态。 */
export function toggleBykcStatus(filters: BykcFilters, status: string): BykcFilters {
  const next: string[] = filters.statuses.slice();
  const i: number = next.indexOf(status);
  if (i >= 0) {
    next.splice(i, 1);
  } else {
    next.push(status);
  }
  return { statuses: next, categories: filters.categories, campuses: filters.campuses };
}

/** 切换某个类别的选中态。 */
export function toggleBykcCategory(filters: BykcFilters, category: string): BykcFilters {
  const next: string[] = filters.categories.slice();
  const i: number = next.indexOf(category);
  if (i >= 0) {
    next.splice(i, 1);
  } else {
    next.push(category);
  }
  return { statuses: filters.statuses, categories: next, campuses: filters.campuses };
}

/** 切换某个校区的选中态。 */
export function toggleBykcCampus(filters: BykcFilters, campus: string): BykcFilters {
  const next: string[] = filters.campuses.slice();
  const i: number = next.indexOf(campus);
  if (i >= 0) {
    next.splice(i, 1);
  } else {
    next.push(campus);
  }
  return { statuses: filters.statuses, categories: filters.categories, campuses: next };
}

/** 状态集合按显示顺序排好（持久化用）。 */
export function sortBykcStatuses(statuses: string[]): string[] {
  const out: string[] = [];
  for (let i = 0; i < BYKC_STATUS_ORDER.length; i++) {
    if (statuses.indexOf(BYKC_STATUS_ORDER[i]) >= 0) {
      out.push(BYKC_STATUS_ORDER[i]);
    }
  }
  return out;
}

/** 类别集合按固定顺序排好。 */
export function sortBykcCategories(categories: string[]): string[] {
  const out: string[] = [];
  for (let i = 0; i < BYKC_CATEGORY_ORDER.length; i++) {
    if (categories.indexOf(BYKC_CATEGORY_ORDER[i]) >= 0) {
      out.push(BYKC_CATEGORY_ORDER[i]);
    }
  }
  // 不在固定列表里的（上游新增的类别）排最后
  for (let i = 0; i < categories.length; i++) {
    if (out.indexOf(categories[i]) < 0) {
      out.push(categories[i]);
    }
  }
  return out;
}

/** 校区集合按 rank 排好。 */
export function sortBykcCampuses(campuses: string[]): string[] {
  const out: string[] = campuses.slice();
  out.sort((a: string, b: string) => {
    const ra: number = bykcCampusRank(a);
    const rb: number = bykcCampusRank(b);
    if (ra !== rb) {
      return ra - rb;
    }
    return a.localeCompare(b);
  });
  return out;
}
