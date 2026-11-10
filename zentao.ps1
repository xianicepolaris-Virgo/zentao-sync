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
    [switch]$Recreate,
    [string]$Comment,
    [int]$Pri = 3,
    [string]$Category = 'feature',
    [string]$Source,
    [string]$Extra,
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
$script:Plain = ''
$script:LinkNote = ''
$script:WebSess = $null
$script:WebLoginText = ''
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
    $source = ''
    if ($null -ne $c) {
        if ($c.PSObject.Properties.Name -contains 'source' -and $c.source) { $source = [string]$c.source }
        if ($c.url) { $url = [string]$c.url }
        if ($c.current) { $current = [string]$c.current }
        foreach ($a in $c.accounts) { if ($null -ne $a) { $accounts += $a } }
    }
    return @{ url = $url; current = $current; accounts = $accounts; source = $source }
}

function Save-Config($cfg) {
    $obj = New-Object PSObject -Property @{ url = $cfg.url; current = $cfg.current; accounts = @($cfg.accounts); source = [string]$cfg.source }
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
    # add clickable ZenTao page links for whatever ids are in the result
    if ($script:Api) {
        $base = $script:Api -replace '/api\.php/v1$', ''
        if ($hash.ContainsKey('storyId') -and [int]$hash['storyId'] -gt 0) { $hash['storyUrl'] = $base + '/story-view-' + [int]$hash['storyId'] + '.html' }
        if ($hash.ContainsKey('taskId') -and [int]$hash['taskId'] -gt 0) { $hash['taskUrl'] = $base + '/task-view-' + [int]$hash['taskId'] + '.html' }
        if ($hash.ContainsKey('project') -and [int]$hash['project'] -gt 0) { $hash['projectStoryUrl'] = $base + '/projectstory-story-' + [int]$hash['project'] + '.html' }
        if ($hash.ContainsKey('execution') -and [int]$hash['execution'] -gt 0) { $hash['executionTaskUrl'] = $base + '/execution-task-' + [int]$hash['execution'] + '.html' }
    }
    if ($script:LinkNote -and -not $hash.ContainsKey('projectLink')) { $hash['projectLink'] = $script:LinkNote }
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
        $err0 = $_
        $msg = $err0.Exception.Message
        $bodyText = ''
        try {
            $stream = $err0.Exception.Response.GetResponseStream()
            if ($stream.CanSeek) { $stream.Position = 0 }
            $reader = New-Object System.IO.StreamReader($stream, [System.Text.Encoding]::UTF8)
            $bodyText = $reader.ReadToEnd()
        } catch { }
        if (-not $bodyText) {
            try { if ($err0.ErrorDetails -and $err0.ErrorDetails.Message) { $bodyText = [string]$err0.ErrorDetails.Message } } catch { }
        }
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
    $script:Plain = $plain
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

function Get-StoryOrNull([int]$sid) {
    # returns $null when the story was deleted in ZenTao (404, or deleted flag set)
    $st = $null
    try { $st = Invoke-Zt 'GET' ('/stories/' + $sid) $null }
    catch {
        $m = [string]$_.Exception.Message
        if ($m -match '\(404\)' -or $m -match '(?i)not found') { return $null }
        throw
    }
    if ($null -eq $st) { return $null }
    if ($st.PSObject.Properties.Name -contains 'deleted') {
        $del = [string]$st.deleted
        if ($del -eq '1' -or $del -eq 'True') { return $null }
    }
    return $st
}

function Set-Prop($obj, [string]$name, $value) {
    if ($obj.PSObject.Properties.Name -contains $name) { $obj.$name = $value }
    else { $obj | Add-Member -NotePropertyName $name -NotePropertyValue $value }
}

function Get-PendingProject($entry) {
    if ($null -ne $entry -and ($entry.PSObject.Properties.Name -contains 'pendingProject') -and $entry.pendingProject) { return [int]$entry.pendingProject }
    return 0
}

function Get-EntryProject($entry) {
    if ($null -ne $entry -and ($entry.PSObject.Properties.Name -contains 'project') -and $entry.project) { return [int]$entry.project }
    return 0
}

function Get-TaskList($entry) {
    $tasks = @()
    if ($null -ne $entry -and $null -ne $entry.tasks) { foreach ($t in $entry.tasks) { if ($null -ne $t) { $tasks += $t } } }
    return , $tasks
}

function Add-Extra($body) {
    # -Extra "key=value;key2=value2" adds any extra API fields (for site-specific required fields)
    if (-not $Extra) { return }
    foreach ($pair in $Extra.Split(';')) {
        $idx = $pair.IndexOf('=')
        if ($idx -le 0) { continue }
        $k = $pair.Substring(0, $idx).Trim()
        $v = $pair.Substring($idx + 1).Trim()
        if ($v -match '^\d+$') { $body[$k] = [int]$v } else { $body[$k] = $v }
    }
}

function Get-Short([string]$t, [int]$n) {
    if ($null -eq $t) { return '' }
    if ($t.Length -gt $n) { return $t.Substring(0, $n) }
    return $t
}

function Get-WebSession {
    # The REST token is not a web session. Some actions have no REST endpoint, so log in to the
    # web side once per run with the saved account (in memory only) and reuse that session.
    if ($null -ne $script:WebSess) { return $script:WebSess }
    $base = $script:Api -replace '/api\.php/v1$', ''
    $sess = New-Object Microsoft.PowerShell.Commands.WebRequestSession
    $u = [System.Uri]$base
    $r1 = Invoke-WebRequest -Uri ($base + '/index.php?m=api&f=getSessionID&t=json') -WebSession $sess -UseBasicParsing -TimeoutSec 60
    try {
        $j1 = ConvertFrom-Json ([string]$r1.Content)
        $d1 = $j1.data
        if ($d1 -is [string]) { $d1 = ConvertFrom-Json $d1 }
        if ($d1.sessionName -and $d1.sessionID) {
            $sess.Cookies.Add((New-Object System.Net.Cookie([string]$d1.sessionName, [string]$d1.sessionID, '/', $u.Host)))
        }
    } catch { }
    $loginBody = 'account=' + [System.Uri]::EscapeDataString($script:CurrentAccount) + '&password=' + [System.Uri]::EscapeDataString($script:Plain) + '&keepLogin=0'
    $r2 = Invoke-WebRequest -Uri ($base + '/index.php?m=user&f=login&t=json') -Method POST -Body $loginBody `
        -ContentType 'application/x-www-form-urlencoded' -Headers @{ 'X-Requested-With' = 'XMLHttpRequest' } -WebSession $sess -UseBasicParsing -TimeoutSec 60
    $script:WebLoginText = [string]$r2.Content
    $script:WebSess = $sess
    return $sess
}

function Invoke-WebForm([string]$query, [string]$form) {
    $base = $script:Api -replace '/api\.php/v1$', ''
    $sess = Get-WebSession
    $resp = Invoke-WebRequest -Uri ($base + '/index.php?' + $query + '&t=json') -Method POST -Body $form `
        -ContentType 'application/x-www-form-urlencoded' -Headers @{ 'X-Requested-With' = 'XMLHttpRequest' } -WebSession $sess -UseBasicParsing -TimeoutSec 60
    return [string]$resp.Content
}

function Submit-StoryReview([int]$sid, $reviewers) {
    # A story created through REST v1 stays in draft. Submit it the way the web page does:
    # with reviewers -> reviewing; without -> "no review needed" -> active.
    $form = 'needNotReview=1'
    if ($reviewers.Count -gt 0) {
        $form = (@($reviewers | ForEach-Object { 'reviewer%5B%5D=' + [System.Uri]::EscapeDataString([string]$_) }) -join '&')
    }
    try { return (Get-Short (Invoke-WebForm ('m=story&f=submitReview&storyID=' + $sid + '&storyType=story') $form) 200) }
    catch { return [string]$_.Exception.Message }
}

function Test-StoryInProject([int]$sid, [int]$projId) {
    try {
        $r = Invoke-Zt 'GET' ('/projects/' + $projId + '/stories?limit=2000') $null
        foreach ($x in $r.stories) { if ($null -ne $x -and [int]$x.id -eq $sid) { return $true } }
    } catch { }
    return $false
}

function Connect-StoryToProject([int]$sid, [int]$projId, [int]$prod) {
    # REST v1 has no "link story to project" endpoint, so post the same form the web page uses,
    # then verify through the API. Returns 'LINKED' or 'LINK_FAILED: reason'.
    if (Test-StoryInProject $sid $projId) { return 'LINKED' }
    $base = $script:Api -replace '/api\.php/v1$', ''
    $form = 'stories%5B%5D=' + $sid + '&products%5B' + $sid + '%5D=' + $prod
    $why = ''
    try {
        $t = Invoke-WebForm ('m=projectstory&f=linkStory&projectID=' + $projId) $form
        $why = 'link=' + (Get-Short $t 200) + ' | login=' + (Get-Short $script:WebLoginText 150)
    } catch { $why = [string]$_.Exception.Message }
    if (Test-StoryInProject $sid $projId) { return 'LINKED' }
    return ('LINK_FAILED: ' + $why)
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
        # normalize: add http://, drop page names like /my.html, then also try with /zentao
        $nu = [string]$d.url
        if ($nu -notmatch '^https?://') { $nu = 'http://' + $nu }
        $nu = [regex]::Replace($nu, '/[^/]*\.(html|php).*$', '')
        $nu = $nu.TrimEnd('/')
        $candidates = @($nu)
        if ($nu -notmatch '/zentao$') { $candidates += ($nu + '/zentao') }
        $script:CurrentAccount = $acc
        $script:Token = ''
        $okUrl = ''
        foreach ($cand in $candidates) {
            $script:Api = $cand + '/api.php/v1'
            try {
                $r = Invoke-Zt 'POST' '/tokens' @{ account = $acc; password = $d.password }
                if ($null -eq $r -or -not $r.token) { throw 'no token returned' }
                $okUrl = $cand
                break
            } catch {
                $errText = [string]$_.Exception.Message
                if ($errText.Length -gt 110) { $errText = $errText.Substring(0, 110) }
            }
        }
        if (-not $okUrl) { $cfg.url = $nu; continue }
        $cfg.url = $okUrl
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
    $recreatedFrom = 0
    $oldTasks = @()

    if ($null -ne $entry) {
        $oldId = [int]$entry.storyId
        if ($null -eq (Get-StoryOrNull $oldId)) {
            # the story was deleted in ZenTao
            # drop the old mapping and publish the md again as a new story (same product / project)
            $recreatedFrom = $oldId
            $oldTasks = Get-TaskList $entry
            if ($Product -le 0) { $Product = [int]$entry.product }
            if ($Project -le 0) { $Project = Get-EntryProject $entry }
            $list = @($list | Where-Object { [string]$_.md -ine $mdPath })
            Save-Map $list
            Write-SyncLog 'story-recreate' $mdPath ([string]$oldId) '' 'OK' 'story was deleted in zentao: old mapping dropped, creating a new story'
            $entry = $null
        }
    }

    if ($null -eq $entry) {
        if ($Product -le 0) { throw 'NEED_PRODUCT: new story needs -Product <id>. Run "products" and ask the user which product.' }
        $t = Get-MdTitle $text $mdPath
        $body = @{ title = $t; product = $Product; pri = $Pri; category = $Category; spec = (Convert-MdToHtml $text) }
        if ($reviewers.Count -gt 0) { $body['reviewer'] = $reviewers }
        else { $body['needNotReview'] = 1 }
        if ($AssignedTo) { $body['assignedTo'] = $AssignedTo }
        # source: use -Source if given and remember it; otherwise reuse the remembered one
        $src = $Source
        $cfg2 = Get-Config
        if ($src) { if ($src -ne $cfg2.source) { $cfg2.source = $src; Save-Config $cfg2 } }
        else { $src = $cfg2.source }
        if ($src) { $body['source'] = $src }
        Add-Extra $body
        $r = Invoke-Zt 'POST' '/stories' $body
        $sid = [int]$r.id
        if ($sid -le 0) { throw ('CREATE_FAILED: no story id returned: ' + (ConvertTo-Json -InputObject $r -Compress -Depth 4)) }
        $s = Invoke-Zt 'GET' ('/stories/' + $sid) $null
        $reviewNote = ''
        if ([string]$s.status -eq 'draft') {
            $submitText = Submit-StoryReview $sid $reviewers
            $s = Invoke-Zt 'GET' ('/stories/' + $sid) $null
            if ([string]$s.status -eq 'draft') { $reviewNote = 'SUBMIT_FAILED: story is still draft. ' + $submitText }
            elseif ($reviewers.Count -gt 0) { $reviewNote = 'SUBMITTED_FOR_REVIEW: ' + $Reviewer }
            else { $reviewNote = 'NO_REVIEW: activated without review' }
            Write-SyncLog 'story-submit-review' $mdPath ([string]$sid) '' $reviewNote ''
        }
        $new = New-Object PSObject -Property @{
            md = $mdPath; storyId = $sid; product = $Product; title = $t; hash = $hash
            version = [int]$s.version; account = $script:CurrentAccount
            updated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); tasks = @(); project = $Project
        }
        $list += $new
        Save-Map $list
        Write-SyncLog 'story-create' $mdPath ([string]$sid) '' 'OK' $t
        $link = ''
        if ($Project -gt 0) {
            $link = Connect-StoryToProject $sid $Project $Product
            if ($link -ne 'LINKED' -and ([string]$s.status -eq 'reviewing' -or [string]$s.status -eq 'draft')) {
                # ZenTao only lets reviewed (active) stories be linked to a project: retry automatically later
                $link = 'LINK_PENDING_REVIEW: story status is ' + [string]$s.status + '; it will be linked to project ' + $Project + ' on the next sync after the review passes'
                $new.project = 0
                Set-Prop $new 'pendingProject' $Project
                Save-Map $list
            }
            Write-SyncLog 'story-link-project' $mdPath ([string]$sid) '' $link ('project=' + $Project)
        }
        $res = 'CREATED'
        if ($recreatedFrom -gt 0) { $res = 'RECREATED' }
        Out-Result @{ result = $res; recreatedFrom = $recreatedFrom; oldTasks = $oldTasks; storyId = $sid; title = $t; status = [string]$s.status; version = [int]$s.version; project = $Project; projectLink = $link; reviewNote = $reviewNote }
        return
    }

    $sid = [int]$entry.storyId
    $s = Invoke-Zt 'GET' ('/stories/' + $sid) $null
    $remoteVersion = [int]$s.version

    $pp = Get-PendingProject $entry
    if ($pp -gt 0) {
        if ([string]$s.status -eq 'active') {
            $lk = Connect-StoryToProject $sid $pp ([int]$entry.product)
            if ($lk -eq 'LINKED') {
                Set-Prop $entry 'project' $pp
                Set-Prop $entry 'pendingProject' 0
                Save-Map $list
            }
            $script:LinkNote = $lk
            Write-SyncLog 'story-link-project' $mdPath ([string]$sid) '' $lk ('project=' + $pp)
        } else {
            $script:LinkNote = 'LINK_PENDING_REVIEW: story status is ' + [string]$s.status + '; project ' + $pp + ' not linked yet'
        }
    }

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
        Out-Result @{ result = 'NO_CHANGE'; storyId = $sid; version = $remoteVersion; status = [string]$s.status; project = (Get-EntryProject $entry) }
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
    Add-Extra $body
    [void](Invoke-Zt 'POST' ('/stories/' + $sid + '/change') $body)
    $s2 = Invoke-Zt 'GET' ('/stories/' + $sid) $null
    $entry.hash = $hash
    $entry.title = $t
    $entry.version = [int]$s2.version
    $entry.updated = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    Save-Map $list
    Write-SyncLog 'story-change' $mdPath ([string]$sid) '' 'OK' ('v' + $remoteVersion + ' -> v' + [int]$s2.version + ' reviewer=' + $Reviewer)
    Out-Result @{
        result = 'CHANGED'; storyId = $sid; version = [int]$s2.version; status = [string]$s2.status; project = (Get-EntryProject $entry)
        tasks = (Get-TaskList $entry)
        next = 'If tasks is not empty, update each affected task with task-update.'
    }
}

function Do-LinkProject {
    $mdPath = Resolve-Md
    if ($Project -le 0) { throw 'MISSING_PARAM: -Project <project id> is required' }
    $list = Get-Map
    $entry = Find-Entry $list $mdPath
    if ($null -eq $entry) { throw 'NOT_SYNCED: run sync for this md first' }
    Connect-Zt
    $st = Get-StoryOrNull ([int]$entry.storyId)
    if ($null -eq $st) { Out-Result @{ result = 'REMOTE_DELETED'; oldStoryId = [int]$entry.storyId }; return }
    $link = Connect-StoryToProject ([int]$entry.storyId) $Project ([int]$entry.product)
    if ($link -eq 'LINKED') {
        Set-Prop $entry 'project' $Project
        Set-Prop $entry 'pendingProject' 0
        Save-Map $list
    } elseif ([string]$st.status -eq 'reviewing' -or [string]$st.status -eq 'draft') {
        $link = 'LINK_PENDING_REVIEW: story status is ' + [string]$st.status + '; it will be linked to project ' + $Project + ' on the next sync after the review passes'
        Set-Prop $entry 'pendingProject' $Project
        Save-Map $list
    }
    Write-SyncLog 'story-link-project' $mdPath ([string]$entry.storyId) '' $link ('project=' + $Project)
    Out-Result @{ result = $link; storyId = [int]$entry.storyId; project = $Project; status = [string]$st.status }
}

function Do-CheckDeleted {
    # scan every synced md and report the ones whose story no longer exists in ZenTao
    $list = Get-Map
    Connect-Zt
    $gone = @()
    $alive = 0
    foreach ($e in $list) {
        if ($null -eq (Get-StoryOrNull ([int]$e.storyId))) {
            $gone += (New-Object PSObject -Property @{ md = [string]$e.md; oldStoryId = [int]$e.storyId; title = [string]$e.title })
            Write-SyncLog 'story-deleted-detected' ([string]$e.md) ([string]$e.storyId) '' 'REMOTE_DELETED' ''
        } else { $alive++ }
    }
    Out-Result @{ result = 'OK'; deleted = $gone; aliveCount = $alive; next = 'Run sync on each deleted md to publish it again as a new story.' }
}

function Do-Status {
    $mdPath = Resolve-Md
    $list = Get-Map
    $entry = Find-Entry $list $mdPath
    if ($null -eq $entry) { Out-Result @{ result = 'NOT_SYNCED'; md = $mdPath }; return }
    Connect-Zt
    $s = Get-StoryOrNull ([int]$entry.storyId)
    if ($null -eq $s) {
        Out-Result @{ result = 'REMOTE_DELETED'; oldStoryId = [int]$entry.storyId; oldTasks = (Get-TaskList $entry) }
        return
    }
    Out-Result @{
        result = 'OK'; storyId = [int]$entry.storyId; title = [string]$s.title; status = [string]$s.status; project = (Get-EntryProject $entry)
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
    Add-Extra $body
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
    $h = @{ result = 'TASK_UPDATED'; taskId = $TaskId; fields = $changed }
    if ($sid) { $h['storyId'] = [int]$sid }
    Out-Result $h
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
        'check-deleted' { Do-CheckDeleted }
        'link-project' { Do-LinkProject }
        'task-add' { Do-TaskAdd }
        'task-update' { Do-TaskUpdate }
        'log' { Do-Log }
        default {
            Out-Result @{
                result = 'HELP'
                actions = 'login use accounts test products projects executions users sync status check-deleted link-project task-add task-update log'
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
