# MEMI 輕音 · HarmonyOS

MEMI 輕音的鸿蒙原生版本，使用 **ArkTS / ArkUI** 重写，独立于 Android 版推进。
本地曲库优先，同时接入网易云在线音源；播放页、歌词页与设置体系按 Miuix 风格重新设计。

> 这是 [MEMI_MusicPlayer](https://github.com/mumuji-colar/MEMI_MusicPlayer)（Android）的鸿蒙版本，
> 功能与交互参考 [NeriPlayer](https://github.com/cwuom/NeriPlayer)。两个项目均以 GPL-3.0 发布。

## 功能

**本地曲库**
- MP3 / FLAC / WAV / OGG / M4A / AAC / AMR / OPUS，读取标签、封面与内嵌歌词
- 歌曲 / 专辑 / 艺术家 / 歌单 / 最近 / 收藏 / 下载 / 统计
- 自建歌单、收藏、搜索、排序；SQLite（RDB）持久化，重启复原

**播放**
- 后台播放与播控中心（封面、歌词、上一首/下一首）
- 倍速、睡眠定时、列表循环 / 单曲循环 / 随机
- 沉浸式播放页：封面模糊背景、音质信息、五键控制

**歌词**
- 逐字歌词（yrc）、翻译、时间偏移、点击跳转
- 同名外挂歌词与音频内嵌歌词；可手动导入 / 移除 `.lrc` `.yrc` `.ttml`
- 当前行高亮、上下渐隐、逐字进度按插值时钟平滑推进

**网易云在线**
- 搜索（单曲 / 歌单 / 专辑）、首页分段推荐流（私人雷达、每日推荐、私人FM、榜单等）
- 歌单 / 专辑 / 艺人主页 / 评论 / MV
- 扫码登录与 Cookie 导入；按账号权限获取 320k / 无损 / Hi-Res
- 在线歌曲收藏、加入歌单、下载
- 音质降级：按安卓端同款顺序逐级尝试（lossless → exhigh → higher → standard），试听片段会继续往下找
- 自动换源（实验，默认关闭）：网易云完全拿不到地址时，按歌名/歌手/时长匹配 B 站同名音频

**下载与数据**
- 流式下载、断点续传、并发队列、歌词随下载
- 存储占用统计、缓存清理
- 设置 / 歌单 / 收藏备份导出与恢复

## 环境

| 项 | 版本 |
|:---|:---|
| DevEco Studio | 5.0.0 及以上（开发使用 26.0.1） |
| HarmonyOS SDK | 最低兼容 API 12，当前用 API 26 编译 |
| 语言 | ArkTS / ArkUI（Stage 模型） |

模拟器可直接运行；真机需要在 DevEco Studio 里配置自动签名。

## 构建

```bash
./build.sh          # 构建 debug HAP
./build.sh run      # 构建 + 安装到已连接设备 + 启动
./build.sh release  # 构建 release HAP
./build.sh clean    # 清理后重建
```

`build.sh` 默认从 `D:\Huawei\DevEco Studio` 读取 SDK，可用环境变量覆盖：

```bash
DEVECO_HOME="/path/to/DevEco Studio" ./build.sh
```

也可以直接用 DevEco Studio 打开 `app/` 目录运行。

## 目录

```
app/
  AppScope/                  应用级配置与图标
  entry/src/main/ets/
    pages/Index.ets          主界面：四个页签 + 播放/歌词/队列等浮层
    service/                 播放、曲库、网易云、下载、设置等服务
    model/                   数据模型
    common/                  工具函数与日志
  entry/src/main/resources/  字符串、颜色、图标
testdata/                    各格式测试音频（验证解码与歌词读取）
```

## 免责声明

- 本项目仅供**个人学习与技术交流**，不得用于商业用途。
- 在线内容来自网易云音乐 Web 端与哔哩哔哩 Web 端公开接口，音乐版权归原作者及版权方所有。
- 本项目**不提供任何破解或绕过付费的能力**：能否播放、能拿到什么码率，完全取决于登录账号自身的权限。
- 请遵守网易云音乐的服务条款；因使用本项目产生的任何后果由使用者自行承担。
- 如果相关权利方认为本项目不妥，请通过 Issue 联系，会及时处理。

## 更新日志

各版本的功能与已知限制见 [CHANGELOG.md](CHANGELOG.md)。

## 许可

本项目继承上游的 **GPL-3.0** 许可发布，完整文本见 [LICENSE](LICENSE)。

分发修改版时请继续遵守 GPL-3.0：保留版权声明、显著标明修改，并提供对应源码。

## 致谢

- [cwuom/NeriPlayer](https://github.com/cwuom/NeriPlayer)：功能与交互的主要参考
- [MEMI_MusicPlayer](https://github.com/mumuji-colar/MEMI_MusicPlayer)：Android 版本体
- Miuix：设置与列表的视觉规范参考
