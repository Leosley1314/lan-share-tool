<#
============================================================
 局域网共享工具  (LAN Share Setup)
 -----------------------------------------------------------
 兼容性 : Windows Vista / 7 / 8 / 10 / 11 (PowerShell 2.0+)
 界面    : 图形界面(GUI)
 语言    : 简体中文
 版本    : v1.4
 ============================================================
#>
param(
    [string]$SharePath = '',
    [string]$ShareUser = '',
    [string]$SharePw = '',
    [switch]$ReadOnly,
    [switch]$NoGuest,
    [switch]$NoDiscovery,
    [switch]$NoPause,
    [switch]$NoElevate,
    [switch]$Gui,
    [switch]$ClearAll,
    [switch]$NoPrinter,
    [switch]$ShareAll,
    [switch]$FixFirewall,
    [switch]$FixNetwork,
    [switch]$NetReset
)
$script:InSharePath = $SharePath
# =============== 配置区（按需修改） ===============
$script:DefaultSharePath        = 'D:\'
$script:EnablePasswordlessGuest = $true
$script:EnableNetDiscovery      = $true
# =================================================
$ErrorActionPreference = 'Continue'
# 立即隐藏控制台窗口（启动即隐藏，不显示终端）
try { Add-Type -TypeDefinition 'using System;using System.Runtime.InteropServices;public class WinHide {[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();[DllImport("user32.dll")] public static extern bool ShowWindowAsync(IntPtr h,int n);[DllImport("kernel32.dll")] public static extern bool FreeConsole();}' -ErrorAction Stop } catch {}
try { $cw = [WinHide]::GetConsoleWindow(); if ($cw -ne [IntPtr]::Zero) { [void][WinHide]::ShowWindowAsync($cw, 0) } } catch {}
$script:scriptPath = $MyInvocation.MyCommand.Path
if (-not $script:scriptPath) {
    try { $script:scriptPath = [Environment]::GetCommandLineArgs()[0] } catch {}
}
if (-not $script:scriptPath) {
    try { $script:scriptPath = (Get-Process -Id $PID).Path } catch {}
}
if (-not $script:scriptPath) { $script:scriptPath = (Join-Path (Get-Location).Path 'lan-share.ps1') }
$scriptDir = Split-Path -Parent $script:scriptPath
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
$script:IsExe = ($script:scriptPath -match '(?i)\.exe$')
$logFile = Join-Path $scriptDir '局域网配置日志(重启后删除).txt'
# DPI 感知
try {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class DpiAwareness {
    [DllImport("user32.dll")]
    public static extern bool SetProcessDPIAware();
}
'@ -ErrorAction Stop
    [void][DpiAwareness]::SetProcessDPIAware()
} catch {}
$effGuest     = [bool]($script:EnablePasswordlessGuest -and (-not $NoGuest))
Add-Type -AssemblyName System.Drawing
function Get-Accent {
    $c = [System.Drawing.Color]::FromArgb(0, 120, 212)
    try {
        $ac = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\DWM' -Name AccentColor -ErrorAction Stop).AccentColor
        $ar = [uint32]$ac
        $c = [System.Drawing.Color]::FromArgb([int]($ar -band 0xFF), [int](($ar -shr 8) -band 0xFF), [int](($ar -shr 16) -band 0xFF))
    } catch {}
    return $c
}
function Restart-Explorer {
    Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    Start-Process explorer.exe
}
function Write-Log {
    param([string]$Msg)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Add-Content -Path $logFile -Value ('[' + $ts + '] ' + $Msg) -Encoding UTF8 -ErrorAction SilentlyContinue
    try { $cmd = "Remove-Item -LiteralPath '$logFile' -Force -ErrorAction SilentlyContinue"; $b64 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($cmd)); Set-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce' -Name 'LANShareCleanLog' -Value ("powershell.exe -NoProfile -WindowStyle Hidden -EncodedCommand " + $b64) -Force -ErrorAction SilentlyContinue } catch {}
}
$effDiscovery = [bool]($script:EnableNetDiscovery -and (-not $NoDiscovery))
# ---------- 前置检查 ----------
function Pre-Check {
    Write-Log '=== 前置检查 ==='
    $os = Get-WmiObject Win32_OperatingSystem
    $ver = [Version]$os.Version
    Write-Log ("系统: " + $os.Caption + " (Build " + $ver.Build + ")")
    if ($ver.Major -lt 6) { Write-Log '警告: Windows XP 不支持' }
    try {
        $smb1 = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' -Name SMB1 -ErrorAction SilentlyContinue).SMB1
        Write-Log ("SMB1: " + $(if ($smb1 -eq 1) {'已启用'} else {'未启用'}))
    } catch {}
    $svc = Get-Service LanmanServer -ErrorAction SilentlyContinue
    if ($svc) { Write-Log ("LanmanServer: " + $svc.Status + "/" + $svc.StartType) }
    Write-Log '=== 检查完毕 ==='
}
# ---------- 进度窗口 ----------
$script:progressForm = $null
$script:progressLabel = $null
$script:progressBar = $null
function Show-Progress {
    $script:progressForm = New-Object System.Windows.Forms.Form
    $script:progressForm.Text = '正在配置...'
    $script:progressForm.ClientSize = New-Object System.Drawing.Size(420, 110)
    $script:progressForm.StartPosition = 'CenterScreen'
    $script:progressForm.FormBorderStyle = 'FixedDialog'
    $script:progressForm.MaximizeBox = $false
    $script:progressForm.MinimizeBox = $false
    $script:progressLabel = New-Object System.Windows.Forms.Label
    $script:progressLabel.Location = New-Object System.Drawing.Point(15, 15)
    $script:progressLabel.Size = New-Object System.Drawing.Size(390, 22)
    $script:progressLabel.Text = '准备中...'
    $script:progressForm.Controls.Add($script:progressLabel)
    $script:progressBar = New-Object System.Windows.Forms.ProgressBar
    $script:progressBar.Location = New-Object System.Drawing.Point(15, 45)
    $script:progressBar.Size = New-Object System.Drawing.Size(390, 20)
    $script:progressBar.Minimum = 0
    $script:progressBar.Maximum = 100
    $script:progressForm.Controls.Add($script:progressBar)
    $script:progressForm.Show()
    $script:progressForm.Refresh()
}
function Update-Progress {
    param([string]$Text, [int]$Percent)
    if ($script:progressForm) {
        $script:progressLabel.Text = $Text
        $script:progressBar.Value = $Percent
        $script:progressForm.Refresh()
        [System.Windows.Forms.Application]::DoEvents()
    }
}
function Close-Progress {
    if ($script:progressForm) { $script:progressForm.Close(); $script:progressForm = $null }
}
function Show-Gui {
function Test-ShareReady {
    param([string]$ShareName)
    $sbT = New-Object System.Text.StringBuilder
    try {
        $svc = Get-Service LanmanServer -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -eq 'Running') { [void]$sbT.AppendLine('[OK] 文件共享服务(Server)运行中') }
        elseif ($svc) { [void]$sbT.AppendLine('[失败] 文件共享服务(Server)未运行 (' + $svc.Status + ')') }
        else { [void]$sbT.AppendLine('[失败] 文件共享服务(Server)不存在') }
    } catch { [void]$sbT.AppendLine('[未知] 文件共享服务(Server)检测失败') }
    try {
        $cl = New-Object System.Net.Sockets.TcpClient
        $ac = $cl.BeginConnect('127.0.0.1', 445, $null, $null)
        if ($ac.AsyncWaitHandle.WaitOne(800) -and $cl.Connected) { [void]$sbT.AppendLine('[OK] 445 端口(SMB)已监听') }
        else { [void]$sbT.AppendLine('[失败] 445 端口未监听') }
        $cl.Close()
    } catch { [void]$sbT.AppendLine('[失败] 445 端口检测异常') }
    try {
        $fw = @(netsh advfirewall firewall show rule name=LAN-SMB-In-TCP 2>$null)
        if (($fw | Where-Object { $_ -match '已启用\s*:\s*是|已启用\s*:\s*Yes|Enabled\s*:\s*Yes' }).Count -gt 0) { [void]$sbT.AppendLine('[OK] SMB 防火墙规则已启用') }
        else { [void]$sbT.AppendLine('[警告] SMB 防火墙规则缺失') }
    } catch { [void]$sbT.AppendLine('[未知] 防火墙规则检测失败') }
    if ($ShareName) {
        try {
            $sh = @(net share 2>$null)
            $found = $false
            foreach ($s in $sh) { if ($s -match ('^\s*' + [regex]::Escape($ShareName) + '\s')) { $found = $true } }
            if ($found) { [void]$sbT.AppendLine('[OK] 共享 "' + $ShareName + '" 已创建') }
            else { [void]$sbT.AppendLine('[失败] 共享 "' + $ShareName + '" 未找到') }
        } catch { [void]$sbT.AppendLine('[未知] 共享查询失败') }
    }
    return $sbT.ToString()
}
    $form = New-Object System.Windows.Forms.Form
    $sysFont = [System.Drawing.SystemFonts]::DefaultFont
    $accent = Get-Accent
    $accentDark = [System.Drawing.Color]::FromArgb([int]($accent.R*0.82), [int]($accent.G*0.82), [int]($accent.B*0.82))
    $hoverBg = [System.Drawing.Color]::FromArgb([int]($accent.R*0.12+255*0.88), [int]($accent.G*0.12+255*0.88), [int]($accent.B*0.12+255*0.88))
    $redHover = [System.Drawing.Color]::FromArgb(252, 232, 232)
    $form.Font = $sysFont
    try {
        $icoPath = Join-Path $scriptDir 'lan-share.ico'
        if (Test-Path $icoPath) { $form.Icon = New-Object System.Drawing.Icon($icoPath) }
    } catch {}
    $form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::Dpi
    $form.Text = '局域网共享工具'
    $form.ShowInTaskbar = $true
    $form.ClientSize = New-Object System.Drawing.Size(620, 560)
    $form.StartPosition = 'Manual'
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $form.Location = New-Object System.Drawing.Point([int][math]::Max(0, ($wa.Width - $form.Width) / 2), [int][math]::Max(0, ($wa.Height - $form.Height) / 2))
    $form.FormBorderStyle = 'FixedSingle'
    $form.MinimumSize = $form.Size
    $form.MaximumSize = $form.Size
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.BackColor = [System.Drawing.Color]::White
    $form.KeyPreview = $true
    $lblSub = New-Object System.Windows.Forms.Label
    $lblSub.Text = '选择要共享的磁盘或文件夹'
    $lblSub.Font = New-Object System.Drawing.Font($sysFont.FontFamily, 10)
    $lblSub.Location = New-Object System.Drawing.Point(0, 20)
    $lblSub.Size = New-Object System.Drawing.Size(620, 24)
    $lblSub.TextAlign = 'MiddleCenter'
    $form.Controls.Add($lblSub)
    $gbPath = New-Object System.Windows.Forms.Panel
    $gbPath.BackColor = [System.Drawing.Color]::White
    $gbPath.BorderStyle = 'FixedSingle'
    $gbPath.Location = New-Object System.Drawing.Point(25, 56)
    $gbPath.Size = New-Object System.Drawing.Size(570, 112)
    $form.Controls.Add($gbPath)
    $combo = New-Object System.Windows.Forms.ComboBox
    $combo.DropDownStyle = 'DropDownList'
    $drivePaths = New-Object System.Collections.ArrayList
    $drives = @()
    try { $drives = @(Get-WmiObject Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 } | Sort-Object DeviceID) } catch {}
    if ($drives.Count -eq 0) { try { $drives = @(Get-WmiObject Win32_LogicalDisk | Where-Object { $_.DeviceID -match '^[A-Z]:$' } | Sort-Object DeviceID) } catch {} }
    if ($drives.Count -eq 0) { try { $netDrv = [System.IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq [System.IO.DriveType]::Fixed -and $_.IsReady }; foreach ($dd in $netDrv) { $letter = $dd.Name.Substring(0, $dd.Name.Length - 1); [void]$drivePaths.Add($letter); $vol2 = if ($dd.VolumeLabel) { $dd.VolumeLabel } else { '本地磁盘' }; $size2 = [math]::Round($dd.TotalSize / 1GB, 1); [void]$combo.Items.Add(($letter + ' ' + $vol2 + ' (' + $size2 + ' GB)')) } } catch {} }
    foreach ($d in $drives) {
        $sizeGB = [math]::Round($d.Size / 1GB, 1)
        [void]$drivePaths.Add($d.DeviceID + '\')
        $vol = $d.VolumeName; if (-not $vol) { $vol = '本地磁盘' }
        [void]$combo.Items.Add(($d.DeviceID + ' ' + $vol + ' (' + $sizeGB + ' GB)'))
    }
    [void]$combo.Items.Add('自定义')
    $combo.SelectedIndex = 0
    $lblPath = New-Object System.Windows.Forms.Label
    $lblPath.Text = '共享位置'
    $lblPath.Location = New-Object System.Drawing.Point(12, 31)
    $lblPath.AutoSize = $false
    $lblPath.TextAlign = 'MiddleLeft'
    $lblW = $lblPath.PreferredWidth
    $lblPath.Size = New-Object System.Drawing.Size($lblW, 28)
    $comboW = 305
    $comboX0 = 12 + $lblW + 8
    $combo.Location = New-Object System.Drawing.Point($comboX0, 33)
    $combo.Size = New-Object System.Drawing.Size($comboW, 24)
    $gbPath.Controls.Add($lblPath)
    $gbPath.Controls.Add($combo)
    $txt = New-Object System.Windows.Forms.TextBox
    $txt.Location = New-Object System.Drawing.Point(12, 78)
    $txt.Size = New-Object System.Drawing.Size(546, 24)
    $txt.Visible = $false
    $btnBrowse = New-Object System.Windows.Forms.Button
    $btnBrowse.Text = '浏览...'
    $btnBrowse.Location = New-Object System.Drawing.Point(400, 31)
    $btnBrowse.Size = New-Object System.Drawing.Size(84, 28)
    $btnBrowse.Visible = $false
    $gbPath.Controls.Add($txt)
    $gbPath.Controls.Add($btnBrowse)
    $rowW = $lblW + 8 + $comboW + 8 + $btnBrowse.Width
    $startX = [math]::Round([math]::Max(0, ($gbPath.Width - $rowW) / 2))
    $lblPath.Location = New-Object System.Drawing.Point($startX, 31)
    $comboX1 = $startX + $lblW + 8
    $combo.Location = New-Object System.Drawing.Point($comboX1, 33)
    $btnX1 = $startX + $lblW + 8 + $comboW + 8
    $btnBrowse.Location = New-Object System.Drawing.Point($btnX1, 31)
    $gbOpt = New-Object System.Windows.Forms.Panel
    $gbOpt.BackColor = [System.Drawing.Color]::White
    $gbOpt.BorderStyle = 'FixedSingle'
    $gbOpt.Location = New-Object System.Drawing.Point(25, 212)
    $gbOpt.Size = New-Object System.Drawing.Size(570, 152)
    $form.Controls.Add($gbOpt)
    $lblOptTitle = New-Object System.Windows.Forms.Label
    $lblOptTitle.Text = '选项'
    $lblOptTitle.Font = New-Object System.Drawing.Font($sysFont.FontFamily, 10, [System.Drawing.FontStyle]::Bold)
    $lblOptTitle.ForeColor = [System.Drawing.Color]::FromArgb(90, 90, 90)
    $lblOptTitle.Location = New-Object System.Drawing.Point(14, 8)
    $lblOptTitle.Size = New-Object System.Drawing.Size(120, 20)
    $gbOpt.Controls.Add($lblOptTitle)
    $chkGuest = New-Object System.Windows.Forms.CheckBox
    $chkGuest.Text = '开启无密码访客访问'
    $chkGuest.Location = New-Object System.Drawing.Point(18, 34)
    $chkGuest.Size = New-Object System.Drawing.Size(250, 24)
    $chkGuest.Checked = $true
    $gbOpt.Controls.Add($chkGuest)
    $chkDisc = New-Object System.Windows.Forms.CheckBox
    $chkDisc.Text = '启用网络发现'
    $chkDisc.Location = New-Object System.Drawing.Point(300, 34)
    $chkDisc.Size = New-Object System.Drawing.Size(250, 24)
    $chkDisc.Checked = $true
    $gbOpt.Controls.Add($chkDisc)
    $chkRO = New-Object System.Windows.Forms.CheckBox
    $chkRO.Text = '只读共享'
    $chkRO.Location = New-Object System.Drawing.Point(300, 70)
    $chkRO.Size = New-Object System.Drawing.Size(250, 24)
    $chkRO.Checked = $false
    $gbOpt.Controls.Add($chkRO)
    $chkPrinter = New-Object System.Windows.Forms.CheckBox
    $chkPrinter.Text = '启用打印机共享'
    $chkPrinter.Location = New-Object System.Drawing.Point(18, 70)
    $chkPrinter.Size = New-Object System.Drawing.Size(250, 24)
    $chkPrinter.Checked = $true
    $gbOpt.Controls.Add($chkPrinter)
    $tip = New-Object System.Windows.Forms.ToolTip
    $tip.AutoPopDelay = 5000
    $tip.InitialDelay = 500
    $tip.ReshowDelay = 200
    $tip.SetToolTip($chkGuest, ("勾选后同一网络内任何设备无需密码即可访问共享。" + [Environment]::NewLine + "不勾选则需输入用户名密码访问。"))
    $tip.SetToolTip($chkDisc, ('让其他设备在网络文件夹中看到这台电脑。' + [Environment]::NewLine + '不勾选则需通过 \\电脑名 或 IP 地址直接访问。'))
    $tip.SetToolTip($chkRO, "其他设备只能打开和复制文件，不能修改、删除或写入。")
    $tip.SetToolTip($chkPrinter, "局域网内其他电脑可使用这台电脑连接的打印机。")
    $lblUser = New-Object System.Windows.Forms.Label
    $lblUser.Text = '用户名:'
    $lblUser.Location = New-Object System.Drawing.Point(66, 104)
    $lblUser.Size = New-Object System.Drawing.Size(62, 22)
    $lblUser.Visible = $false
    $gbOpt.Controls.Add($lblUser)
    $txtUser = New-Object System.Windows.Forms.TextBox
    $txtUser.Location = New-Object System.Drawing.Point(130, 102)
    $txtUser.Size = New-Object System.Drawing.Size(150, 22)
    $txtUser.Text = $env:USERNAME
    $txtUser.Visible = $false
    $gbOpt.Controls.Add($txtUser)
    $lblPw = New-Object System.Windows.Forms.Label
    $lblPw.Text = '密码:'
    $lblPw.Location = New-Object System.Drawing.Point(290, 104)
    $lblPw.Size = New-Object System.Drawing.Size(62, 22)
    $lblPw.Visible = $false
    $gbOpt.Controls.Add($lblPw)
    $txtPw = New-Object System.Windows.Forms.TextBox
    $txtPw.Location = New-Object System.Drawing.Point(354, 102)
    $txtPw.Size = New-Object System.Drawing.Size(150, 22)
    $txtPw.PasswordChar = '*'
    $txtPw.Visible = $false
    $gbOpt.Controls.Add($txtPw)
    $lblTip = New-Object System.Windows.Forms.Label
    $lblTip.Text = '点"开始配置"后请求管理员权限，自动完成全部设置。'
    $lblTip.ForeColor = [System.Drawing.Color]::Gray
    $lblTip.Location = New-Object System.Drawing.Point(25, 378)
    $lblTip.Size = New-Object System.Drawing.Size(570, 34)
    $lblTip.TextAlign = 'MiddleCenter'
    $form.Controls.Add($lblTip)
    $chkGuest.add_CheckedChanged({
        $show = -not $chkGuest.Checked
        $lblUser.Visible = $show; $txtUser.Visible = $show
        $lblPw.Visible = $show; $txtPw.Visible = $show
    })
    $combo.add_SelectedIndexChanged({
        $isCustom = ($combo.SelectedItem -and $combo.SelectedItem.ToString() -eq '自定义')
        $txt.Visible = $isCustom
        $btnBrowse.Visible = $isCustom
    })
    $btnBrowse.add_Click({
        $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
        $dlg.Description = '选择要共享的文件夹'
        if ($dlg.ShowDialog() -eq 'OK') { $txt.Text = $dlg.SelectedPath }
    })
    $btnNet = New-Object System.Windows.Forms.Button
    $btnNet.Text = '网络工具'
    $btnNet.Size = New-Object System.Drawing.Size(135, 36)
    $btnNet.Location = New-Object System.Drawing.Point(97, 424)
    $btnNet.FlatStyle = 'Flat'
    $btnNet.FlatAppearance.BorderColor = $accent
    $btnNet.FlatAppearance.BorderSize = 1
    $btnNet.BackColor = [System.Drawing.Color]::White
    $btnNet.ForeColor = $accent
    $form.Controls.Add($btnNet)
    $btnNet.add_MouseEnter({ $btnNet.BackColor = $hoverBg })
    $btnNet.add_MouseLeave({ $btnNet.BackColor = [System.Drawing.Color]::White })
    $btnNet.add_Click({
        $nt = New-Object System.Windows.Forms.Form
        $nt.Text = '网络工具'
        $nt.ClientSize = New-Object System.Drawing.Size(520, 850)
        $nt.StartPosition = 'CenterParent'
        $nt.FormBorderStyle = 'FixedDialog'
        $nt.MaximizeBox = $false
        $nt.MinimizeBox = $false
        $nt.BackColor = [System.Drawing.Color]::White
        $lblIp = New-Object System.Windows.Forms.Label
        $lblIp.Text = '本机信息：'
        $lblIp.Location = New-Object System.Drawing.Point(15, 12)
        $lblIp.Size = New-Object System.Drawing.Size(110, 20)
        $lblIp.Font = New-Object System.Drawing.Font([System.Drawing.SystemFonts]::DefaultFont.FontFamily, 10, [System.Drawing.FontStyle]::Bold)
        $lblIp.BackColor = [System.Drawing.Color]::White
        $nt.Controls.Add($lblIp)
        $ipPanel = New-Object System.Windows.Forms.Panel
        $ipPanel.Location = New-Object System.Drawing.Point(15, 40)
        $ipPanel.Size = New-Object System.Drawing.Size(490, 110)
        $ipPanel.BackColor = [System.Drawing.Color]::White
        $ipPanel.AutoScroll = $true
        $nt.Controls.Add($ipPanel)
    $fillIp = {
        foreach ($c in @($ipPanel.Controls)) { if ($c.Tag -eq 'iprow') { $ipPanel.Controls.Remove($c); $c.Dispose() } }
        $yy = 30
        $hasStatic = $false
        $lowGw = $null; $lowMet = 2147483647
        foreach ($rl in (route print 2>$null)) {
            if ($rl -match '^\s*0\.0\.0\.0\s+0\.0\.0\.0\s+(\S+)\s+(\S+)\s+(\d+)\s*$') {
                if ([int]$Matches[3] -lt $lowMet) { $lowMet = [int]$Matches[3]; $lowGw = $Matches[1] }
            }
        }
        try {
            $ads = @(Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled })
            foreach ($ad in $ads) {
                $ipv4 = @()
                foreach ($a in $ad.IPAddress) { if ($a -match '^\d+\.\d+\.\d+\.\d+$') { $ipv4 += $a } }
                if ($ipv4.Count -eq 0) { continue }
                $name = $ad.Description
                if (-not $name) { $name = '网络适配器' }
                $isDefault = $false
                if ($lowGw -and $ad.DefaultIPGateway) { foreach ($g in $ad.DefaultIPGateway) { if ($g -eq $lowGw) { $isDefault = $true } } }
                $fixTag = ''
                if ($ad.DHCPEnabled -eq $false) { $fixTag = '（固定 IP）'; $hasStatic = $true }
                $p = New-Object System.Windows.Forms.Label
                $p.BackColor = [System.Drawing.Color]::White
                $p.Tag = 'iprow'
                $p.Font = New-Object System.Drawing.Font([System.Drawing.SystemFonts]::DefaultFont.FontFamily, 10, [System.Drawing.FontStyle]::Bold)
                $p.Text = $name + $(if ($isDefault) { '（默认路由）' } else { '' }) + $fixTag
                $p.Location = New-Object System.Drawing.Point(15, $yy)
                $p.AutoSize = $true
                $p.MaximumSize = New-Object System.Drawing.Size(460, 0)
                $ipPanel.Controls.Add($p)
                $yy += $p.Height + 4
                foreach ($ip in $ipv4) {
                    $pl = New-Object System.Windows.Forms.Label
                    $pl.BackColor = [System.Drawing.Color]::White
                    $pl.Tag = 'iprow'; $pl.Text = 'IPv4 地址:'; $pl.TextAlign = 'MiddleRight'
                    $pl.Font = New-Object System.Drawing.Font([System.Drawing.SystemFonts]::DefaultFont.FontFamily, 10)
                    $pl.Location = New-Object System.Drawing.Point(15, $yy)
                    $pl.Size = New-Object System.Drawing.Size(245, 20)
                    $ipPanel.Controls.Add($pl)
                    $vl = New-Object System.Windows.Forms.Label
                    $vl.BackColor = [System.Drawing.Color]::White
                    $vl.Tag = 'iprow'; $vl.Text = $ip; $vl.TextAlign = 'MiddleLeft'
                    $vl.Font = New-Object System.Drawing.Font([System.Drawing.SystemFonts]::DefaultFont.FontFamily, 10)
                    $vl.Location = New-Object System.Drawing.Point(265, $yy)
                    $vl.Size = New-Object System.Drawing.Size(200, 20)
                    $ipPanel.Controls.Add($vl)
                    $yy += 20
                }
                if ($ad.DefaultIPGateway) {
                    foreach ($g in $ad.DefaultIPGateway) {
                        if ($g -notmatch ':') {
                            $pl = New-Object System.Windows.Forms.Label
                            $pl.BackColor = [System.Drawing.Color]::White
                            $pl.Tag = 'iprow'; $pl.Text = 'IPv4 默认网关:'; $pl.TextAlign = 'MiddleRight'
                            $pl.Font = New-Object System.Drawing.Font([System.Drawing.SystemFonts]::DefaultFont.FontFamily, 10)
                            $pl.Location = New-Object System.Drawing.Point(15, $yy)
                            $pl.Size = New-Object System.Drawing.Size(245, 20)
                            $ipPanel.Controls.Add($pl)
                            $vl = New-Object System.Windows.Forms.Label
                            $vl.BackColor = [System.Drawing.Color]::White
                            $vl.Tag = 'iprow'; $vl.Text = $g; $vl.TextAlign = 'MiddleLeft'
                            $vl.Font = New-Object System.Drawing.Font([System.Drawing.SystemFonts]::DefaultFont.FontFamily, 10)
                            $vl.Location = New-Object System.Drawing.Point(265, $yy)
                            $vl.Size = New-Object System.Drawing.Size(200, 20)
                            $ipPanel.Controls.Add($vl)
                            $yy += 20
                            break
                        }
                    }
                }
                if ($ad.MACAddress) {
                    $pl = New-Object System.Windows.Forms.Label
                    $pl.BackColor = [System.Drawing.Color]::White
                    $pl.Tag = 'iprow'; $pl.Text = 'MAC 地址:'; $pl.TextAlign = 'MiddleRight'
                    $pl.Font = New-Object System.Drawing.Font([System.Drawing.SystemFonts]::DefaultFont.FontFamily, 10)
                    $pl.Location = New-Object System.Drawing.Point(15, $yy)
                    $pl.Size = New-Object System.Drawing.Size(245, 20)
                    $ipPanel.Controls.Add($pl)
                    $vl = New-Object System.Windows.Forms.Label
                    $vl.BackColor = [System.Drawing.Color]::White
                    $vl.Tag = 'iprow'; $vl.Text = $ad.MACAddress; $vl.TextAlign = 'MiddleLeft'
                    $vl.Font = New-Object System.Drawing.Font([System.Drawing.SystemFonts]::DefaultFont.FontFamily, 10)
                    $vl.Location = New-Object System.Drawing.Point(265, $yy)
                    $vl.Size = New-Object System.Drawing.Size(200, 20)
                    $ipPanel.Controls.Add($vl)
                    $yy += 20
                }
                $yy += 4
            }
        } catch {}
        if ($hasStatic) {
            $w = New-Object System.Windows.Forms.Label
            $w.Text = '⚠ 检测到固定 IP：请确保 IP 未与其他设备冲突、网关/子网掩码配置正确；建议改用路由器 DHCP 静态分配（按 MAC 绑定 IP），避免冲突断网。'
            $w.Location = New-Object System.Drawing.Point(15, $yy)
            $w.AutoSize = $true
            $w.MaximumSize = New-Object System.Drawing.Size(460, 0)
            $w.ForeColor = [System.Drawing.Color]::FromArgb(200, 120, 0)
            $w.BackColor = [System.Drawing.Color]::White
            $w.Tag = 'iprow'
            $w.Font = New-Object System.Drawing.Font([System.Drawing.SystemFonts]::DefaultFont.FontFamily, 9)
            $ipPanel.Controls.Add($w)
            $yy += $w.Height + 4
        }
        if ($yy -le 30) {
            $e = New-Object System.Windows.Forms.Label
            $e.BackColor = [System.Drawing.Color]::White
            $e.Tag = 'iprow'; $e.Text = '(未检测到有效网络适配器)'
            $e.Location = New-Object System.Drawing.Point(15, 30)
            $e.Size = New-Object System.Drawing.Size(300, 18)
            $ipPanel.Controls.Add($e)
        }
    }
        $script:lastIpSnapshot = @(Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled } | ForEach-Object { $_.MACAddress + '|' + ($_.IPAddress -join ',') + '|' + ($_.DefaultIPGateway -join ',') }) -join ';'
        $refreshIp = {
            $snap = @(Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled } | ForEach-Object { $_.MACAddress + '|' + ($_.IPAddress -join ',') + '|' + ($_.DefaultIPGateway -join ',') }) -join ';'
            if ($snap -ne $script:lastIpSnapshot) {
                $script:lastIpSnapshot = $snap
                & $fillIp
            }
        }
        $ipTimer = New-Object System.Windows.Forms.Timer
        $ipTimer.Interval = 2000
        $ipTimer.add_Tick({ & $refreshIp })
        & $fillIp
        $ipTimer.Start()
        $nt.add_FormClosed({ $ipTimer.Stop() })
        $btnScan = New-Object System.Windows.Forms.Button
        $btnScan.Text = '局域网 IP 扫描'
        $btnScan.Size = New-Object System.Drawing.Size(150, 32)
        $btnScan.Location = New-Object System.Drawing.Point(15, 156)
        $btnScan.FlatStyle = 'Flat'
        $btnScan.FlatAppearance.BorderSize = 0
        $btnScan.BackColor = $accent
        $btnScan.ForeColor = [System.Drawing.Color]::White
        $nt.Controls.Add($btnScan)
        $btnScan.add_MouseEnter({ $btnScan.BackColor = $accentDark })
        $btnScan.add_MouseLeave({ $btnScan.BackColor = $accent })
        $lblScan = New-Object System.Windows.Forms.Label
        $lblScan.Text = '在线设备列表（双击打开）：'
        $lblScan.Location = New-Object System.Drawing.Point(15, 192)
        $lblScan.Size = New-Object System.Drawing.Size(490, 20)
        $lblScan.BackColor = [System.Drawing.Color]::White
        $nt.Controls.Add($lblScan)
        $lbRes = New-Object System.Windows.Forms.ListBox
        $lbRes.Location = New-Object System.Drawing.Point(15, 214)
        $lbRes.Size = New-Object System.Drawing.Size(490, 110)
        $lbRes.ScrollAlwaysVisible = $true
        $nt.Controls.Add($lbRes)
        $lbRes.add_DoubleClick({
            $sel = $lbRes.SelectedItem
            if ($sel -and $sel -match '^(\d+\.\d+\.\d+\.\d+)') {
                try { Start-Process explorer.exe -ArgumentList ('\\' + $Matches[1]) } catch {}
            }
        })
        $btnScan.add_Click({
            $btnScan.Enabled = $false
            $lbRes.Items.Add('正在扫描局域网，请稍候...')
            [System.Windows.Forms.Application]::DoEvents()
            $myIp = ''; $gateway = ''
            foreach ($ad in (Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -and $_.MACAddress })) {
                $gw = @($ad.DefaultIPGateway | Where-Object { $_ -notmatch ':' })[0]
                if ($gw -and ($gw -notmatch '^198\.18\.' -and $gw -notmatch '^100\.64\.')) {
                    $gateway = $gw
                    foreach ($a in @($ad.IPAddress)) { if ($a -match '^\d+\.\d+\.\d+\.\d+$') { $myIp = $a; break } }
                    break
                }
            }
            if (-not $myIp) {
                foreach ($ad in (Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -and $_.MACAddress })) {
                    foreach ($a in @($ad.IPAddress)) { if ($a -match '^\d+\.\d+\.\d+\.\d+$' -and $a -notmatch '^(198\.18|100\.64)') { $myIp = $a; break } }
                    if ($myIp) { break }
                }
            }
            $oui = @{
                '3C22FB'='手机(Apple)';'A483E7'='手机(Apple)';'F01898'='手机(Apple)';'8863DF'='手机(Apple)';'0017F2'='手机(Apple)';'28CFDA'='手机(Apple)';'68A03E'='手机(Apple)';'B8098A'='手机(Apple)';'886B0F'='手机(Apple)';'A45E60'='手机(Apple)';'5CF5DA'='手机(Apple)';'04DB56'='手机(Apple)';'784F43'='手机(Apple)';'D85ED3'='手机(Apple)';'40CBC0'='手机(Apple)';'F40F24'='手机(Apple)';'74C14F'='手机(Apple)';
                '001A11'='手机(Samsung)';'58A23F'='手机(Samsung)';'8C71F8'='手机(Samsung)';'485519'='手机(Samsung)';'A85C2C'='手机(Samsung)';'30122A'='手机(Samsung)';'5C338E'='手机(Samsung)';'445719'='手机(Samsung)';'8C9EBF'='手机(Samsung)';'50D2E5'='手机(Samsung)';
                '640980'='小米设备';'286ED4'='小米设备';'684F13'='小米设备';'B00A37'='小米设备';'7811DC'='小米设备';'102C6B'='小米设备';'90CD65'='小米设备';'94652D'='小米设备';'84AF1F'='小米设备';'50ECD4'='小米设备';
                '3C3786'='华为设备';'446EE5'='华为设备';'982CBC'='华为设备';'E0191D'='华为设备';'8C34FD'='华为设备';'705EAA'='华为设备';'407C1F'='华为设备';'8C8A6D'='华为设备';
                '882853'='手机(OPPO)';'9C61B2'='手机(OPPO)';'701CE7'='手机(OPPO)';'30E95A'='手机(OPPO)';
                '9076F6'='手机(vivo)';'701A04'='手机(vivo)';'E823FA'='手机(vivo)';
                '04FE31'='手机(OnePlus)';'488F5A'='手机(OnePlus)';'44237C'='手机(荣耀)';'1856EA'='手机(荣耀)';'001267'='手机(LG)';'50642B'='手机(LG)';'9C934E'='手机(LG)';'188A5B'='手机(Google)';'5CC5D4'='手机(Google)';'AC216A'='手机(Google)';'A47733'='手机(Google)';'A0741D'='手机(魅族)';
                '50FA84'='路由器(TP-Link)';'603197'='路由器(TP-Link)';'C006C3'='路由器(TP-Link)';'001B2F'='路由器(TP-Link)';'487B6B'='路由器(TP-Link)';'681CA2'='路由器(TP-Link)';'0C8063'='路由器(TP-Link)';'300BC4'='路由器(TP-Link)';'58696C'='路由器(TP-Link)';'D80D17'='路由器(TP-Link)';
                '000C6E'='网络设备(ASUS)';'0435AB'='网络设备(ASUS)';'08870F'='网络设备(ASUS)';'14D64D'='网络设备(ASUS)';'485B39'='网络设备(ASUS)';'204E7F'='网络设备(NETGEAR)';'680AE2'='网络设备(NETGEAR)';'7845C4'='网络设备(NETGEAR)';'A06391'='网络设备(NETGEAR)';'0018F8'='网络设备(Linksys)';'002369'='网络设备(Linksys)';'8CEACC'='网络设备(Linksys)';'548CA0'='网络设备(Linksys)';
                '000C42'='网络设备(Cisco)';'001D45'='网络设备(Cisco)';'00211B'='网络设备(Cisco)';'00115C'='网络设备(Cisco)';'00131A'='网络设备(Cisco)';'001B1B'='网络设备(H3C)';'000FE2'='网络设备(H3C)';'00227D'='网络设备(H3C)';'00156D'='网络设备(Ubiquiti)';'0418D6'='网络设备(Ubiquiti)';'788A20'='网络设备(Ubiquiti)';'24A43C'='网络设备(Ubiquiti)';'802AA8'='网络设备(Ubiquiti)';'F09FC2'='网络设备(Ubiquiti)';
                '58961D'='网络设备(Tenda)';'A4574D'='网络设备(Tenda)';'D807B6'='网络设备(Tenda)';'001B11'='网络设备(D-Link)';'00055D'='网络设备(D-Link)';'0080C8'='网络设备(D-Link)';'28107B'='网络设备(D-Link)';'40D28C'='网络设备(D-Link)';'64D154'='网络设备(MikroTik)';'CC2DE0'='网络设备(MikroTik)';'DC9FDB'='网络设备(MikroTik)';'E48D8C'='网络设备(MikroTik)';'0001AF'='网络设备(Ruijie)';'0024E8'='网络设备(Ruijie)';'001A92'='网络设备(Mercury)';
                '001B21'='电脑(Intel)';'3CFDFE'='电脑(Intel)';'001E67'='电脑(Intel)';'B42E99'='电脑(Intel)';'3CA82A'='电脑(Intel)';'0013E8'='电脑(Intel)';'0025B7'='电脑(Intel)';'88B111'='电脑(Intel)';'4C796E'='电脑(Intel)';'AC7BA1'='电脑(Intel)';'A41F72'='电脑(Intel)';
                '00E04C'='电脑(Realtek)';'74852A'='电脑(Realtek)';'9C2A70'='电脑(Realtek)';'A46BB6'='电脑(Realtek)';'D8BBC1'='电脑(Realtek)';'001143'='电脑(Broadcom)';'00142D'='电脑(Broadcom)';'0017C5'='电脑(Broadcom)';'001A2B'='电脑(Broadcom)';'00236E'='电脑(Broadcom)';'002688'='电脑(Broadcom)';'000F39'='电脑(Qualcomm)';'00266A'='电脑(Qualcomm)';
                '001422'='电脑(Dell)';'001D09'='电脑(Dell)';'00219B'='电脑(Dell)';'0023AE'='电脑(Dell)';'0026B9'='电脑(Dell)';'F8BC12'='电脑(Dell)';'001B78'='电脑(HP)';'001F29'='电脑(HP)';'002324'='电脑(HP)';'00259C'='电脑(HP)';'3CD92B'='电脑(HP)';'54EE75'='电脑(Lenovo)';'E41F13'='电脑(Lenovo)';'F4A52D'='电脑(Lenovo)';
                '000569'='虚拟机(VMware)';'000C29'='虚拟机(VMware)';'005056'='虚拟机(VMware)';'080027'='虚拟机(VirtualBox)';'525400'='虚拟机(QEMU)';'00155D'='虚拟机(Hyper-V)';'B827EB'='开发板(树莓派)';'DCA632'='开发板(树莓派)';'E45F01'='开发板(树莓派)'
            }
            $seg = ''
            if ($myIp) { $seg = ($myIp -split '\.')[0..2] -join '.' }
            if ($seg) {
                $lbRes.Items.Clear()
                $lbRes.Items.Add('正在扫描局域网 0/254，请稍候...')
                [System.Windows.Forms.Application]::DoEvents()
                for ($batch = 0; $batch -lt 8; $batch++) {
                    $procs = @()
                    $start = $batch * 32 + 1
                    $end = [Math]::Min(254, ($batch + 1) * 32)
                    for ($n = $start; $n -le $end; $n++) {
                        $ip = $seg + '.' + $n
                        try { $proc = Start-Process ping.exe -ArgumentList ('-n','1','-w','150',$ip) -PassThru -WindowStyle Hidden -ErrorAction SilentlyContinue; $procs += @{ P = $proc; Ip = $ip } } catch {}
                    }
                    foreach ($pd in $procs) {
                        try { $pd.P.WaitForExit(1200) | Out-Null } catch {}
                        try { $pd.P.ExitCode | Out-Null } catch {}
                    }
                    $lbRes.Items[0] = '正在扫描局域网 ' + [Math]::Min(254, ($batch+1)*32) + '/254，请稍候...'
                    [System.Windows.Forms.Application]::DoEvents()
                }
            }
            $rows = @()
            try { $rows = arp.exe -a 2>$null } catch {}
            $lbRes.Items.Clear()
            $found = $false
            foreach ($r in $rows) {
                $r = $r -replace "\s+", " "
                $r = $r.Trim()
                if ($r -match "^(\d+\.\d+\.\d+\.\d+) ([\da-fA-F\-]{17})") {
                    $ip = $Matches[1]; $mac = $Matches[2]
                    $macU = $mac.ToUpper()
                    if ($macU -match '^01-00-5E|^FF-FF-FF' -or $ip -match '^(224|239|255)\.') { continue }
                    $mySeg = ($myIp -split '\.')[0..2] -join '.'
                    $ipSeg = ($ip -split '\.')[0..2] -join '.'
                    if ($mySeg -and $ipSeg -ne $mySeg) { continue }
                    $ouiKey = ($mac -replace '-', '').Substring(0, 6).ToUpper()
                    if ($ip -eq $myIp) { $type = '本机' }
                    elseif ($gateway -and $ip -eq $gateway) { $type = '路由器/网关' }
                    elseif ($oui.ContainsKey($ouiKey)) { $type = $oui[$ouiKey] }
                    [void]$lbRes.Items.Add($ip.PadRight(16) + ' ' + $type.PadRight(16) + ' ' + $mac.ToUpper())
                    $found = $true
                }
            }
            if (-not $found) { [void]$lbRes.Items.Add("(未扫描到在线设备，请确认在同一网络)") }
            $btnScan.Enabled = $true
        })
        $btnTest = New-Object System.Windows.Forms.Button
        $btnTest.Text = '检测互传能力'
        $btnTest.Size = New-Object System.Drawing.Size(150, 32)
        $btnTest.Location = New-Object System.Drawing.Point(15, 330)
        $btnTest.FlatStyle = 'Flat'
        $btnTest.FlatAppearance.BorderSize = 0
        $btnTest.BackColor = $accent
        $btnTest.ForeColor = [System.Drawing.Color]::White
        $nt.Controls.Add($btnTest)
        $btnTest.add_MouseEnter({ $btnTest.BackColor = $accentDark })
        $btnTest.add_MouseLeave({ $btnTest.BackColor = $accent })
        $lblTest = New-Object System.Windows.Forms.Label
        $lblTest.Text = '互传能力检测结果（SMB 445 端口）：'
        $lblTest.Location = New-Object System.Drawing.Point(15, 366)
        $lblTest.Size = New-Object System.Drawing.Size(490, 20)
        $lblTest.BackColor = [System.Drawing.Color]::White
        $nt.Controls.Add($lblTest)
        $txtTest = New-Object System.Windows.Forms.TextBox
        $txtTest.Location = New-Object System.Drawing.Point(15, 388)
        $txtTest.Size = New-Object System.Drawing.Size(490, 85)
        $txtTest.Multiline = $true
        $txtTest.ReadOnly = $true
        $txtTest.ScrollBars = 'Vertical'
        $nt.Controls.Add($txtTest)
        $btnTest.add_Click({
            $btnTest.Enabled = $false
            [void]$txtTest.Clear()
            $ips = @()
            foreach ($item in $lbRes.Items) {
                if ($item -match '^\d+\.\d+\.\d+\.\d+') { $ips += $Matches[0] }
            }
            if ($ips.Count -eq 0) { $txtTest.Text = '(请先点击"局域网 IP 扫描"获取设备列表)'; $btnTest.Enabled = $true; return }
            foreach ($ip in $ips) {
                $smb = $false
                try {
                    $client = New-Object System.Net.Sockets.TcpClient
                    $async = $client.BeginConnect($ip, 445, $null, $null)
                    $ok = $async.AsyncWaitHandle.WaitOne(600)
                    if ($ok -and $client.Connected) { $smb = $true }
                    $client.Close()
                } catch {}
                $status = if ($smb) { '可互传（SMB 445 开放）' } else { '不可互传（445 未开放）' }
                [void]$txtTest.AppendText($ip + "  →  " + $status + [Environment]::NewLine)
                [System.Windows.Forms.Application]::DoEvents()
            }
            $btnTest.Enabled = $true
        })
        $lblProxy = New-Object System.Windows.Forms.Label
        $lblProxy.Text = '代理 / VPN 检测结果：'
        $lblProxy.Location = New-Object System.Drawing.Point(15, 515)
        $lblProxy.Size = New-Object System.Drawing.Size(490, 20)
        $lblProxy.BackColor = [System.Drawing.Color]::White
        $nt.Controls.Add($lblProxy)
        $btnProxy = New-Object System.Windows.Forms.Button
        $btnProxy.Text = '检测代理 / VPN'
        $btnProxy.Size = New-Object System.Drawing.Size(150, 32)
        $btnProxy.Location = New-Object System.Drawing.Point(15, 479)
        $btnProxy.FlatStyle = 'Flat'
        $btnProxy.FlatAppearance.BorderSize = 0
        $btnProxy.BackColor = $accent
        $btnProxy.ForeColor = [System.Drawing.Color]::White
        $nt.Controls.Add($btnProxy)
        $btnProxy.add_MouseEnter({ $btnProxy.BackColor = $accentDark })
        $btnProxy.add_MouseLeave({ $btnProxy.BackColor = $accent })
        $txtProxy = New-Object System.Windows.Forms.TextBox
        $txtProxy.Location = New-Object System.Drawing.Point(15, 537)
        $txtProxy.Size = New-Object System.Drawing.Size(490, 85)
        $txtProxy.Multiline = $true
        $txtProxy.ReadOnly = $true
        $txtProxy.ScrollBars = 'Vertical'
        $nt.Controls.Add($txtProxy)
        $btnProxy.add_Click({
            $sb2 = New-Object System.Text.StringBuilder
            try {
                $ie = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
                if ($ie.ProxyEnable -eq 1) { [void]$sb2.AppendLine('[代理] 已开启: ' + $ie.ProxyServer) }
                else { [void]$sb2.AppendLine('[代理] 未开启') }
            } catch { [void]$sb2.AppendLine('[代理] 读取失败') }
            try {
                $vpn = @(Get-WmiObject Win32_NetworkAdapter | Where-Object { $_.NetConnectionID -and ($_.NetConnectionID -match 'VPN|WAN|TAP|TUN|Tunnel' -or $_.Description -match 'Virtual|TAP|TUN|OpenVPN|WireGuard') })
                $vpnOn = @()
                foreach ($v in $vpn) {
                    $vcfg = @(Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { $_.Index -eq $v.Index -and $_.IPEnabled })
                    foreach ($vc in $vcfg) {
                        $ipv4ok = $false
                        foreach ($ipa in $vc.IPAddress) { if ($ipa -match '^\d+\.\d+\.\d+\.\d+$' -and $ipa -notmatch '^169\.254\.') { $ipv4ok = $true; break } }
                        if ($ipv4ok) { $vpnOn += $v.NetConnectionID }
                    }
                }
                if ($vpnOn.Count -gt 0) { foreach ($vo in $vpnOn) { [void]$sb2.AppendLine('[VPN] 已开启: ' + $vo) } }
                else { [void]$sb2.AppendLine('[VPN] 未开启') }
            } catch { [void]$sb2.AppendLine('[VPN] 检测失败') }
            $txtProxy.Text = $sb2.ToString()
        })
        $btnClose = New-Object System.Windows.Forms.Button
        $btnClose.Text = '关闭'
        $btnClose.Size = New-Object System.Drawing.Size(100, 30)
        $btnClose.Location = New-Object System.Drawing.Point(210, 805)
        $btnClose.FlatStyle = 'Flat'
        $btnClose.FlatAppearance.BorderSize = 0
        $btnClose.BackColor = $accent
        $btnClose.ForeColor = [System.Drawing.Color]::White
        $nt.Controls.Add($btnClose)
        $btnClose.add_MouseEnter({ $btnClose.BackColor = $accentDark })
        $btnClose.add_MouseLeave({ $btnClose.BackColor = $accent })
        $btnNdisc = New-Object System.Windows.Forms.Button
        $btnNdisc.Text = '检测网络发现'
        $btnNdisc.Size = New-Object System.Drawing.Size(150, 32)
        $btnNdisc.Location = New-Object System.Drawing.Point(15, 625)
        $btnNdisc.FlatStyle = 'Flat'
        $btnNdisc.FlatAppearance.BorderSize = 0
        $btnNdisc.BackColor = $accent
        $btnNdisc.ForeColor = [System.Drawing.Color]::White
        $nt.Controls.Add($btnNdisc)
        $btnNdisc.add_MouseEnter({ $btnNdisc.BackColor = $accentDark })
        $btnNdisc.add_MouseLeave({ $btnNdisc.BackColor = $accent })
        $lblNdisc = New-Object System.Windows.Forms.Label
        $lblNdisc.Text = '网络发现检测结果：'
        $lblNdisc.Location = New-Object System.Drawing.Point(15, 661)
        $lblNdisc.Size = New-Object System.Drawing.Size(490, 20)
        $lblNdisc.BackColor = [System.Drawing.Color]::White
        $nt.Controls.Add($lblNdisc)
        $txtNdisc = New-Object System.Windows.Forms.TextBox
        $txtNdisc.Location = New-Object System.Drawing.Point(15, 683)
        $txtNdisc.Size = New-Object System.Drawing.Size(490, 85)
        $txtNdisc.ScrollBars = 'Vertical'
        $txtNdisc.Multiline = $true
        $txtNdisc.ReadOnly = $true
        $nt.Controls.Add($txtNdisc)
        $btnNdisc.add_Click({
            $sb3 = New-Object System.Text.StringBuilder
            foreach ($sn in @('FDResPub','FDpHost','upnphost','SSDPSRV')) {
                $cn = switch ($sn) { 'FDResPub' { '功能发现资源发布' } 'FDpHost' { '功能发现提供程序主机' } 'upnphost' { 'UPnP 设备主机' } 'SSDPSRV' { 'SSDP 发现服务' } default { $sn } }
                try {
                    $s = Get-Service $sn -ErrorAction SilentlyContinue
                    if ($s) {
                        $st = switch ($s.Status.ToString()) { 'Running' { '正在运行' } 'Stopped' { '已停止' } 'StartPending' { '正在启动' } 'StopPending' { '正在停止' } 'Paused' { '已暂停' } 'ContinuePending' { '正在继续' } default { $s.Status } }
                        [void]$sb3.AppendLine('[OK] ' + $cn + ': ' + $st)
                    }
                    else { [void]$sb3.AppendLine('[警告] ' + $cn + ': 未安装') }
                } catch { [void]$sb3.AppendLine('[未知] ' + $cn + ': 检测失败') }
            }
            try {
                $pf = @(netsh advfirewall show currentprofile 2>$null)
                $pfName = '未知'; $pfState = ''
                foreach ($pl in $pf) {
                    if ($pl -match '公用配置文件|Public Profile') { $pfName = '公用网络' }
                    elseif ($pl -match '专用配置文件|Private Profile') { $pfName = '专用网络' }
                    elseif ($pl -match '域配置文件|Domain Profile') { $pfName = '域网络' }
                    elseif ($pl -match '(当前配置文件|Current Profile)\s*:\s*(\S+)') {
                        $cp = $Matches[2]
                        if ($cp -match '公用|Public') { $pfName = '公用网络' }
                        elseif ($cp -match '专用|Private') { $pfName = '专用网络' }
                        elseif ($cp -match '域|Domain') { $pfName = '域网络' }
                    }
                    if ($pl -match '(状态|State)\s*(:)?\s*(\S+)') {
                        $sv = $Matches[3]
                        if ($sv -match 'ON|启用|Enabled|Yes') { $pfState = '启用' }
                        elseif ($sv -match 'OFF|禁用|Disabled|No') { $pfState = '关闭' }
                        else { $pfState = $sv }
                    }
                }
                $fwState = '未知'
                if ($pfState) { $fwState = $pfState }
                [void]$sb3.AppendLine('[信息] 当前网络配置文件: ' + $pfName + '，防火墙: ' + $fwState)
                if ($pfName -eq '公用网络') { [void]$sb3.AppendLine('[提示] 公用网络默认禁用网络发现，请将网络切换为"专用"') }
            } catch {}
            try {
                $disc = @(netsh advfirewall firewall show rule group=网络发现 2>$null)
                if ($disc.Count -le 1) { $disc = @(netsh advfirewall firewall show rule group="Network Discovery" 2>$null) }
                if ($disc.Count -gt 1) {
                    $discEn = ($disc | Where-Object { $_ -match '已启用\s*:\s*是|已启用\s*:\s*Yes|Enabled\s*:\s*Yes' }).Count
                    if ($discEn -gt 0) { [void]$sb3.AppendLine('[OK] 防火墙"网络发现"规则已启用') }
                    else { [void]$sb3.AppendLine('[警告] 防火墙"网络发现"规则未启用') }
                } else { [void]$sb3.AppendLine('[提示] 无法枚举网络发现规则(GPO 管理)，请检查控制面板-高级共享设置') }
            } catch { [void]$sb3.AppendLine('[未知] 防火墙规则检测失败') }
            $txtNdisc.Text = $sb3.ToString()
        })
        $btnClose.add_Click({ $nt.Close() })
        [void]$nt.ShowDialog()
    })
    $btnView = New-Object System.Windows.Forms.Button
    $btnView.Text = '查看共享'
    $btnView.Size = New-Object System.Drawing.Size(135, 36)
    $btnView.Location = New-Object System.Drawing.Point(387, 424)
    $btnView.FlatStyle = 'Flat'
    $btnView.FlatAppearance.BorderColor = $accent
    $btnView.FlatAppearance.BorderSize = 1
    $btnView.BackColor = [System.Drawing.Color]::White
    $btnView.ForeColor = $accent
    $form.Controls.Add($btnView)
    $btnView.add_MouseEnter({ $btnView.BackColor = $hoverBg })
    $btnView.add_MouseLeave({ $btnView.BackColor = [System.Drawing.Color]::White })
    $btnView.add_Click({
        $vw = New-Object System.Windows.Forms.Form
        $vw.Text = '当前共享状态'
        $vw.ClientSize = New-Object System.Drawing.Size(520, 380)
        $vw.StartPosition = 'CenterParent'
        $vw.FormBorderStyle = 'FixedDialog'
        $vw.MaximizeBox = $false
        $vw.MinimizeBox = $false
        $vw.BackColor = [System.Drawing.Color]::White
        $lv = New-Object System.Windows.Forms.ListView
        $lv.Location = New-Object System.Drawing.Point(15, 15)
        $lv.Size = New-Object System.Drawing.Size(490, 320)
        $lv.View = 'Details'
        $lv.FullRowSelect = $true
        $lv.GridLines = $true
        $lv.Columns.Add('共享名', 130) | Out-Null
        $lv.Columns.Add('路径', 280) | Out-Null
        $lv.Columns.Add('类型', 70) | Out-Null
        try {
            $shares = Get-WmiObject Win32_Share | Where-Object { $_.Name -notmatch "^(ADMIN|IPC)" }
            foreach ($s in $shares) {
                $typeStr = switch ($s.Type) { 0 {'磁盘'} 1 {'打印'} default {'其他'} }
                [void]$lv.Items.Add((New-Object System.Windows.Forms.ListViewItem -ArgumentList (,[string[]]@($s.Name, $s.Path, $typeStr))))
            }
        } catch {}
        if ($lv.Items.Count -eq 0) {
            [void]$lv.Items.Add((New-Object System.Windows.Forms.ListViewItem -ArgumentList (,[string[]]@("(无共享)", "", ""))))
        }
        $vw.Controls.Add($lv)
        $btnClose = New-Object System.Windows.Forms.Button
        $btnClose.Text = '关闭'
        $btnClose.Size = New-Object System.Drawing.Size(100, 30)
        $btnClose.Location = New-Object System.Drawing.Point(210, 345)
        $btnClose.FlatStyle = 'Flat'
        $btnClose.FlatAppearance.BorderSize = 0
        $btnClose.BackColor = $accent
        $btnClose.ForeColor = [System.Drawing.Color]::White
        $vw.Controls.Add($btnClose)
        $btnClose.add_Click({ $vw.Close() })
        [void]$vw.ShowDialog()
    })
    $btnAll = New-Object System.Windows.Forms.Button
    $btnAll.Text = '共享所有磁盘'
    $btnAll.Location = New-Object System.Drawing.Point(242, 424)
    $btnAll.Size = New-Object System.Drawing.Size(135, 36)
    $btnAll.FlatStyle = 'Flat'
    $btnAll.FlatAppearance.BorderColor = $accent
    $btnAll.FlatAppearance.BorderSize = 1
    $btnAll.BackColor = [System.Drawing.Color]::White
    $btnAll.ForeColor = $accent
    $form.Controls.Add($btnAll)
    $btnAll.add_MouseEnter({ $btnAll.BackColor = $hoverBg })
    $btnAll.add_MouseLeave({ $btnAll.BackColor = [System.Drawing.Color]::White })
    $btnAll.add_Click({
        $c = [System.Windows.Forms.MessageBox]::Show("将共享所有非 C 盘的磁盘（D、E 等）。继续吗？", "确认", "YesNo", "Question")
        if ($c -ne "Yes") { return }
        $launchArgs = @("-NoProfile","-ExecutionPolicy","Bypass","-WindowStyle","Hidden","-File",$script:scriptPath,"-ShareAll","-NoPause")
        Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList $launchArgs
    })
    $btnAbout = New-Object System.Windows.Forms.Button
    $btnAbout.FlatStyle = 'Flat'
    $btnAbout.Text = '关于软件'
    $btnAbout.Size = New-Object System.Drawing.Size(135, 36)
    $btnAbout.FlatAppearance.BorderColor = $accent
    $btnAbout.FlatAppearance.BorderSize = 1
    $btnAbout.Location = New-Object System.Drawing.Point(387, 474)
    $btnAbout.BackColor = [System.Drawing.Color]::White
    $btnAbout.ForeColor = $accent
    $form.Controls.Add($btnAbout)
    $btnAbout.add_MouseEnter({ $btnAbout.BackColor = $hoverBg })
    $btnAbout.add_MouseLeave({ $btnAbout.BackColor = [System.Drawing.Color]::White })
    $btnAbout.add_Click({
        $nl = [Environment]::NewLine
        $about = New-Object System.Windows.Forms.Form
        $about.Text = '关于软件'
        $about.ClientSize = New-Object System.Drawing.Size(520, 150)
        $about.StartPosition = "CenterParent"
        $about.KeyPreview = $true
        $about.FormBorderStyle = "FixedDialog"
        $about.MaximizeBox = $false
        $about.MinimizeBox = $false
        $about.BackColor = [System.Drawing.Color]::White
        $txt = New-Object System.Windows.Forms.Label
        $txt.Location = New-Object System.Drawing.Point(20, 10)
        $txt.Size = New-Object System.Drawing.Size(480, 90)
        $txt.Text = "局域网共享工具 v1.4" + $nl + $nl +
            "在家庭/办公局域网内快速配置文件共享与打印机共享。" + $nl +
            "兼容 Windows Vista/7/8/8.1/10/11，需管理员权限。"
        $about.Controls.Add($txt)
        $link = New-Object System.Windows.Forms.LinkLabel
        $link.Text = "GitHub"
        $link.Location = New-Object System.Drawing.Point(20, 110)
        $link.Size = New-Object System.Drawing.Size(350, 20)
        $link.add_LinkClicked({ Start-Process "https://github.com/Leosley1314/lan-share-tool" })
        $link.TabStop = $false
        $about.Controls.Add($link)
        $ok = New-Object System.Windows.Forms.Button
        $ok.Text = "确定"
        $ok.Location = New-Object System.Drawing.Point(420, 105)
        $ok.Size = New-Object System.Drawing.Size(85, 30)
        $ok.FlatStyle = "Flat"
        $ok.FlatAppearance.BorderSize = 0
        $ok.TabStop = $false
        $ok.BackColor = $accent
        $ok.ForeColor = [System.Drawing.Color]::White
        $about.Controls.Add($ok)
        $ok.add_MouseEnter({ $ok.BackColor = $accentDark })
        $ok.add_MouseLeave({ $ok.BackColor = $accent })
        $ok.add_Click({ $about.Close() })
        [void]$about.ShowDialog()
    })
    $btnMaint = New-Object System.Windows.Forms.Button
    $btnMaint.Text = '系统维护'
    $btnMaint.Size = New-Object System.Drawing.Size(135, 36)
    $btnMaint.Location = New-Object System.Drawing.Point(97, 474)
    $btnMaint.FlatStyle = 'Flat'
    $btnMaint.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(200, 60, 60)
    $btnMaint.FlatAppearance.BorderSize = 1
    $btnMaint.BackColor = [System.Drawing.Color]::White
    $btnMaint.ForeColor = [System.Drawing.Color]::FromArgb(200, 60, 60)
    $form.Controls.Add($btnMaint)
    $btnMaint.add_MouseEnter({ $btnMaint.BackColor = $redHover })
    $btnMaint.add_MouseLeave({ $btnMaint.BackColor = [System.Drawing.Color]::White })
    $btnMaint.add_Click({
        $mf = New-Object System.Windows.Forms.Form
        $mf.Text = '系统维护'
        $mf.ClientSize = New-Object System.Drawing.Size(360, 360)
        $mf.FormBorderStyle = 'FixedSingle'
        $mf.StartPosition = 'CenterParent'
        $mf.MaximizeBox = $false
        $mf.MinimizeBox = $false
        $mf.BackColor = [System.Drawing.Color]::White
        $l1 = New-Object System.Windows.Forms.Label
        $l1.Text = '选择要执行的操作：'
        $l1.Location = New-Object System.Drawing.Point(20, 16)
        $l1.Size = New-Object System.Drawing.Size(320, 24)
        $l1.TextAlign = 'MiddleLeft'
        $mf.Controls.Add($l1)
        $b1 = New-Object System.Windows.Forms.Button
        $b1.Text = '重启资源管理器'
        $b1.Size = New-Object System.Drawing.Size(320, 40)
        $b1.Location = New-Object System.Drawing.Point(20, 52)
        $b1.FlatStyle = 'Flat'
        $b1.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(200, 60, 60)
        $b1.BackColor = [System.Drawing.Color]::White
        $b1.ForeColor = [System.Drawing.Color]::FromArgb(200, 60, 60)
        $b1.add_Click({
            $mf.Close()
            $c = [System.Windows.Forms.MessageBox]::Show("将重启 Windows 资源管理器（桌面会短暂消失后自动恢复）。继续吗？", "确认", "YesNo", "Question")
            if ($c -eq [System.Windows.Forms.DialogResult]::Yes) { Restart-Explorer }
        })
        $mf.Controls.Add($b1)
        $b1.add_MouseEnter({ $b1.BackColor = $redHover })
        $b1.add_MouseLeave({ $b1.BackColor = [System.Drawing.Color]::White })
        $b2 = New-Object System.Windows.Forms.Button
        $b2.Text = '取消所有共享'
        $b2.Size = New-Object System.Drawing.Size(320, 40)
        $b2.Location = New-Object System.Drawing.Point(20, 102)
        $b2.FlatStyle = 'Flat'
        $b2.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(200, 60, 60)
        $b2.BackColor = [System.Drawing.Color]::White
        $b2.ForeColor = [System.Drawing.Color]::FromArgb(200, 60, 60)
        $b2.add_Click({
            $mf.Close()
            $c = [System.Windows.Forms.MessageBox]::Show('将删除所有共享并移除防火墙规则，还原为默认状态。继续吗？', '确认', 'YesNo', 'Question')
            if ($c -ne 'Yes') { return }
            if ($script:IsExe) {
                Start-Process -FilePath $script:scriptPath -Verb RunAs -ArgumentList @('-ClearAll','-NoPause')
            } else {
                Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$script:scriptPath,'-ClearAll','-NoPause')
            }
        })
        $mf.Controls.Add($b2)
        $b2.add_MouseEnter({ $b2.BackColor = $redHover })
        $b2.add_MouseLeave({ $b2.BackColor = [System.Drawing.Color]::White })
        $bConn = New-Object System.Windows.Forms.Button
        $bConn.Text = '共享连接监控'
        $bConn.Size = New-Object System.Drawing.Size(320, 40)
        $bConn.Location = New-Object System.Drawing.Point(20, 152)
        $bConn.FlatStyle = 'Flat'
        $bConn.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(200, 60, 60)
        $bConn.BackColor = [System.Drawing.Color]::White
        $bConn.ForeColor = [System.Drawing.Color]::FromArgb(200, 60, 60)
        $bConn.add_Click({
            $mf.Close()
            $cf = New-Object System.Windows.Forms.Form
            $cf.Text = '共享连接监控'
            $cf.ClientSize = New-Object System.Drawing.Size(560, 430)
            $cf.StartPosition = 'CenterParent'
            $cf.FormBorderStyle = 'FixedSingle'
            $cf.MaximizeBox = $false
            $cf.MinimizeBox = $false
            $cf.BackColor = [System.Drawing.Color]::White
            $tab = New-Object System.Windows.Forms.TabControl
            $tab.Location = New-Object System.Drawing.Point(15, 12)
            $tab.Size = New-Object System.Drawing.Size(530, 340)
            $tab1 = New-Object System.Windows.Forms.TabPage
            $tab1.Text = '会话连接'
            $tab2 = New-Object System.Windows.Forms.TabPage
            $tab2.Text = '打开的文件'
            $lvS = New-Object System.Windows.Forms.ListView
            $lvS.Location = New-Object System.Drawing.Point(8, 8)
            $lvS.Size = New-Object System.Drawing.Size(505, 240)
            $lvS.View = 'Details'; $lvS.FullRowSelect = $true; $lvS.GridLines = $true
            $lvS.Columns.Add('计算机', 160) | Out-Null
            $lvS.Columns.Add('用户名', 110) | Out-Null
            $lvS.Columns.Add('客户端类型', 120) | Out-Null
            $lvS.Columns.Add('空闲时间', 90) | Out-Null
            $tab1.Controls.Add($lvS)
            $btnRefS = New-Object System.Windows.Forms.Button
            $btnRefS.Text = '刷新'
            $btnRefS.Size = New-Object System.Drawing.Size(90, 28)
            $btnRefS.Location = New-Object System.Drawing.Point(8, 258)
            $tab1.Controls.Add($btnRefS)
            $btnKick = New-Object System.Windows.Forms.Button
            $btnKick.Text = '断开选中'
            $btnKick.Size = New-Object System.Drawing.Size(110, 28)
            $btnKick.Location = New-Object System.Drawing.Point(108, 258)
            $tab1.Controls.Add($btnKick)
            $lvF = New-Object System.Windows.Forms.ListView
            $lvF.Location = New-Object System.Drawing.Point(8, 8)
            $lvF.Size = New-Object System.Drawing.Size(505, 240)
            $lvF.View = 'Details'; $lvF.FullRowSelect = $true; $lvF.GridLines = $true
            $lvF.Columns.Add('ID', 60) | Out-Null
            $lvF.Columns.Add('已打开路径', 220) | Out-Null
            $lvF.Columns.Add('用户', 110) | Out-Null
            $lvF.Columns.Add('锁定状态', 80) | Out-Null
            $tab2.Controls.Add($lvF)
            $btnRefF = New-Object System.Windows.Forms.Button
            $btnRefF.Text = '刷新'
            $btnRefF.Size = New-Object System.Drawing.Size(90, 28)
            $btnRefF.Location = New-Object System.Drawing.Point(8, 258)
            $tab2.Controls.Add($btnRefF)
            $btnCloseF = New-Object System.Windows.Forms.Button
            $btnCloseF.Text = '关闭选中'
            $btnCloseF.Size = New-Object System.Drawing.Size(110, 28)
            $btnCloseF.Location = New-Object System.Drawing.Point(108, 258)
            $tab2.Controls.Add($btnCloseF)
            $tab.TabPages.Add($tab1)
            $tab.TabPages.Add($tab2)
            $cf.Controls.Add($tab)
            $btnOk = New-Object System.Windows.Forms.Button
            $btnOk.Text = '关闭'
            $btnOk.Size = New-Object System.Drawing.Size(100, 30)
            $btnOk.Location = New-Object System.Drawing.Point(230, 365)
            $cf.Controls.Add($btnOk)
            $btnOk.add_Click({ $cf.Close() })
            $refreshS = {
                $lvS.Items.Clear()
                $sess = @(net session 2>$null)
                foreach ($s in $sess) {
                    if ($s -match '^\s*\\\\(\S+)\s+(\S+)\s+(\S+)\s+(\S+)\s*$') {
                        [void]$lvS.Items.Add((New-Object System.Windows.Forms.ListViewItem -ArgumentList (,[string[]]@($Matches[1], $Matches[2], $Matches[3], $Matches[4]))))
                    }
                }
                if ($lvS.Items.Count -eq 0) { [void]$lvS.Items.Add((New-Object System.Windows.Forms.ListViewItem -ArgumentList (,[string[]]@('(无活动会话)', '', '', '')))) }
            }
            & $refreshS
            $btnRefS.add_Click({ & $refreshS })
            $btnKick.add_Click({
                $sel = $lvS.SelectedItems
                if ($sel.Count -gt 0) {
                    $comp = $sel[0].SubItems[0].Text
                    if ($comp -ne '(无活动会话)') {
                        $c = [System.Windows.Forms.MessageBox]::Show("断开与 " + $comp + " 的连接？", "确认", "YesNo", "Question")
                        if ($c -eq 'Yes') { $null = & net.exe session ('\\' + $comp) /delete 2>&1; & $refreshS }
                    }
                }
            })
            $refreshF = {
                $lvF.Items.Clear()
                $files = @(net file 2>$null)
                foreach ($f in $files) {
                    if ($f -match '^\s*(\d+)\s+(\S+)\s+(\S+)\s+(\S+)\s*$') {
                        [void]$lvF.Items.Add((New-Object System.Windows.Forms.ListViewItem -ArgumentList (,[string[]]@($Matches[1], $Matches[2], $Matches[3], $Matches[4]))))
                    }
                }
                if ($lvF.Items.Count -eq 0) { [void]$lvF.Items.Add((New-Object System.Windows.Forms.ListViewItem -ArgumentList (,[string[]]@('(无打开的文件)', '', '', '')))) }
            }
            & $refreshF
            $btnRefF.add_Click({ & $refreshF })
            $btnCloseF.add_Click({
                $sel = $lvF.SelectedItems
                if ($sel.Count -gt 0) {
                    $id = $sel[0].SubItems[0].Text
                    if ($id -match '^\d+$') {
                        $c = [System.Windows.Forms.MessageBox]::Show("关闭文件 ID " + $id + "？", "确认", "YesNo", "Question")
                        if ($c -eq 'Yes') { $null = & net.exe file $id /close 2>&1; & $refreshF }
                    }
                }
            })
            [void]$cf.ShowDialog()
        })
        $mf.Controls.Add($bConn)
        $bConn.add_MouseEnter({ $bConn.BackColor = $redHover })
        $bConn.add_MouseLeave({ $bConn.BackColor = [System.Drawing.Color]::White })
        $b4 = New-Object System.Windows.Forms.Button
        $b4.Text = '修复防火墙'
        $b4.Size = New-Object System.Drawing.Size(320, 40)
        $b4.Location = New-Object System.Drawing.Point(20, 202)
        $b4.FlatStyle = 'Flat'
        $b4.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(200, 60, 60)
        $b4.BackColor = [System.Drawing.Color]::White
        $b4.ForeColor = [System.Drawing.Color]::FromArgb(200, 60, 60)
        $b4.add_Click({
            $mf.Close()
            $c = [System.Windows.Forms.MessageBox]::Show('将重新启用文件和打印机共享的防火墙规则，并确保 445/137-139 端口放行。继续吗？', '确认', 'YesNo', 'Question')
            if ($c -ne 'Yes') { return }
            if ($script:IsExe) { Start-Process -FilePath $script:scriptPath -Verb RunAs -ArgumentList @('-FixFirewall','-NoPause') }
            else { Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$script:scriptPath,'-FixFirewall','-NoPause') }
        })
        $mf.Controls.Add($b4)
        $b4.add_MouseEnter({ $b4.BackColor = $redHover })
        $b4.add_MouseLeave({ $b4.BackColor = [System.Drawing.Color]::White })
        $b5 = New-Object System.Windows.Forms.Button
        $b5.Text = '修复网络'
        $b5.Size = New-Object System.Drawing.Size(320, 40)
        $b5.Location = New-Object System.Drawing.Point(20, 252)
        $b5.FlatStyle = 'Flat'
        $b5.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(200, 60, 60)
        $b5.BackColor = [System.Drawing.Color]::White
        $b5.ForeColor = [System.Drawing.Color]::FromArgb(200, 60, 60)
        $b5.add_Click({
            $mf.Close()
            $c = [System.Windows.Forms.MessageBox]::Show('将重置 Winsock 与 IP 协议栈（建议之后重启计算机）。继续吗？', '确认', 'YesNo', 'Question')
            if ($c -ne 'Yes') { return }
            if ($script:IsExe) { Start-Process -FilePath $script:scriptPath -Verb RunAs -ArgumentList @('-FixNetwork','-NoPause') }
            else { Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$script:scriptPath,'-FixNetwork','-NoPause') }
        })
        $mf.Controls.Add($b5)
        $b5.add_MouseEnter({ $b5.BackColor = $redHover })
        $b5.add_MouseLeave({ $b5.BackColor = [System.Drawing.Color]::White })
        $b6 = New-Object System.Windows.Forms.Button
        $b6.Text = '网络重置'
        $b6.Size = New-Object System.Drawing.Size(320, 40)
        $b6.Location = New-Object System.Drawing.Point(20, 302)
        $b6.FlatStyle = 'Flat'
        $b6.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(200, 60, 60)
        $b6.BackColor = [System.Drawing.Color]::White
        $b6.ForeColor = [System.Drawing.Color]::FromArgb(200, 60, 60)
        $b6.add_Click({
            $mf.Close()
            $c = [System.Windows.Forms.MessageBox]::Show('将重置 Winsock/IP 协议栈并重启网络适配器（网络会短暂断开后自动恢复）。继续吗？', '确认', 'YesNo', 'Question')
            if ($c -ne 'Yes') { return }
            if ($script:IsExe) { Start-Process -FilePath $script:scriptPath -Verb RunAs -ArgumentList @('-NetReset','-NoPause') }
            else { Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$script:scriptPath,'-NetReset','-NoPause') }
        })
        $mf.Controls.Add($b6)
        $b6.add_MouseEnter({ $b6.BackColor = $redHover })
        $b6.add_MouseLeave({ $b6.BackColor = [System.Drawing.Color]::White })
        [void]$mf.ShowDialog()
    })
    $btnStart = New-Object System.Windows.Forms.Button
    $btnStart.Text = '开始配置'
    $btnStart.BackColor = $accent
    $btnStart.ForeColor = [System.Drawing.Color]::White
    $btnStart.FlatStyle = 'Flat'
    $btnStart.FlatAppearance.BorderSize = 0
    $btnStart.Size = New-Object System.Drawing.Size(135, 36)
    $btnStart.Location = New-Object System.Drawing.Point(242, 474)
    $form.Controls.Add($btnStart)
    $btnStart.add_MouseEnter({ $btnStart.BackColor = $accentDark })
    $btnStart.add_MouseLeave({ $btnStart.BackColor = $accent })
    $btnStart.add_Click({
        $btnStart.Enabled = $false
        $selPath = ''
        $selIdx = $combo.SelectedIndex
        if ($selIdx -ge 0 -and $selIdx -lt $drivePaths.Count) { $selPath = $drivePaths[$selIdx] }
        elseif ($selIdx -eq $drivePaths.Count) {
            $selPath = $txt.Text.Trim()
            if (-not $selPath) {
                [void][System.Windows.Forms.MessageBox]::Show('请先输入要共享的文件夹路径。', '提示')
                $btnStart.Enabled = $true; return
            }
        } else { $selPath = $script:DefaultSharePath }
        $launchArgs = @('-NoPause')
        if ($selPath) { $launchArgs += @('-SharePath', $selPath) }
        if ($chkRO.Checked) { $launchArgs += '-ReadOnly' }
        if (-not $chkGuest.Checked) { $launchArgs += '-NoGuest'; if ($txtUser.Text.Trim()) { $launchArgs += @('-ShareUser', $txtUser.Text.Trim()) }; if ($txtPw.Text) { $launchArgs += @('-SharePw', $txtPw.Text) } }
        if (-not $chkDisc.Checked) { $launchArgs += '-NoDiscovery' }
        if (-not $chkPrinter.Checked) { $launchArgs += '-NoPrinter' }
        if ($script:IsExe) {
            Start-Process -FilePath $script:scriptPath -Verb RunAs -ArgumentList $launchArgs
        } else {
            $psArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File',$script:scriptPath) + $launchArgs
            Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $psArgs
        }
        $btnStart.Enabled = $true
    })
    $form.add_Shown({
        $lblW2 = $lblPath.PreferredWidth
        $comboW2 = 305
        $rowW2 = $lblW2 + 8 + $comboW2 + 8 + $btnBrowse.Width
        $startX2 = [math]::Round([math]::Max(0, ($gbPath.Width - $rowW2) / 2))
        $lblPath.Location = New-Object System.Drawing.Point($startX2, 31)
        $comboX2 = $startX2 + $lblW2 + 8
        $combo.Location = New-Object System.Drawing.Point($comboX2, 33)
        $btnX2 = $startX2 + $lblW2 + 8 + $comboW2 + 8
        $btnBrowse.Location = New-Object System.Drawing.Point($btnX2, 31)
    })
    [void]$form.ShowDialog()
}
function Show-Disclaimer {
    $dlg = New-Object System.Windows.Forms.Form
    $accent = Get-Accent
    $accentDarkD = [System.Drawing.Color]::FromArgb([int]($accent.R*0.82), [int]($accent.G*0.82), [int]($accent.B*0.82))
    $redHoverD = [System.Drawing.Color]::FromArgb(252, 232, 232)
    $dlg.Text = "免责声明"
    $dlg.ClientSize = New-Object System.Drawing.Size(480, 300)
    $dlg.StartPosition = "CenterScreen"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $txt = New-Object System.Windows.Forms.Label
    $txt.Location = New-Object System.Drawing.Point(20, 15)
    $txt.Size = New-Object System.Drawing.Size(440, 220)
    $nl = [Environment]::NewLine
    $txt.Text = "使用前请阅读免责声明：" + $nl + $nl +
        "1. 无密码访客(Guest)模式下，同一网络内任何设备均可读写共享内容，请勿在公共网络环境开启。" + $nl +
        "2. 共享整个磁盘会暴露该盘全部文件，可能被误删、篡改或泄露，请先确认无敏感数据。" + $nl +
        "3. 请仅在你信任并可控的网络中使用；配置完成后建议及时关闭不再需要的共享。" + $nl +
        "4. 本工具按原样提供，不附带任何担保；因使用导致的数据损失由使用者自行承担。"
    $dlg.Controls.Add($txt)
    $btnAccept = New-Object System.Windows.Forms.Button
    $btnAccept.Text = "接受"
    $btnAccept.Location = New-Object System.Drawing.Point(250, 245)
    $btnAccept.Size = New-Object System.Drawing.Size(90, 30)
    $btnAccept.FlatStyle = "Flat"
    $btnAccept.FlatAppearance.BorderSize = 0
    $btnAccept.BackColor = $accent
    $btnAccept.ForeColor = [System.Drawing.Color]::White
    $btnAccept.add_Click({ $dlg.DialogResult = "OK"; $dlg.Close() })
    $dlg.Controls.Add($btnAccept)
    $btnAccept.add_MouseEnter({ $btnAccept.BackColor = $accentDarkD })
    $btnAccept.add_MouseLeave({ $btnAccept.BackColor = $accent })
    $btnReject = New-Object System.Windows.Forms.Button
    $btnReject.Text = "拒绝"
    $btnReject.Location = New-Object System.Drawing.Point(360, 245)
    $btnReject.Size = New-Object System.Drawing.Size(90, 30)
    $btnReject.FlatStyle = "Flat"
    $btnReject.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(200,60,60)
    $btnReject.FlatAppearance.BorderSize = 1
    $btnReject.BackColor = [System.Drawing.Color]::White
    $btnReject.ForeColor = [System.Drawing.Color]::FromArgb(200,60,60)
    $btnReject.add_Click({ $dlg.DialogResult = "Cancel"; $dlg.Close() })
    $dlg.Controls.Add($btnReject)
    $btnReject.add_MouseEnter({ $btnReject.BackColor = $redHoverD })
    $btnReject.add_MouseLeave({ $btnReject.BackColor = [System.Drawing.Color]::White })
    return $dlg.ShowDialog() -eq "OK"
}
if (-not $ClearAll -and -not $FixFirewall -and -not $FixNetwork -and -not $NetReset -and -not $SharePath -and -not $ShareAll) { $Gui = $true }
if ($Gui) {
    if (-not (Show-Disclaimer)) { exit }
    Show-Gui
    exit
}
# ---------- 自我提权 ----------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $NoElevate) {
    $innerArgs = @()
    if ($SharePath)   { $innerArgs += @('-SharePath', $SharePath) }
    if ($ReadOnly)    { $innerArgs += '-ReadOnly' }
    if ($NoGuest)     { $innerArgs += '-NoGuest' }
    if ($ShareUser)   { $innerArgs += @('-ShareUser', $ShareUser) }
    if ($SharePw)     { $innerArgs += @('-SharePw', $SharePw) }
    if ($NoDiscovery) { $innerArgs += '-NoDiscovery' }
    if ($NoPause)     { $innerArgs += '-NoPause' }
    if ($ClearAll)    { $innerArgs += '-ClearAll' }
    if ($FixFirewall) { $innerArgs += '-FixFirewall' }
    if ($FixNetwork)  { $innerArgs += '-FixNetwork' }
    if ($NetReset)    { $innerArgs += '-NetReset' }
    if ($ShareAll)    { $innerArgs += '-ShareAll' }
    if ($NoPrinter)   { $innerArgs += '-NoPrinter' }
    if ($script:IsExe) {
        Start-Process -FilePath $script:scriptPath -Verb RunAs -ArgumentList $innerArgs
    } else {
        $psArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script:scriptPath) + $innerArgs
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $psArgs
    }
    exit
}
if ($ClearAll) {
    Show-Progress
    Update-Progress '取消所有共享...' 50
    $shares = @()
    try { $shares = Get-WmiObject Win32_Share | Where-Object { $_.Name -notmatch '^(ADMIN|IPC|print$)' } } catch {}
    foreach ($s in $shares) {
        try {
            $ret = $s.Delete()
            if ($ret.ReturnValue -ne 0) { $null = & net.exe share $s.Name /delete 2>&1 }
        } catch {}
    }
    foreach ($rn in 'LAN-SMB-In-TCP','LAN-NB-In-TCP','LAN-NB-In-UDP') {
        $null = netsh advfirewall firewall delete rule name=$rn 2>&1
    }
    Update-Progress '关闭旧版文件共享协议(SMB1)...' 70
    try { Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' -Name SMB1 -Value 0 -Type DWord -Force } catch {}
    Update-Progress '关闭文件共享服务(Server)...' 85
    try { Stop-Service LanmanServer -Force -ErrorAction SilentlyContinue } catch {}
    try { Set-Service LanmanServer -StartupType Manual -ErrorAction SilentlyContinue } catch {}
    Update-Progress '完成' 100
    Start-Sleep 1
    Close-Progress
    [void][System.Windows.Forms.MessageBox]::Show('已取消所有共享。', '完成', 'OK', 'Information')
    $w = [System.Windows.Forms.MessageBox]::Show('为使更改立即生效，需要重启 Windows 资源管理器，重启会暂时关闭所有已打开的文件夹窗口，请先保存工作。', '警告', 'OKCancel', 'Warning')
    if ($w -eq 'OK') {
        $c = [System.Windows.Forms.MessageBox]::Show('确定现在重启资源管理器吗？', '确认', 'YesNo', 'Question')
        if ($c -eq 'Yes') { Restart-Explorer }
    }
    exit
}
if ($FixFirewall) {
    Show-Progress
    Update-Progress '修复防火墙...' 40
    $null = netsh advfirewall firewall set rule group="文件和打印机共享" new enable=Yes profile=any 2>&1
    $null = netsh advfirewall firewall set rule group="File and Printer Sharing" new enable=Yes profile=any 2>&1
    $null = netsh advfirewall firewall add rule name=LAN-SMB-In-TCP dir=in action=allow protocol=TCP localport=445 profile=any 2>&1
    $null = netsh advfirewall firewall add rule name=LAN-NB-In-TCP dir=in action=allow protocol=TCP localport=137-139 profile=any 2>&1
    $null = netsh advfirewall firewall add rule name=LAN-NB-In-UDP dir=in action=allow protocol=UDP localport=137-139 profile=any 2>&1
    Update-Progress '完成' 100
    Start-Sleep 1
    Close-Progress
    [void][System.Windows.Forms.MessageBox]::Show('防火墙修复完成：文件共享规则已启用，445/137-139 端口已放行。', '修复防火墙', 'OK', 'Information')
    exit
}
if ($FixNetwork) {
    Show-Progress
    Update-Progress '重置 Winsock...' 40
    $null = netsh winsock reset 2>&1
    Update-Progress '重置 IP 协议栈...' 80
    $null = netsh int ip reset 2>&1
    Update-Progress '完成' 100
    Start-Sleep 1
    Close-Progress
    [void][System.Windows.Forms.MessageBox]::Show('网络修复完成：Winsock 与 IP 协议栈已重置。建议重启计算机使更改完全生效。', '修复网络', 'OK', 'Information')
    exit
}
if ($NetReset) {
    Show-Progress
    Update-Progress '重置 Winsock...' 25
    $null = netsh winsock reset 2>&1
    Update-Progress '重置 IP 协议栈...' 50
    $null = netsh int ip reset 2>&1
    Update-Progress '重启网络适配器...' 75
    $ads = @(Get-WmiObject Win32_NetworkAdapter | Where-Object { $_.NetConnectionID -and $_.PhysicalAdapter })
    foreach ($ad in $ads) {
        try { $ad.Disable() | Out-Null } catch {}
        Start-Sleep -Milliseconds 800
        try { $ad.Enable() | Out-Null } catch {}
        Start-Sleep -Milliseconds 500
    }
    Update-Progress '完成' 100
    Start-Sleep 1
    Close-Progress
    [void][System.Windows.Forms.MessageBox]::Show('网络重置完成：Winsock/IP 栈已重置，网络适配器已重启。若仍异常建议重启计算机。', '网络重置', 'OK', 'Information')
    exit
}
# ---------- 开始配置 ----------
Show-Progress
Update-Progress '前置检查...' 5
Pre-Check
Update-Progress '配置防火墙...' 30
foreach ($g in @('文件和打印机共享','File and Printer Sharing')) { $null = netsh advfirewall firewall set rule group=$g new enable=Yes profile=any }
if ($effDiscovery) { foreach ($g in @('网络发现','Network Discovery')) { $null = netsh advfirewall firewall set rule group=$g new enable=Yes profile=any } }
foreach ($r in @(@{n='LAN-SMB-In-TCP';p='TCP';port='445'},@{n='LAN-NB-In-TCP';p='TCP';port='137-139'},@{n='LAN-NB-In-UDP';p='UDP';port='137-139'})) {
    $null = netsh advfirewall firewall add rule name=$($r.n) dir=in action=allow protocol=$($r.p) localport=$($r.port) profile=any
}
Update-Progress '启动系统服务...' 50
$svcList = @('FDResPub','FDpHost','upnphost','SSDPSRV')
if (-not $NoPrinter) { $svcList += 'spooler' }
foreach ($svc in $svcList) {
    $null = sc.exe config $svc start= auto
    $so = Get-Service $svc -ErrorAction SilentlyContinue
    if (-not $so -or $so.Status -ne 'Running') { $null = sc.exe start $svc 2>&1 }
}
foreach ($svc in @('LanmanWorkstation','LanmanServer')) {
    $null = sc.exe config $svc start= auto
    $so = Get-Service $svc -ErrorAction SilentlyContinue
    if (-not $so -or $so.Status -ne 'Running') { $null = sc.exe start $svc 2>&1 }
}
try {
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' -Name 'SMB1' -Value 1 -Type DWord -ErrorAction Stop
} catch {}
    # Windows 8+ 启用 SMB1 功能（如未安装则安装）
    try {
        $osVer = (Get-WmiObject Win32_OperatingSystem).Version
        if ([Version]$osVer -ge [Version]'6.2') {
            $null = dism.exe /online /enable-feature /featurename:SMB1Protocol /all /norestart 2>&1
        }
    } catch {}
Update-Progress '配置来宾账户访问(Guest)...' 70
if ($effGuest) {
    $null = net.exe user Guest /active:yes 2>&1
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' -Name 'RestrictNullSessAccess' -Value 0 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'LimitBlankPasswordUse' -Value 0 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Lsa' -Name 'everyoneincludesanonymous' -Value 1 -Type DWord -ErrorAction SilentlyContinue
    Set-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name 'LocalAccountTokenFilterPolicy' -Value 1 -Type DWord -ErrorAction SilentlyContinue
    $null = net.exe user Guest /passwordchg:no 2>&1
}
Update-Progress '创建共享...' 85
$sharePath = $script:InSharePath
if (-not $sharePath) { $sharePath = 'D:\' }
if (-not (Test-Path $sharePath)) {
    $sharePath = (Get-WmiObject Win32_LogicalDisk | Where-Object {$_.DriveType -eq 3 -and $_.DeviceID -ne 'C:'} | Select-Object -First 1).DeviceID + '\'
}
$shareName = if ($sharePath -match '^[A-Za-z]:\\$') { $sharePath.Substring(0,1) } else { Split-Path $sharePath -Leaf }
# 确定共享授权账户
$grantUser = "Everyone"
if (-not $effGuest -and $ShareUser) {
    $grantUser = $ShareUser
    if ($SharePw) { $null = net.exe user $ShareUser $SharePw 2>&1 }
    $null = net.exe user Guest /active:no 2>&1
}
$sharePerm = if ($ReadOnly) { 'READ' } else { 'FULL' }
$ntfsPerm  = if ($ReadOnly) { 'R' } else { 'M' }
if ($ShareAll) {
    foreach ($d in (Get-WmiObject Win32_LogicalDisk | Where-Object {$_.DriveType -eq 3 -and $_.DeviceID -ne 'C:' -and $_.FileSystem -eq 'NTFS'})) {
        $p = $d.DeviceID + '\'; $n = $d.DeviceID.Substring(0,1)
        $null = & net.exe share "$n=$p" "/grant:${grantUser},${sharePerm}" 2>&1
        $null = & icacls $p /grant "${grantUser}:(OI)(CI)${ntfsPerm}" 2>&1
    }
} else {
    $null = & net.exe share "$shareName=$sharePath" "/grant:${grantUser},${sharePerm}" 2>&1
    $null = & icacls $sharePath /grant "${grantUser}:(OI)(CI)${ntfsPerm}" 2>&1
}
Update-Progress '获取访问地址...' 95
$ip = $null
$adapters = Get-WmiObject Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled }
foreach ($a in $adapters) {
    foreach ($addr in $a.IPAddress) {
        if ($addr -match '^\d+\.\d+\.\d+\.\d+$' -and $addr -notlike '127.*' -and $addr -notlike '169.254.*') { $ip = $addr; break }
    }
    if ($ip) { break }
}
Update-Progress '完成' 100
Start-Sleep 1
Close-Progress
if ($ShareAll) {
    $msg = "磁盘共享设置完毕！" + "`n`n"
    if ($ip) { $msg += "Windows 访问: \\" + $ip + "`n"; $msg += "手机访问: smb://" + $ip + "`n" }
} else {
    $msg = "局域网共享配置完成！" + "`n`n"
    $msg += "共享路径: " + $sharePath + "`n"
    $msg += "共享名称: " + $shareName + "`n"
    if ($ip) { $msg += "Windows 访问: \\" + $ip + "`n"; $msg += "手机访问: smb://" + $ip + "`n" }
}
$selfTest = Test-ShareReady $shareName
$msg += "`n`n" + $selfTest
[void][System.Windows.Forms.MessageBox]::Show($msg, "配置完成", "OK", "Information")
$r2 = [System.Windows.Forms.MessageBox]::Show("为使共享立即生效，需要重启 Windows 资源管理器（重启会暂时关闭所有已打开的文件夹窗口，请先保存工作）。" + "`n`n" + "确定现在重启吗？", "重启确认", "YesNo", "Warning")
if ($r2 -eq [System.Windows.Forms.DialogResult]::Yes) { Restart-Explorer }
