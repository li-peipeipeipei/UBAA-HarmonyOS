import { formBindingData, FormExtensionAbility, formInfo, formProvider } from '@kit.FormKit';
import { Want } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { CardCache } from '../common/CardCache';

const DOMAIN_NUMBER: number = 0x0100;
const TAG: string = 'UBAAForm';

/**
 * 推给卡片的扁平数据。
 *
 * ⚠️ 官方明确：卡片侧 `@LocalStorageProp` 收到的值**会被转换成 string**，
 * 所以这里只放 string，复杂结构（课表数组）由主应用 `JSON.stringify` 后传过来，
 * 卡片侧再 `JSON.parse`。这样最稳，避开任何序列化差异。
 *
 * 另注：ArkTS 不允许把对象字面量直接赋给 `Record<K, V>`，
 * 所以要先声明 interface 再写字面量。
 */
interface CardPayload {
  /** 今天概览 + 课程数组的 JSON 串；没有缓存时为空串。 */
  scheduleJson: string;
  /** 形如 `第6周 · 10月15日 周三`。 */
  weekLabel: string;
  /** 数据更新时间，形如 `10月15日 07:30`。 */
  updatedAt: string;
  /** 最近一场考试的 JSON 串（考试卡用）。 */
  examJson: string;
  /** 本学期成绩概览的 JSON 串（成绩卡用）。 */
  gradeJson: string;
  /** 空闲教室的 JSON 串（教室卡用）。 */
  classroomJson: string;
  /** 周课表（一整周七天）的 JSON 串（周课表卡用）。 */
  weekViewJson: string;
  /** 日课表（某一天全天）的 JSON 串（日课表卡用）。 */
  dayViewJson: string;
}

/**
 * 桌面服务卡片的提供方（FormExtensionAbility）。
 *
 * ## 职责边界（很重要）
 *
 * 这个进程**只做三件事**：记住有哪些卡片、读取主应用写好的缓存、把缓存推给卡片 UI。
 * **它不联网、不解密、不碰登录链路** ——
 * 官方明写 FormExtensionAbility 回调后只存活 5~10 秒，
 * 而取课表要走 CAS 登录 + Cookie 跳转 + 解密，必然超时。
 *
 * ## 为什么 import 链这么短
 *
 * 官方 FAQ 原文：「ArkTS 卡片的 FormExtensionAbility **不支持加载**
 * particleAbility、audio、camera、media、backgroundTaskManager 等模块。
 * 强行加载得到的对象是 undefined，使用时就会产生 JS crash。」
 * 所以这里只引 FormKit / AbilityKit / hilog 和一个纯 Preferences 的 CardCache，
 * 绝不间接引到项目里那些会带上网络栈、加密栈的文件。
 */
export default class UBAAFormAbility extends FormExtensionAbility {
  /**
   * 用户把卡片拖到桌面时触发。
   *
   * 这里必须**同步返回**数据（签名不是 Promise，没法 await），
   * 所以直接同步读 Preferences —— 主应用把课表写进去，这里才读得到。
   */
  onAddForm(want: Want): formBindingData.FormBindingData {
    const params = want.parameters;
    if (params === undefined) {
      hilog.warn(DOMAIN_NUMBER, TAG, 'onAddForm: want.parameters 为空');
      return formBindingData.createFormBindingData(this.buildPayload());
    }
    const formId = params[formInfo.FormParam.IDENTITY_KEY] as string;
    const name = params[formInfo.FormParam.NAME_KEY] as string;
    hilog.info(DOMAIN_NUMBER, TAG, 'onAddForm: name=%{public}s formId=%{public}s', name, formId);
    // 记下这张卡片，主应用之后才知道该往哪些 formId 推数据
    CardCache.addFormId(this.context, formId);
    return formBindingData.createFormBindingData(this.buildPayload());
  }

  /**
   * 定时 / 定点 / 主动刷新时触发。
   *
   * 只读缓存、只推数据，**不做任何网络请求**。
   */
  onUpdateForm(formId: string): void {
    hilog.info(DOMAIN_NUMBER, TAG, 'onUpdateForm: %{public}s', formId);
    this.push(formId);
  }

  /** 用户移除卡片时触发 —— 必须清掉持久化的 formId，否则会越攒越多。 */
  onRemoveForm(formId: string): void {
    hilog.info(DOMAIN_NUMBER, TAG, 'onRemoveForm: %{public}s', formId);
    CardCache.removeFormId(this.context, formId);
  }

  /** 卡片内 `postCardAction({action:'message'})` 时触发。 */
  onFormEvent(formId: string, message: string): void {
    hilog.info(DOMAIN_NUMBER, TAG, 'onFormEvent: %{public}s', message);
    this.push(formId);
  }

  /** 卡片状态查询：直接报就绪。 */
  onAcquireFormState(want: Want): formInfo.FormState {
    return formInfo.FormState.READY;
  }

  /** 组一份扁平数据（**只放 string**）。 */
  private buildPayload(): CardPayload {
    const today = CardCache.loadToday(this.context);
    const exam = CardCache.loadExam(this.context);
    const grade = CardCache.loadGrade(this.context);
    const room = CardCache.loadClassroom(this.context);
    const weekView = CardCache.loadWeekView(this.context);
    const dayView = CardCache.loadDayView(this.context);
    const payload: CardPayload = {
      scheduleJson: today === null ? '' : JSON.stringify(today),
      weekLabel: CardCache.weekLabel(this.context),
      updatedAt: CardCache.updatedAt(this.context),
      examJson: exam === null ? '' : JSON.stringify(exam),
      gradeJson: grade === null ? '' : JSON.stringify(grade),
      classroomJson: room === null ? '' : JSON.stringify(room),
      weekViewJson: weekView === null ? '' : JSON.stringify(weekView),
      dayViewJson: dayView === null ? '' : JSON.stringify(dayView)
    };
    return payload;
  }

  /** 把缓存推给指定卡片。 */
  private push(formId: string): void {
    const data = formBindingData.createFormBindingData(this.buildPayload());
    formProvider.updateForm(formId, data).catch((error: BusinessError) => {
      hilog.error(DOMAIN_NUMBER, TAG, 'updateForm 失败：code=%{public}d', error.code);
    });
  }
}