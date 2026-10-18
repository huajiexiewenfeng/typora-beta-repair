# Windows 原生环境与隔离配置

## 已验证案例，2026-10-18

用户安装 Windows Typora 0.11.18，提示 `This beta version of Typora is expired, please download and install a newer version.`，明确希望保留免费测试版。

最初从 Codex 执行的 PowerShell 修改 HKCU 后，直接启动能成功，资源管理器右键打开仍报错。两者 exe 路径、用户 SID 相同，显式用 HKU\用户SID 也仍命中隔离视图。

Codex 包的 `LocalCache\Roaming\Typora\typora.log` 含最初成功日志，资源管理器启动却没更新这份日志。隔离视图与原生视图的 IDate 也不同。不要混淆两份日志或安装日期。

最终以 `Invoke-CimMethod -ClassName Win32_Process -MethodName Create` 启动一次原生 Windows PowerShell，修复真实用户键并关闭真实 profile 的自动更新。随后关闭 Typora，在资源管理器中右键打开实际文件，正文正常显示且无到期弹窗。未注册计划任务或修改文档。

## 环境判断

脚本用 Windows `GetCurrentPackageFullName` 检查包身份：`APPMODEL_ERROR_NO_PACKAGE` (15700) 表示 API 未报告包身份。此案例中，Codex 启动的 shell 即使返回此状态，仍能访问先前隔离的配置；不要把它单独用作无重定向的证明。入口统一派发一次 WMI 工作进程，工作进程再次检查，仍带包身份则失败，不递归重试。真实资源管理器验证仍不可省略。

备份和结果置于用户目录 `.codex` 下，避开 AppData 重定向。技能安装于 `~/.codex/skills`；若另存于 AppData，脚本拒绝将其用作隔离环境的工作进程来源，需先复制到两环境均可访问的位置。不要禁用 Codex 隔离或修改应用包清单。

WMI 在此机器验证有效，并不保证所有 Windows 策略下都有效。返回非零、超时或工作进程仍带包身份时停止并报告，不改用持久任务、自动提权或关闭防护。可在用户明确授权的普通 Windows PowerShell 中运行同一脚本。

## 权限与范围

用 `RegistryKey.GetAccessControl(Access).GetSecurityDescriptorSddlForm(Access)` 获取 DACL；不要依赖 `.Sddl` 展示属性，某些运行时中它为空。写权限时只提交 Access 部分，避免顺带提交 owner/group 而报 unauthorized operation。

补丁只处理旧测试版本地到期检查，不等于获得新版商业许可证。不要承诺永久有效或推广到其他版本。原始方案清空整个 Typora 键的权限；本技能只拒绝当前用户、单键、四项数据权限，保留恢复能力。

来源：

- [0.11.18 注册表权限方案](https://github.com/adrve/Typora-Free-Version-History/blob/master/Typora.bat)
- [Microsoft：打包桌面应用的运行与虚拟化](https://learn.microsoft.com/en-us/windows/msix/desktop/desktop-to-uwp-behind-the-scenes)
- [Microsoft：Flexible virtualization](https://learn.microsoft.com/en-us/windows/msix/desktop/flexible-virtualization)
