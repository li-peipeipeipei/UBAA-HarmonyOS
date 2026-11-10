import { Grade } from '../model/ApiTypes';

/**
 * 成绩统计 —— **口径与原版 UBAA 完全一致**（`GradeScreen.kt` 的 calculateGradeStatistics）。
 *
 * ## 为什么要照抄原版
 *
 * 上游给的是**分数字符串**（可能是数字，也可能是「优 / 良 / 中 / 及格 / 不及格 / 通过」），
 * GPA 不是直接读 `JD` 字段，而是**由分数换算**出来的 —— 换算规则（4.0 / 3.5 / 2.8 / 1.7 /
 * 4.0 - 3(100-x)²/1600）是学校口径，自己另算一套数字会跟教务系统对不上。
 */

/** 统计结果；null 表示「算不出来」（原版用 null → 显示 "--"）。 */
export interface GradeStatistics {
  /** 课程数（有几门课，不看学分是否 > 0）。 */
  courseCount: number;
  /** 总学分（只累加学分 > 0 的）。 */
  totalCredits: number;
  /** GPA：Σ(绩点×学分) / Σ学分。 */
  gpa: number | null;
  /** 加权平均分：Σ(分数×学分) / Σ学分。 */
  weightedAverage: number | null;
  /** 算术平均分：Σ分数 / 门数。 */
  arithmeticAverage: number | null;
}

/**
 * 等级分归一：原版把「优秀 / 良好 / 中等」统一成「优 / 良 / 中」再处理。
 */
export function normalizeLevelScore(score: string): string {
  const text: string = score.trim();
  if (text === '优秀') {
    return '优';
  }
  if (text === '良好') {
    return '良';
  }
  if (text === '中等') {
    return '中';
  }
  return text;
}

/**
 * 分数 → 绩点。
 *
 * - 优 4.0 / 良 3.5 / 中 2.8 / 及格 1.7 / 不及格 0.0
 * - 「通过 / 不通过」不算绩点（null，不计入任何加权）
 * - 数字：< 60 记 0；否则 `4.0 - 3.0 × (100 - x)² / 1600`
 */
export function scoreToGradePoint(score: string): number | null {
  const normalized: string = normalizeLevelScore(score);
  if (normalized === '优') {
    return 4.0;
  }
  if (normalized === '良') {
    return 3.5;
  }
  if (normalized === '中') {
    return 2.8;
  }
  if (normalized === '及格') {
    return 1.7;
  }
  if (normalized === '不及格') {
    return 0.0;
  }
  if (normalized === '通过' || normalized === '不通过') {
    return null;
  }
  const numeric: number = parseFloat(normalized);
  if (Number.isNaN(numeric)) {
    return null;
  }
  if (numeric < 60.0) {
    return 0.0;
  }
  return 4.0 - (3.0 * (100.0 - numeric) * (100.0 - numeric) / 1600.0);
}

/**
 * 分数 → 参与加权平均的数值。
 * 等级分折算成 90 / 80 / 70 / 60 / 0；「通过 / 不通过」不参与（null）。
 */
export function scoreToWeightedAverage(score: string): number | null {
  const normalized: string = normalizeLevelScore(score);
  if (normalized === '优') {
    return 90.0;
  }
  if (normalized === '良') {
    return 80.0;
  }
  if (normalized === '中') {
    return 70.0;
  }
  if (normalized === '及格') {
    return 60.0;
  }
  if (normalized === '不及格') {
    return 0.0;
  }
  if (normalized === '通过' || normalized === '不通过') {
    return null;
  }
  const numeric: number = parseFloat(normalized);
  if (Number.isNaN(numeric)) {
    return null;
  }
  return numeric;
}

/** 保留两位小数（与原版一致：先 ×100 取整再 ÷100）。 */
function weightedValue(total: number, credits: number): number | null {
  if (credits <= 0.0) {
    return null;
  }
  return Math.round((total / credits) * 100.0) / 100.0;
}

function averageValue(total: number, count: number): number | null {
  if (count <= 0) {
    return null;
  }
  return Math.round((total / count) * 100.0) / 100.0;
}

/**
 * 统计一批成绩。
 *
 * ⚠️ 与原版一致的口径细节：**学分 > 0、分数非空、且能换算出绩点与加权分**的课才参与统计；
 * 任何一环不满足，这门课就整门跳过（连学分也不进加权分母）。
 * 但「总学分」是单独算的 —— 学分 > 0 的课都会计入。
 */
export function calculateGradeStatistics(grades: Grade[]): GradeStatistics {
  let gpaWeightedTotal = 0.0;
  let gpaCreditTotal = 0.0;
  let scoreWeightedTotal = 0.0;
  let scoreCreditTotal = 0.0;
  let arithmeticScoreTotal = 0.0;
  let arithmeticScoreCount = 0;

  for (let i = 0; i < grades.length; i++) {
    const item: Grade = grades[i];
    const credit: number = item.XF !== undefined ? item.XF : 0;
    if (credit <= 0.0) {
      continue;
    }
    const score: string = item.XSZCJ !== undefined ? item.XSZCJ.trim() : '';
    if (score.length === 0) {
      continue;
    }
    const points: number | null = scoreToGradePoint(score);
    if (points === null) {
      continue;
    }
    const numericScore: number | null = scoreToWeightedAverage(score);
    if (numericScore === null) {
      continue;
    }
    gpaWeightedTotal += points * credit;
    gpaCreditTotal += credit;
    scoreWeightedTotal += numericScore * credit;
    scoreCreditTotal += credit;
    arithmeticScoreTotal += numericScore;
    arithmeticScoreCount += 1;
  }

  let totalCredits = 0.0;
  for (let i = 0; i < grades.length; i++) {
    const credit: number = grades[i].XF !== undefined ? grades[i].XF as number : 0;
    if (credit > 0.0) {
      totalCredits += credit;
    }
  }

  return {
    courseCount: grades.length,
    totalCredits: totalCredits,
    gpa: weightedValue(gpaWeightedTotal, gpaCreditTotal),
    weightedAverage: weightedValue(scoreWeightedTotal, scoreCreditTotal),
    arithmeticAverage: averageValue(arithmeticScoreTotal, arithmeticScoreCount)
  };
}

/**
 * 数字格式化（原版 formatNumber）：两位小数；整数就只显示整数。
 * 例：19 → "19"，32 → "32"，80.16 → "80.16"，1.5 → "1.5"
 */
export function formatNumber(value: number): string {
  const rounded: number = Math.round(value * 100.0) / 100.0;
  if (rounded % 1.0 === 0.0) {
    return rounded.toFixed(0);
  }
  return rounded.toString();
}

/**
 * 绩点格式化（原版 formatGradePoint）：固定两位小数（3.09 / 3.1 → "3.09" / "3.10"）。
 */
export function formatGradePoint(value: number): string {
  const rounded: number = Math.round(value * 100.0);
  const integerPart: number = Math.floor(rounded / 100);
  const decimalPart: number = Math.abs(rounded % 100);
  return integerPart.toString() + '.' + decimalPart.toString().padStart(2, '0');
}
