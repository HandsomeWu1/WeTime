# WeTime

一个 macOS 菜单栏小应用——记录恋爱时间，互相戳一下，看对方在不在线。

## 功能

- ❤️ 菜单栏显示在一起的天数（年/月/日详情）
- 戳 TA 一下：对方收到 macOS 系统通知 + 菜单栏图标短暂变粉
- 在线状态：每 5 分钟心跳，菜单里看对方在线/离线
- 检查更新：启动时 + 每周一次自动查 GitHub Release，也可手动触发

## 安装

1. 到 [Releases](https://github.com/HandsomeWu1/WeTime/releases/latest) 下载 `WeTime.zip`
2. 解压，把 `WeTime.app` 拖进 `应用程序`
3. 第一次打开：右键 `WeTime.app` → 选「打开」→ 弹窗里再点「打开」（绕过未签名警告）
4. 弹"是否允许通知" → 选**允许**
5. 弹"首次配置：设置共享频道" → 输入和对方约定的字符串（建议长 + 含字母数字横杠）
6. 完成。菜单栏 ❤️ 就是入口

## 使用

- 点 ❤️：看恋爱天数
- 「戳 TA 一下 ❤️」（⌘P）：戳对方
- 「共享频道」：修改频道
- 「检查更新」：看有没有新版

## 安全说明

- 通信走 [ntfy.sh](https://ntfy.sh) 公共服务，是匿名公开的
- 频道名就是你们的"密码"——任何知道频道名的人都能订阅 / 发消息到这个频道
- 因此请用足够难猜的字符串（如 `abc-def-2026-x9k3p7`），**不要把频道名公开**

## 开发

```bash
make build              # 打包成 WeTime.app
make run                # 编译并运行
make zip                # 打包成 zip
make release VERSION=1.0.1 NOTES="新增 xxx"   # 发布到 GitHub Releases
```

发布前需要：
- 装好 [GitHub CLI](https://cli.github.com/)：`brew install gh`
- 登录：`gh auth login`
