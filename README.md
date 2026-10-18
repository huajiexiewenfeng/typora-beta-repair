# Typora Beta Repair

一个用于 **Windows Typora 0.11.18 免费测试版** 的 Codex skill，处理启动或右键打开 Markdown 时出现的提示：

> This beta version of Typora is expired, please download and install a newer version.

保留现有旧版，通过当前用户的 Typora 专用注册表权限处理到期检查，支持诊断、独立备份和恢复。它不提供 Typora 安装包，也不处理新版商业许可证激活。

## 为什么还要检查启动环境

Codex 的 MSIX 环境可能重定向注册表和 AppData。直接在 Codex 内修改并启动成功，资源管理器右键打开仍可能报错。

本技能统一通过一次 WMI 工作进程操作桌面环境中的配置，并要求最终在资源管理器里验证用户原先的打开方式。详细原因见 [Windows 环境说明](references/windows-context.md)。

## 安装

需要 Windows、Git，以及支持本地 skill 的 Codex。首次安装，在 PowerShell 中运行：

```powershell
$skillPath = Join-Path $env:USERPROFILE '.codex\skills\typora-beta-repair'
git clone https://github.com/huajiexiewenfeng/typora-beta-repair.git $skillPath
```

若目标目录已存在，先保留原目录，避免覆盖已有文件。打开新的 Codex 聊天后使用：

```text
使用 $typora-beta-repair 检查并修复 Typora 的旧测试版到期提示，保留现有版本。
```

技能入口是 [SKILL.md](SKILL.md)。

## 手动运行

脚本支持 Windows PowerShell 5.1 与 PowerShell 7。修复、恢复前请先保存文档并正常关闭所有 Typora 窗口，脚本不会强制结束进程。

```powershell
$repairScript = Join-Path $env:USERPROFILE '.codex\skills\typora-beta-repair\scripts\typora-beta.ps1'

# 只诊断；不会修改 Typora 设置
& $repairScript -Mode Diagnose

# 修复；仅适用于已确认出现到期提示的 0.11.18
& $repairScript -Mode Repair -DisableAutoUpdate

# 只在临时测试键和临时偏好文件上运行自检
& $repairScript -Mode SelfTest
```

自动发现安装路径失败时可传 `-ExePath '实际的 Typora.exe 路径'`。希望保留自动更新设置时，不传 `-DisableAutoUpdate`。

修复结果返回 `backupDirectory`，备份位于用户目录的 `.codex\backups\typora-beta` 下。仅使用本脚本生成的备份进行恢复：

```powershell
& $repairScript -Mode Restore -BackupDirectory '之前返回的 backupDirectory'
```

如果 PowerShell 的脚本执行策略阻止运行，请检查本机策略和脚本内容；本技能不更改持久执行策略。工作进程只在本次进程范围使用 `-ExecutionPolicy Bypass`。

## 修改范围

- 只处理当前用户的 `HKCU\Software\Typora`，添加当前用户 SID 的四项数据权限拒绝规则，保留恢复权限。
- 可选关闭 `profile.data` 中的自动更新检查，保留其他偏好。
- 不修改程序二进制、系统时间、Markdown 正文或默认编辑器，也不创建计划任务。
- 恢复会还原原 DACL 及涉及的更新偏好；注册表键值备份保留供排查，不自动覆盖后来的许可证值。
- 已有相同权限规则时返回 `already_applied`，不重复修改或覆盖备份；此时本次新增的更新偏好参数不会另外执行。

配置写入成功不等于完成界面验证。请关闭 Typora 后，在资源管理器中通过原来的入口重新打开实际 `.md` 文件，确认正文正常显示且没有到期弹窗。

## 验证情况

已在 Windows Typora 0.11.18 上验证实际文件的“右键 → 打开方式 → Typora”启动。技能结构校验通过；SelfTest 覆盖原生工作进程路由、权限拒绝与恢复、键值保留、十六进制偏好文件的中文往返、无关偏好保留及错误格式拒绝。

其他版本只诊断，不应用此补丁。WMI 被系统策略禁止时会停止并报告；不自动提权，也不承诺该旧版方案永久有效。

## 参考

- [历史版本注册表权限方案](https://github.com/adrve/Typora-Free-Version-History/blob/master/Typora.bat)
- [Microsoft：打包桌面应用的运行与虚拟化](https://learn.microsoft.com/en-us/windows/msix/desktop/desktop-to-uwp-behind-the-scenes)
- [Microsoft：Flexible virtualization](https://learn.microsoft.com/en-us/windows/msix/desktop/flexible-virtualization)
