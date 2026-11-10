# zentao.ps1 - sync markdown requirements to ZenTao (REST API v1)
# Runs on Windows PowerShell 5.1+. Keep this file ASCII-only.
param(
    [Parameter(Position = 0)][string]$Action = 'help',
    [string]$Md,
    [string]$Account,
    [string]$Url,
    [int]$Product = 0,
    [int]$Project = 0,
    [int]$Execution = 0,
    [int]$TaskId = 0,
    [string]$Title,
    [string]$Reviewer,
    [switch]$NoReview,
    [switch]$AcceptRemote,
    [string]$Comment,
    [int]$Pri = 3,
    [string]$Category = 'feature',
    [string]$Name,
    [string]$AssignedTo,
    [string]$Type = 'devel',
    [string]$EstStarted,
    [string]$Deadline,
    [string]$Estimate,
    [string]$Desc,
    [int]$Last = 20
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { }

$Home2 = Join-Path $env:USERPROFILE '.zentao-sync'
$ConfigFile = Join-Path $Home2 'config.json'
$MapFile = Join-Path $Home2 'map.json'
$LogFile = Join-Path $Home2 'sync-log.csv'
$DefaultUrl = ''
$Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$Utf8Bom = New-Object System.Text.UTF8Encoding($true)
$script:Token = ''
$script:Api = ''
$script:CurrentAccount = ''

if (-not (Test-Path $Home2)) { [void](New-Item -ItemType Directory -Path $Home2) }

# ---------- storage ----------
function Read-JsonFile([string]$path) {
    if (-not (Test-Path $path)) { return $null }
    $text = [System.IO.File]::ReadAllText($path, [System.Text.Encoding]::UTF8)
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return (ConvertFrom-Json $text)
}

function Get-Config {
    $c = Read-JsonFile $ConfigFile
    $accounts = @()
    $url = $DefaultUrl
    $current = ''
    if ($null -ne $c) {
        if ($c.url) { $url = [string]$c.url }
        if ($c.current) { $current = [string]$c.current }
        foreach ($a in $c.accounts) { if ($null -ne $a) { $accounts += $a } }
    }
    return @{ url = $url; current = $current; accounts = $accounts }
}

function Save-Config($cfg) {
    $obj = New-Object PSObject -Property @{ url = $cfg.url; current = $cfg.current; accounts = @($cfg.accounts) }
    [System.IO.File]::WriteAllText($ConfigFile, (ConvertTo-Json -InputObject $obj -Depth 6), $Utf8NoBom)
}

function Get-Map {
    $raw = Read-JsonFile $MapFile
    $list = @()
    if ($null -ne $raw) { foreach ($e in $raw) { if ($null -ne $e) { $list += $e } } }
    return , $list
}

function Save-Map($list) {
    $arr = @($list)
    if ($arr.Count -eq 0) { $json = '[]' } else { $json = ConvertTo-Json -InputObject $arr -Depth 8 }
    [System.IO.File]::WriteAllText($MapFile, $json, $Utf8NoBom)
}

function Find-Entry($list, [string]$mdPath) {
    foreach ($e in $list) { if ([string]$e.md -ieq $mdPath) { return $e } }
    return $null
}

# ---------- log ----------
function Csv([string]$s) {
    if ($null -eq $s) { $s = '' }
    return '"' + $s.Replace('"', '""').Replace("`r", ' ').Replace("`n", ' ') + '"'
}

function Write-SyncLog([string]$act, [string]$mdPath, [string]$storyId, [string]$taskId, [string]$result, [string]$detail) {
    $os = ''
    try {
        $o = Get-CimInstance Win32_OperatingSystem
        $os = [string]$o.Caption + ' ' + [string]$o.Version
    } catch { $os = [System.Environment]::OSVersion.VersionString }
    $ip = ''
    try {
        $ip = @([System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
                Where-Object { $_.AddressFamily -eq 'InterNetwork' -and $_.ToString() -ne '127.0.0.1' } |
                ForEach-Object { $_.ToString() }) -join ';'
    } catch { }
    if (-not (Test-Path $LogFile)) {
        $header = 'time,action,zentao_account,windows_user,computer,os,ip,md,story_id,task_id,result,detail' + "`r`n"
        [System.IO.File]::WriteAllText($LogFile, $header, $Utf8Bom)
    }
    $fields = @(
        (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $act, $script:CurrentAccount, $env:USERNAME,
        $env:COMPUTERNAME, $os, $ip, $mdPath, $storyId, $taskId, $result, $detail
    )
    $line = (@($fields | ForEach-Object { Csv ([string]$_) }) -join ',') + "`r`n"
    [System.IO.File]::AppendAllText($LogFile, $line, $Utf8NoBom)
}

# ---------- output ----------
function Out-Result($hash) {
    $obj = New-Object PSObject -Property $hash
    Write-Output (ConvertTo-Json -InputObject $obj -Depth 8)
}

# ---------- http ----------
function Invoke-Zt([string]$Method, [string]$Path, $Body) {
    $p = @{ Uri = ($script:Api + $Path); Method = $Method; UseBasicParsing = $true; TimeoutSec = 60 }
    if ($script:Token) { $p['Headers'] = @{ Token = $script:Token } }
    if ($null -ne $Body) {
        $json = ConvertTo-Json -InputObject $Body -Depth 8 -Compress
        $p['Body'] = [System.Text.Encoding]::UTF8.GetBytes($json)
        $p['ContentType'] = 'application/json; charset=utf-8'
    }
    $text = ''
    try {
        $resp = Invoke-WebRequest @p
        $text = [System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray())
    } catch {
        $msg = $_.Exception.Message
        $bodyText = ''
        try {
            $stream = $_.Exception.Response.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
            $bodyText = $reader.ReadToEnd()
        } catch { }
        throw ('API ' + $Method + ' ' + $Path + ' failed: ' + $msg + ' ' + $bodyText)
    }
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $r = $null
    try { $r = ConvertFrom-Json $text } catch { throw ('API ' + $Method + ' ' + $Path + ' returned non-JSON: ' + $text) }
    if ($null -ne $r -and ($r.PSObject.Properties.Name -contains 'error') -and $r.error) {
        throw ('API ' + $Method + ' ' + $Path + ' error: ' + (ConvertTo-Json -InputObject $r.error -Compress))
    }
    return $r
}

function Get-Plain($secure) {
    $b = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try { return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) }
    finally { [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}

function Connect-Zt {
    $cfg = Get-Config
    if (-not $cfg.url) { throw 'NOT_LOGGED_IN: no zentao url. The user must run: zentao.ps1 login -Account <account> -Url <zentao base url>' }
    $script:Api = $cfg.url.TrimEnd('/') + '/api.php/v1'
    if (-not $cfg.current) { throw 'NOT_LOGGED_IN: no account. The user must run: zentao.ps1 login -Account <account>' }
    $acc = $null
    foreach ($a in $cfg.accounts) { if ([string]$a.account -eq $cfg.current) { $acc = $a } }
    if ($null -eq $acc) { throw ('NOT_LOGGED_IN: account not found: ' + $cfg.current) }
    $script:CurrentAccount = [string]$acc.account
    $plain = Get-Plain (ConvertTo-SecureString ([string]$acc.password))
    $r = Invoke-Zt 'POST' '/tokens' @{ account = $script:CurrentAccount; password = $plain }
    if ($null -eq $r -or -not $r.token) { throw 'LOGIN_FAILED: no token returned' }
    $script:Token = [string]$r.token
}

# ---------- markdown -> html ----------
function Convert-Inline([string]$s) {
    $s = [System.Net.WebUtility]::HtmlEncode($s)
    $s = [regex]::Replace($s, '`([^`]+)`', '<code>$1</code>')
    $s = [regex]::Replace($s, '!\[([^\]]*)\]\(([^)\s]+)[^)]*\)', '<img src="$2" alt="$1" />')
    $s = [regex]::Replace($s, '\[([^\]]+)\]\(([^)\s]+)[^)]*\)', '<a href="$2">$1</a>')
    $s = [regex]::Replace($s, '\*\*(.+?)\*\*', '<strong>$1</strong>')
    $s = [regex]::Replace($s, '~~(.+?)~~', '<del>$1</del>')
    return $s
}

function Close-Blocks($sb, $para, $state) {
    if ($para.Count -gt 0) {
        [void]$sb.Append('<p>' + (@($para.ToArray()) -join '<br />') + '</p>' + "`n")
        $para.Clear()
    }
    if ($state.list -ne '') {
        [void]$sb.Append('</' + $state.list + '>' + "`n")
        $state.list = ''
    }
}

function Convert-MdToHtml([string]$text) {
    $lines = $text -split "`r?`n"
    $sb = New-Object System.Text.StringBuilder
    $para = New-Object System.Collections.ArrayList
    $state = @{ list = '' }
    $inCode = $false
    $fence = '^\s*```'
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = [string]$lines[$i]
        if ($inCode) {
            if ($line -match $fence) { [void]$sb.Append('</code></pre>' + "`n"); $inCode = $false }
            else { [void]$sb.Append([System.Net.WebUtility]::HtmlEncode($line) + "`n") }
            continue
        }
        if ($line -match $fence) {
            Close-Blocks $sb $para $state
            [void]$sb.Append('<pre><code>')
            $inCode = $true
            continue
        }
        if ($line -match '^\s*$') { Close-Blocks $sb $para $state; continue }
        if ($line -match '^(#{1,6})\s+(.*)$') {
            $n = $Matches[1].Length
            $content = $Matches[2].Trim()
            Close-Blocks $sb $para $state
            [void]$sb.Append('<h' + $n + '>' + (Convert-Inline $content) + '</h' + $n + '>' + "`n")
            continue
        }
        if ($line -match '^\s*([-*_])(\s*\1){2,}\s*$') {
            Close-Blocks $sb $para $state
            [void]$sb.Append('<hr />' + "`n")
            continue
        }
        if ($line -match '^\s*\|.*\|\s*$') {
            Close-Blocks $sb $para $state
            $rows = New-Object System.Collections.ArrayList
            while ($i -lt $lines.Count -and ([string]$lines[$i]) -match '^\s*\|.*\|\s*$') {
                [void]$rows.Add([string]$lines[$i])
                $i++
            }
            $i--
            $hasHeader = ($rows.Count -ge 2 -and ([string]$rows[1]) -match '^[\s|:\-]+$' -and ([string]$rows[1]) -match '-')
            [void]$sb.Append('<table border="1" cellspacing="0" cellpadding="4">' + "`n")
            for ($r = 0; $r -lt $rows.Count; $r++) {
                if ($hasHeader -and $r -eq 1) { continue }
                $tag = 'td'
                if ($hasHeader -and $r -eq 0) { $tag = 'th' }
                $cells = ([string]$rows[$r]).Trim().Trim('|').Split('|')
                [void]$sb.Append('<tr>')
                foreach ($c in $cells) {
                    [void]$sb.Append('<' + $tag + '>' + (Convert-Inline $c.Trim()) + '</' + $tag + '>')
                }
                [void]$sb.Append('</tr>' + "`n")
            }
            [void]$sb.Append('</table>' + "`n")
            continue
        }
        if ($line -match '^(\s*)([-*+]|\d+[.)])\s+(.*)$') {
            $indent = $Matches[1].Length
            $marker = $Matches[2]
            $content = $Matches[3]
            $t = 'ul'
            if ($marker -match '^\d') { $t = 'ol' }
            if ($para.Count -gt 0) { Close-Blocks $sb $para $state }
            if ($state.list -ne $t) {
                if ($state.list -ne '') { [void]$sb.Append('</' + $state.list + '>' + "`n") }
                [void]$sb.Append('<' + $t + '>' + "`n")
                $state.list = $t
            }
            $margin = [int]([math]::Floor($indent / 2)) * 20
            if ($margin -gt 0) { [void]$sb.Append('<li style="margin-left:' + $margin + 'px">') }
            else { [void]$sb.Append('<li>') }
            [void]$sb.Append((Convert-Inline $content) + '</li>' + "`n")
            continue
        }
        if ($line -match '^\s*>\s?(.*)$') {
            $content = $Matches[1]
            Close-Blocks $sb $para $state
            [void]$sb.Append('<blockquote>' + (Convert-Inline $content) + '</blockquote>' + "`n")
            continue
        }
        if ($state.list -ne '') { Close-Blocks $sb $para $state }
        [void]$para.Add((Convert-Inline $line.Trim()))
    }
    if ($inCode) { [void]$sb.Append('</code></pre>' + "`n") }
    Close-Blocks $sb $para $state
    return $sb.ToString()
}

# ---------- helpers ----------
function Resolve-Md {
    if (-not $Md) { throw 'MISSING_PARAM: -Md <path to .md> is required' }
    if (-not (Test-Path $Md)) { throw ('MD_NOT_FOUND: ' + $Md) }
    return (Resolve-Path $Md).Path
}

function Get-FileHash256([string]$path) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.IO.File]::ReadAllBytes($path)
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLower()
    } finally { $sha.Dispose() }
}

function Get-MdTitle([string]$text, [string]$path) {
    if ($Title) { return $Title }
    foreach ($l in ($text -split "`r?`n")) {
        if ($l -match '^#\s+(.+)$') { return $Matches[1].Trim() }
    }
    return [System.IO.Path]::GetFileNameWithoutExtension($path)
}

function Split-List([string]$s) {
    $out = @()
    if ($s) { foreach ($x in $s.Split(',')) { if ($x.Trim()) { $out += $x.Trim() } } }
    return , $out
}

function Get-TaskList($entry) {
    $tasks = @()
    if ($null -ne $entry -and $null -ne $entry.tasks) { foreach ($t in $entry.tasks) { if ($null -ne $t) { $tasks += $t } } }
    return , $tasks
}

# ---------- actions ----------
function U([int[]]$codes) { return (-join ($codes | ForEach-Object { [char]$_ })) }

function Show-LoginDialog([string]$u, [string]$a, [string]$errText) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $f = New-Object System.Windows.Forms.Form
    $f.Text = (U 0x7985, 0x9053, 0x767B, 0x5F55)
    $f.ClientSize = New-Object System.Drawing.Size(420, 215)
    $f.StartPosition = 'CenterScreen'
    $f.FormBorderStyle = 'FixedDialog'
    $f.MaximizeBox = $false
    $f.MinimizeBox = $false
    $f.TopMost = $true
    $labels = @((U 0x7985, 0x9053, 0x5730, 0x5740), (U 0x8D26, 0x53F7), (U 0x5BC6, 0x7801))
    $boxes = @()
    for ($k = 0; $k -lt 3; $k++) {
        $l = New-Object System.Windows.Forms.Label
        $l.Text = $labels[$k]
        $l.Location = New-Object System.Drawing.Point(20, (23 + 40 * $k))
        $l.Size = New-Object System.Drawing.Size(80, 20)
        $f.Controls.Add($l)
        $t = New-Object System.Windows.Forms.TextBox
        $t.Location = New-Object System.Drawing.Point(105, (20 + 40 * $k))
        $t.Size = New-Object System.Drawing.Size(290, 24)
        $f.Controls.Add($t)
        $boxes += $t
    }
    $boxes[0].Text = $u
    $boxes[1].Text = $a
    $boxes[2].UseSystemPasswordChar = $true
    $e = New-Object System.Windows.Forms.Label
    $e.Text = $errText
    $e.ForeColor = [System.Drawing.Color]::Red
    $e.Location = New-Object System.Drawing.Point(20, 135)
    $e.Size = New-Object System.Drawing.Size(380, 34)
    $f.Controls.Add($e)
    $ok = New-Object System.Windows.Forms.Button
    $ok.Text = (U 0x767B, 0x5F55)
    $ok.Location = New-Object System.Drawing.Point(215, 175)
    $ok.Size = New-Object System.Drawing.Size(85, 28)
    $ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
    $f.Controls.Add($ok)
    $cancel = New-Object System.Windows.Forms.Button
    $cancel.Text = (U 0x53D6, 0x6D88)
    $cancel.Location = New-Object System.Drawing.Point(310, 175)
    $cancel.Size = New-Object System.Drawing.Size(85, 28)
    $cancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
    $f.Controls.Add($cancel)
    $f.AcceptButton = $ok
    $f.CancelButton = $cancel
    $focus = $boxes[2]
    if (-not $u) { $focus = $boxes[0] } elseif (-not $a) { $focus = $boxes[1] }
    $f.Add_Shown({ $f.Activate(); [void]$focus.Focus() })
    $res = $f.ShowDialog()
    $out = $null
    if ($res -eq [System.Windows.Forms.DialogResult]::OK) {
        $out = @{ url = $boxes[0].Text.Trim(); account = $boxes[1].Text.Trim(); password = $boxes[2].Text }
    }
    $f.Dispose()
    return $out
}

function Do-Login {
    # Opens a login window. The password is typed there, never passed on the command line.
    $cfg = Get-Config
    if ($Url) { $cfg.url = $Url }
    $acc = $Account
    if (-not $acc) { $acc = $cfg.current }
    $errText = ''
    $secure = $null
    while ($true) {
        $d = Show-LoginDialog $cfg.url $acc $errText
        if ($null -eq $d) { Out-Result @{ result = 'CANCELLED'; message = 'user closed the login window' }; return }
        $cfg.url = $d.url
        $acc = $d.account
        if (-not $d.url -or -not $d.account -or -not $d.password) { $errText = 'URL / account / password required'; continue }
        $script:Api = $cfg.url.TrimEnd('/') + '/api.php/v1'
        $script:CurrentAccount = $acc
        $script:Token = ''
        try {
            $r = Invoke-Zt 'POST' '/tokens' @{ account = $acc; password = $d.password }
            if ($null -eq $r -or -not $r.token) { throw 'no token returned' }
        } catch {
            $errText = [string]$_.Exception.Message
            if ($errText.Length -gt 110) { $errText = $errText.Substring(0, 110) }
            continue
        }
        $secure = ConvertTo-SecureString $d.password -AsPlainText -Force
        break
    }
    $Account = $acc
    $others = @()
    foreach ($a in $cfg.accounts) { if ([string]$a.account -ne $Account) { $others += $a } }
    $others += (New-Object PSObject -Property @{ account = $Account; password = (ConvertFrom-SecureString $secure) })
    $cfg.accounts = $others
    $cfg.current = $Account
    Save-Config $cfg
    Write-SyncLog 'login' '' '' '' 'OK' $cfg.url
    Out-Result @{ result = 'OK'; current = $Account; url = $cfg.url }
}

function Do-Use {
    if (-not $Account) { throw 'MISSING_PARAM: -Account is required' }
    $cfg = Get-Config
    $found = $false
    foreach ($a in $cfg.accounts) { if ([string]$a.account -eq $Account) { $found = $true } }
    if (-not $found) { throw ('NOT_LOGGED_IN: account not saved yet. The user must run: zentao.ps1 login -Account ' + $Account) }
    $cfg.current = $Account
    Save-Config $cfg
    $script:CurrentAccount = $Account
    Write-SyncLog 'switch-account' '' '' '' 'OK' ''
    Out-Result @{ result = 'OK'; current = $Account }
}

function Do-Accounts {
    $cfg = Get-Config
    $names = @()
    foreach ($a in $cfg.accounts) { $names += [string]$a.account }
    Out-Result @{ result = 'OK'; current = $cfg.current; accounts = $names; url = $cfg.url }
}

function Do-Sync {
    $mdPath = Resolve-Md
    $text = [System.IO.File]::ReadAllText($mdPath, [System.Text.Encoding]::UTF8)
    $hash = Get-FileHash256 $mdPath
    $list = Get-Map
    $entry = Find-Entry $list $mdPath
    Connect-Zt
    $reviewers = Split-List $Reviewer

    if ($null -eq $entry) {
        if ($Product -le 0) { throw 'NEED_PRODUCT: new story needs -Product <id>. Run "products" and ask the user which product.' }
        $t = Get-MdTitle $text $mdPath
        $body = @{ title = $t; product = $Product; pri = $Pri; category = $Category; spec = (Convert-MdToHtml $text) }
        if ($reviewers.Count -gt 0) { $body['reviewer'] = $reviewers }
        elseif ($NoReview) { $body['needNotReview'] = 1 }
        if ($AssignedTo) { $body['assignedTo'] = $AssignedTo }
        $r = Invoke-Zt 'POST' '/stories' $body
        $sid = [int]$r.id
        if ($sid -le 0) { throw ('CREATE_FAILED: no story id returned: ' + (ConvertTo-Json -InputObject $r -Compress -Depth 4)) }
        $s = Invoke-Zt 'GET' ('/stories/' + $sid) $null
        $new = New-Object PSObject -Property @{
            md = $mdPath; storyId = $sid; product = $Product; title = $t; hash = $hash
            version = [int]$s.version; account = $script:CurrentAccount
            updated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); tasks = @()
        }
        $list += $new
        Save-Map $list
        Write-SyncLog 'story-create' $mdPath ([string]$sid) '' 'OK' $t
        Out-Result @{ result = 'CREATED'; storyId = $sid; title = $t; status = [string]$s.status; version = [int]$s.version }
        return
    }

    $sid = [int]$entry.storyId
    $s = Invoke-Zt 'GET' ('/stories/' + $sid) $null
    $remoteVersion = [int]$s.version

    if ($remoteVersion -ne [int]$entry.version) {
        if ($AcceptRemote) {
            $entry.hash = $hash
            $entry.version = $remoteVersion
            $entry.title = [string]$s.title
            $entry.updated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            Save-Map $list
            Write-SyncLog 'pull-accept' $mdPath ([string]$sid) '' 'OK' ('local md overwritten with zentao v' + $remoteVersion)
            Out-Result @{ result = 'REMOTE_ACCEPTED'; storyId = $sid; version = $remoteVersion; tasks = (Get-TaskList $entry) }
            return
        }
        $htmlPath = $mdPath + '.zentao.html'
        $html = '<h1>' + [System.Net.WebUtility]::HtmlEncode([string]$s.title) + '</h1>' + "`n" + [string]$s.spec
        if ($s.verify) { $html = $html + "`n" + '<h2>verify</h2>' + "`n" + [string]$s.verify }
        [System.IO.File]::WriteAllText($htmlPath, $html, $Utf8NoBom)
        Write-SyncLog 'pull' $mdPath ([string]$sid) '' 'REMOTE_CHANGED' ('zentao v' + $remoteVersion + ' local v' + [int]$entry.version)
        Out-Result @{
            result = 'REMOTE_CHANGED'; storyId = $sid; remoteVersion = $remoteVersion; localVersion = [int]$entry.version
            remoteTitle = [string]$s.title; htmlFile = $htmlPath
            next = 'Overwrite the md with the content of htmlFile (convert HTML to markdown), delete htmlFile, then run: sync -Md <md> -AcceptRemote'
        }
        return
    }

    if ($AcceptRemote) {
        Out-Result @{ result = 'NO_REMOTE_CHANGE'; storyId = $sid; version = $remoteVersion }
        return
    }

    $t = Get-MdTitle $text $mdPath
    if ($hash -eq [string]$entry.hash -and $t -eq [string]$entry.title) {
        Out-Result @{ result = 'NO_CHANGE'; storyId = $sid; version = $remoteVersion; status = [string]$s.status }
        return
    }
    if ($reviewers.Count -eq 0 -and -not $NoReview) {
        Out-Result @{
            result = 'NEED_REVIEWER'; storyId = $sid
            next = 'Ask the user who reviews this change, then rerun with -Reviewer acc1,acc2 (or -NoReview only if the user says no review).'
        }
        return
    }
    $body = @{ title = $t; spec = (Convert-MdToHtml $text) }
    if ($reviewers.Count -gt 0) { $body['reviewer'] = $reviewers } else { $body['needNotReview'] = 1 }
    if ($Comment) { $body['comment'] = $Comment }
    [void](Invoke-Zt 'POST' ('/stories/' + $sid + '/change') $body)
    $s2 = Invoke-Zt 'GET' ('/stories/' + $sid) $null
    $entry.hash = $hash
    $entry.title = $t
    $entry.version = [int]$s2.version
    $entry.updated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Save-Map $list
    Write-SyncLog 'story-change' $mdPath ([string]$sid) '' 'OK' ('v' + $remoteVersion + ' -> v' + [int]$s2.version + ' reviewer=' + $Reviewer)
    Out-Result @{
        result = 'CHANGED'; storyId = $sid; version = [int]$s2.version; status = [string]$s2.status
        tasks = (Get-TaskList $entry)
        next = 'If tasks is not empty, update each affected task with task-update.'
    }
}

function Do-Status {
    $mdPath = Resolve-Md
    $list = Get-Map
    $entry = Find-Entry $list $mdPath
    if ($null -eq $entry) { Out-Result @{ result = 'NOT_SYNCED'; md = $mdPath }; return }
    Connect-Zt
    $s = Invoke-Zt 'GET' ('/stories/' + [int]$entry.storyId) $null
    Out-Result @{
        result = 'OK'; storyId = [int]$entry.storyId; title = [string]$s.title; status = [string]$s.status
        remoteVersion = [int]$s.version; localVersion = [int]$entry.version
        localChanged = ((Get-FileHash256 $mdPath) -ne [string]$entry.hash)
        remoteChanged = ([int]$s.version -ne [int]$entry.version)
        tasks = (Get-TaskList $entry)
    }
}

function Do-TaskAdd {
    $mdPath = Resolve-Md
    if ($Execution -le 0) { throw 'NEED_EXECUTION: -Execution <id> is required. Run "executions" and ask the user which one.' }
    if (-not $Name) { throw 'MISSING_PARAM: -Name is required' }
    $list = Get-Map
    $entry = Find-Entry $list $mdPath
    if ($null -eq $entry) { throw 'NOT_SYNCED: run sync for this md first' }
    Connect-Zt
    $body = @{ name = $Name; type = $Type; story = [int]$entry.storyId; pri = $Pri }
    if ($AssignedTo) { $body['assignedTo'] = $AssignedTo } else { $body['assignedTo'] = '' }
    if ($EstStarted) { $body['estStarted'] = $EstStarted }
    if ($Deadline) { $body['deadline'] = $Deadline }
    if ($Estimate) { $body['estimate'] = [double]$Estimate }
    if ($Desc) { $body['desc'] = (Convert-MdToHtml $Desc) }
    $r = Invoke-Zt 'POST' ('/executions/' + $Execution + '/tasks') $body
    $tid = [int]$r.id
    if ($tid -le 0) { throw ('CREATE_FAILED: no task id returned: ' + (ConvertTo-Json -InputObject $r -Compress -Depth 4)) }
    $tasks = Get-TaskList $entry
    $tasks += (New-Object PSObject -Property @{ id = $tid; name = $Name; execution = $Execution; assignedTo = [string]$AssignedTo })
    if ($entry.PSObject.Properties.Name -contains 'tasks') { $entry.tasks = $tasks }
    else { $entry | Add-Member -NotePropertyName tasks -NotePropertyValue $tasks }
    Save-Map $list
    Write-SyncLog 'task-create' $mdPath ([string]$entry.storyId) ([string]$tid) 'OK' ($Name + ' execution=' + $Execution + ' assignedTo=' + $AssignedTo)
    Out-Result @{ result = 'TASK_CREATED'; taskId = $tid; storyId = [int]$entry.storyId; execution = $Execution }
}

function Do-TaskUpdate {
    if ($TaskId -le 0) { throw 'MISSING_PARAM: -TaskId is required' }
    Connect-Zt
    $body = @{}
    if ($Name) { $body['name'] = $Name }
    if ($AssignedTo) { $body['assignedTo'] = $AssignedTo }
    if ($EstStarted) { $body['estStarted'] = $EstStarted }
    if ($Deadline) { $body['deadline'] = $Deadline }
    if ($Estimate) { $body['estimate'] = [double]$Estimate }
    if ($Desc) { $body['desc'] = (Convert-MdToHtml $Desc) }
    if ($body.Count -eq 0) { throw 'MISSING_PARAM: nothing to update' }
    [void](Invoke-Zt 'PUT' ('/tasks/' + $TaskId) $body)
    $list = Get-Map
    $mdPath = ''
    $sid = ''
    foreach ($e in $list) {
        foreach ($t in (Get-TaskList $e)) {
            if ([int]$t.id -eq $TaskId) {
                $mdPath = [string]$e.md
                $sid = [string]$e.storyId
                if ($Name) { $t.name = $Name }
                if ($AssignedTo) { $t.assignedTo = $AssignedTo }
            }
        }
    }
    Save-Map $list
    $changed = @($body.Keys) -join '/'
    Write-SyncLog 'task-update' $mdPath $sid ([string]$TaskId) 'OK' ('fields=' + $changed)
    Out-Result @{ result = 'TASK_UPDATED'; taskId = $TaskId; fields = $changed }
}

function Do-List([string]$path, [string]$key) {
    Connect-Zt
    $r = Invoke-Zt 'GET' $path $null
    $items = @()
    foreach ($x in $r.$key) {
        if ($null -eq $x) { continue }
        $h = @{ id = $x.id }
        if ($x.PSObject.Properties.Name -contains 'name') { $h['name'] = [string]$x.name }
        if ($x.PSObject.Properties.Name -contains 'account') { $h['account'] = [string]$x.account }
        if ($x.PSObject.Properties.Name -contains 'realname') { $h['realname'] = [string]$x.realname }
        if ($x.PSObject.Properties.Name -contains 'status') { $h['status'] = [string]$x.status }
        $items += (New-Object PSObject -Property $h)
    }
    Out-Result @{ result = 'OK'; items = $items }
}

function Do-Log {
    if (-not (Test-Path $LogFile)) { Out-Result @{ result = 'OK'; file = $LogFile; lines = @() }; return }
    $lines = @([System.IO.File]::ReadAllLines($LogFile, [System.Text.Encoding]::UTF8))
    $n = [math]::Min($Last, [math]::Max($lines.Count - 1, 0))
    $tail = @()
    if ($n -gt 0) { $tail = $lines[($lines.Count - $n)..($lines.Count - 1)] }
    Out-Result @{ result = 'OK'; file = $LogFile; header = $lines[0]; lines = $tail }
}

# ---------- main ----------
try {
    switch ($Action.ToLower()) {
        'login' { Do-Login }
        'use' { Do-Use }
        'accounts' { Do-Accounts }
        'test' {
            Connect-Zt
            $u = Invoke-Zt 'GET' '/user' $null
            Out-Result @{ result = 'OK'; account = $script:CurrentAccount; api = $script:Api; profile = $u.profile }
        }
        'products' { Do-List '/products?limit=500' 'products' }
        'executions' {
            if ($Project -gt 0) { Do-List ('/projects/' + $Project + '/executions?limit=500') 'executions' }
            else { Do-List '/executions?limit=500' 'executions' }
        }
        'projects' { Do-List '/projects?limit=500' 'projects' }
        'users' { Do-List '/users?limit=1000' 'users' }
        'sync' { Do-Sync }
        'status' { Do-Status }
        'task-add' { Do-TaskAdd }
        'task-update' { Do-TaskUpdate }
        'log' { Do-Log }
        default {
            Out-Result @{
                result = 'HELP'
                actions = 'login use accounts test products projects executions users sync status task-add task-update log'
                data = $Home2
            }
        }
    }
} catch {
    $m = [string]$_.Exception.Message
    try { Write-SyncLog $Action ([string]$Md) '' ([string]$TaskId) 'ERROR' $m } catch { }
    Out-Result @{ result = 'ERROR'; message = $m }
    exit 1
}
