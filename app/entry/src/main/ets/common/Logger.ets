import { hilog } from '@kit.PerformanceAnalysisKit';

const DOMAIN: number = 0x1001;
const TAG: string = 'MEMI';

/** 统一日志出口，方便用 hdc hilog -T MEMI 过滤 */
export class Logger {
  static i(msg: string): void {
    hilog.info(DOMAIN, TAG, '%{public}s', msg);
  }

  static w(msg: string): void {
    hilog.warn(DOMAIN, TAG, '%{public}s', msg);
  }

  static e(msg: string): void {
    hilog.error(DOMAIN, TAG, '%{public}s', msg);
  }
}
