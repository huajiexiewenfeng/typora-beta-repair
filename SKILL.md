---
name: typora-beta-repair
description: 诊断、修复 Windows Typora 0.11.18 免费测试版的 beta expired 启动提示，以及右键打开 Markdown 仍报到期的问题。保留旧版，备份并恢复专用注册表权限，识别 Codex MSIX 隔离环境；不用于新版商业许可证激活或普通 Markdown 编辑。
---

# Typora 免费测试版启动修复

保留用户选择的旧版 Typora，修复已确认的测试版到期提示。先核对报错和版本，不把普通更新提示、文件关联错误或新版本许可证问题当成此问题。

## 诊断

通过正常工具调用运行本技能目录下的脚本。Windows PowerShell 5.1 与 PowerShell 7 均可调用：

```powershell
& '<skill-dir>\scripts\typora-beta.ps1' -Mode Diagnose
```

脚本检查原生桌面环境中的安装版本、进程、文件关联和 `HKCU\Software\Typora` 权限。自动发现失败时传 `-ExePath '实际的 Typora.exe 路径'`。入口统一通过 WMI 启动一次隐藏的 Windows PowerShell 工作进程，验证子进程没有包身份后再操作；不注册计划任务，不启动 Typora。仅检查当前进程有无包身份，不足以排除继承的重定向环境。`-NativeWorker` 是内部派发参数，不手动跳过此流程。

**关键：** Codex MSIX 环境可能虚拟化 HKCU 和 AppData。直接修改注册表后从同一环境启动成功，不能证明资源管理器打开成功。不要只查看当前 shell 的注册表，也不要把当前用户的原始 SID 路径当作可靠的去隔离方法。详情及实证见 [references/windows-context.md](references/windows-context.md)。

## 修复与恢复

确认实际提示为 `This beta version of Typora is expired...`，且实际运行文件版本为 **0.11.18** 后，用户要求修复即构成此范围内的授权。脚本本身不会判断截图语义。其他版本只诊断，不套用此补丁。

先让用户正常关闭所有 Typora 窗口，避免丢失未保存内容；可用现有 Computer Use 技能正常关闭已确认无未保存修改的窗口。脚本检测到 Typora 进程时会拒绝修复或恢复，不强制结束进程。

```powershell
& '<skill-dir>\scripts\typora-beta.ps1' -Mode Repair -DisableAutoUpdate
```

仅在用户希望留在旧版时使用 `-DisableAutoUpdate`。修复将：

- 创建独立备份，保存原生桌面注册表 DACL、键值、必要的更新偏好和清单。
- 仅向当前用户 `Software\Typora` 添加当前用户 SID 的拒绝规则，限制 QueryValues、SetValue、EnumerateSubKeys、CreateSubKey，保留修改权限的能力；不修改父键或删除键值。
- 按需关闭更新检查；不改系统时间，不下载破解包，不改程序二进制、Markdown 文件或默认打开方式。

重复修复已存在相同规则时返回 `already_applied` 并停止，不覆盖早期备份。此状态不代表界面验证完成，也不保证本次新增的更新偏好参数已执行。

保存返回的 `backupDirectory`。恢复同样要求 Typora 已关闭：

```powershell
& '<skill-dir>\scripts\typora-beta.ps1' -Mode Restore -BackupDirectory '修复返回的备份目录'
```

恢复只还原涉及的 DACL 和更新偏好，保留后来的其他偏好修改；键值备份仅供排查，不自动覆盖可能后来添加的许可证值。权限或原生进程启动失败时停止，报告失败点，不自动提升权限或反复套补丁。

## 验证用户的实际入口

修复脚本成功仅表示配置写入成功。用用户提供的一个 `.md` 文件，在**文件资源管理器**里复现其入口，例如“右键 → 打开方式 → Typora”。

1. 确认是新的启动，而非把文件交给先前由 Codex 启动的实例。
2. 核对实际进程路径和文档标题；通过界面确认正文正常显示，无到期对话框。仅进程存在或日志出现 start 不足以判定完成。
3. 用户原先是右键打开，只验证双击或 shell 的 `Start-Process` 不够。不要顺手改默认编辑器。
4. 保留原版本，说明修复范围和备份位置。无法完成真实入口验证时，明确写“配置已调整，资源管理器入口尚未验证”，不能宣称完全修好。

## 技能自检

```powershell
& '<skill-dir>\scripts\typora-beta.ps1' -Mode SelfTest
```

SelfTest 只用临时测试键和 profile，验证原生环境路由、拒绝规则、恢复、十六进制偏好格式及失败输入；不修改 Typora。检查返回的 `success`、`checks` 和 `nativePackageIdentity`。
