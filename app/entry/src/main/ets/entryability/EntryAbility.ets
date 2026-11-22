import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@kit.BasicServicesKit';
import { mediaSession } from '../service/MediaSessionService';
import { Logger } from '../common/Logger';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    Logger.i('Ability onCreate');
  }

  onDestroy(): void {
    Logger.i('Ability onDestroy');
    mediaSession.savePlaybackNow();
    mediaSession.destroy();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    Logger.i('Ability onWindowStageCreate');

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        Logger.e(`加载首页失败 ${err.code}: ${err.message}`);
        return;
      }
      Logger.i('首页加载完成');
    });

    this.applyImmersive(windowStage);

    // AVSession 尽早建好，通知栏/锁屏才有控制入口
    mediaSession.init(this.context).catch(() => {
      Logger.e('mediaSession.init 未成功');
    });
  }

  /**
   * 沉浸式布局：内容画到状态栏 / 导航条下面。
   *
   * 不这么做的话，窗口只在安全区内布局，状态栏和底部手势条的位置会露出
   * 窗口背景（黑边）。这里把系统栏设成透明、图标设成浅色，
   * 具体的内边距由页面按 getWindowAvoidArea() 的真实高度补。
   */
  private applyImmersive(windowStage: window.WindowStage): void {
    try {
      const win = windowStage.getMainWindowSync();
      win.setWindowLayoutFullScreen(true).then(() => {
        const props: window.SystemBarProperties = {
          statusBarColor: '#00000000',
          navigationBarColor: '#00000000',
          statusBarContentColor: '#FFFFFF',
          navigationBarContentColor: '#FFFFFF'
        };
        win.setWindowSystemBarProperties(props).catch((e: BusinessError) => {
          Logger.w(`设置系统栏样式失败 ${e.code}`);
        });
        Logger.i('已切换沉浸式布局');
      }).catch((e: BusinessError) => {
        Logger.e(`切换沉浸式失败 ${e.code}: ${e.message}`);
      });
    } catch (e) {
      const err = e as BusinessError;
      Logger.e(`获取主窗口失败 ${err.code}`);
    }
  }

  onWindowStageDestroy(): void {
    Logger.i('Ability onWindowStageDestroy');
  }

  onForeground(): void {
    Logger.i('Ability onForeground');
  }

  onBackground(): void {
    Logger.i('Ability onBackground');
    mediaSession.savePlaybackNow();
  }
}
