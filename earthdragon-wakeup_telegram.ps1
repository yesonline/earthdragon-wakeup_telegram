#Requires -Version 5.1
<#
.SYNOPSIS
    地牛 Wake Up to Telegram 地震通知（Windows / PowerShell 版）
	Earth Dragon (Diniu) Wake Up to Telegram Earthquake Alert (Windows / PowerShell Version)

.DESCRIPTION
    接收地牛 Wake Up 傳入的地震速報參數，組成 Telegram HTML 文字警報，並使用 Geoapify 靜態地圖產生震央位置示意圖。
      - 參數同時支援 --name=value 與 --name value（cmd.exe 會把 = 當分隔符）。
      - 設定檔 earthdragon-wakeup_telegram.conf。
      - 文字警報為核心通知，震央地圖為視覺輔助；震央地圖失敗不影響文字警報。
      - 時間固定以 ALERT_TIMEZONE（預設 Asia/Taipei）顯示。
      - 僅使用 Windows 內建的 PowerShell 5.1 與 .NET Framework，不需要 curl、jq、python 或任何外掛模組。

.NOTES
    版本：1.0.0
    相依：Windows PowerShell 5.1 以上（Windows 10 / 11 內建）

.EXAMPLE
    .\earthdragon-wakeup_telegram.ps1 --epicenter-lat=23.85 --epicenter-lon=120.82 --magnitude=7.3 --depth=10 --max-intensity=7 --local-intensity=5+ --arrival-time=1717142400 --remaining-time=20

.EXAMPLE
    # 只預覽訊息內容，不傳送、不呼叫任何 API
	.\earthdragon-wakeup_telegram.ps1 --dry-run --epicenter-lat=23.85 --epicenter-lon=120.82 --magnitude=7.3 --depth=10 --max-intensity=7 --local-intensity=5+ --arrival-time=1717142400 --remaining-time=20

#>

param()

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'

# ============================================================
# 全域狀態
# ============================================================

$Script:ScriptVersion = '1.0.0'
$Script:Config = @{}
$Script:LogFile = ''
$Script:TimeZone = [System.TimeZoneInfo]::Local

# 腳本所在資料夾。設定檔搜尋會以此為優先範圍，讓「整包放在專案資料夾直接跑」與「安裝到 Scripts\」兩種用法都能運作。
$Script:ScriptDirectory = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Script:ScriptDirectory)) {
    try { $Script:ScriptDirectory = (Get-Location).Path } catch { $Script:ScriptDirectory = '' }
}

# 執行期設定（載入設定檔後填入）
$Script:BotToken = ''
$Script:ChatIdsRaw = ''
$Script:MessageThreadId = ''
$Script:DisableNotification = 'false'
$Script:MapDisableNotification = 'true'
$Script:ProtectContent = 'false'
$Script:TelegramConnectTimeout = 10
$Script:TelegramMaxTime = 20

$Script:AlertLocation = ''
$Script:AlertTimeZoneId = 'Asia/Taipei'

$Script:GeoapifyApiKey = ''
$Script:GeoapifyMapBase = 'https://maps.geoapify.com'
$Script:GeoapifyGeocodeBase = 'https://api.geoapify.com'
$Script:TelegramApiBase = 'https://api.telegram.org'

$Script:MapEnabled = 'true'
$Script:MapStyle = 'osm-bright'
$Script:MapLang = 'zh'
$Script:MapWidth = 900
$Script:MapHeight = 900
$Script:MapScaleFactor = 1
$Script:MapConnectTimeout = 10
$Script:MapMaxTime = 30

$Script:ReverseGeocodingEnabled = 'true'
$Script:ReverseGeocodingLang = 'zh'
$Script:ReverseGeocodingConnectTimeout = 10
$Script:ReverseGeocodingMaxTime = 15

$Script:TaiwanWest = '119.0'
$Script:TaiwanEast = '123.0'
$Script:TaiwanNorth = '26.0'
$Script:TaiwanSouth = '21.5'
$Script:MapPadding = '0.35'

$Script:MarkerColor = '#e53935'
$Script:MarkerStrokeColor = '#8b0000'
$Script:MarkerContentColor = '#ffffff'
$Script:MarkerSize = '72'
$Script:MarkerContentSize = '34'

# 地牛 Wake Up 傳入參數
$Script:EpicenterLat = ''
$Script:EpicenterLon = ''
$Script:Depth = ''
$Script:Magnitude = ''
$Script:MaxIntensity = ''
$Script:LocalIntensity = ''
$Script:ArrivalTime = ''
$Script:RemainingTime = ''

# 震央附近地名（反向地理編碼結果）
$Script:EpicenterLocation = ''

# 暫存地圖檔
$Script:MapFile = ''

$Script:InvariantCulture = [System.Globalization.CultureInfo]::InvariantCulture

# ============================================================
# 日誌
# ============================================================

function Get-DiniuNow {
    return [System.TimeZoneInfo]::ConvertTimeFromUtc([DateTime]::UtcNow, $Script:TimeZone)
}

function Write-Log {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )

    $stamp = (Get-DiniuNow).ToString('yyyy-MM-dd HH:mm:ss', $Script:InvariantCulture)
    $line = '[' + $stamp + '] [' + $Level + '] ' + $Message

    try {
        [Console]::Error.WriteLine($line)
    }
    catch {
        Write-Host $line
    }

    if (-not [string]::IsNullOrWhiteSpace($Script:LogFile)) {
        try {
            $directory = Split-Path -Parent $Script:LogFile
            if ($directory -and -not (Test-Path -LiteralPath $directory)) {
                New-Item -ItemType Directory -Force -Path $directory | Out-Null
            }
            Add-Content -LiteralPath $Script:LogFile -Value $line -Encoding UTF8
        }
        catch {
            # 寫入日誌檔失敗不可影響通知流程。
        }
    }
}

function Stop-Diniu {
    param([Parameter(Mandatory = $true)][string]$Message)

    throw [System.InvalidOperationException]::new($Message)
}

# ============================================================
# 設定檔
#
# 刻意不 dot-source 設定檔：
#   1. 設定檔只是資料，不需要（也不應該）具備執行能力。
#   2. 副檔名為 .conf 的既有檔案可直接沿用，無需改成 .ps1。
# 支援：KEY='value'、KEY="value"、KEY=value、$KEY='value'、export KEY=value，以及以單／雙引號跨行的多行值（TELEGRAM_CHAT_IDS 可逐行列出）。
#
# ============================================================

function ConvertFrom-DiniuConfigText {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Text)

    $map = @{}
    $lines = $Text -split "\r?\n"
    $index = 0

    while ($index -lt $lines.Count) {
        $line = $lines[$index].Trim()
        $index++

        if ($line.Length -eq 0) { continue }
        if ($line.StartsWith('#')) { continue }
        if ($line.StartsWith(';')) { continue }

        $pattern = '^(?:export\s+)?\$?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*)$'
        if ($line -notmatch $pattern) { continue }

        $name = $Matches[1]
        $rest = $Matches[2]
        $value = ''

        if ($rest.StartsWith("'")) {
            $buffer = $rest.Substring(1)
            while ($true) {
                $end = $buffer.IndexOf("'")
                if ($end -ge 0) {
                    $value = $buffer.Substring(0, $end)
                    break
                }
                if ($index -ge $lines.Count) {
                    $value = $buffer
                    break
                }
                $buffer = $buffer + "`n" + $lines[$index]
                $index++
            }
        }
        elseif ($rest.StartsWith('"')) {
            $buffer = $rest.Substring(1)
            while ($true) {
                $end = $buffer.IndexOf('"')
                if ($end -ge 0) {
                    $value = $buffer.Substring(0, $end)
                    break
                }
                if ($index -ge $lines.Count) {
                    $value = $buffer
                    break
                }
                $buffer = $buffer + "`n" + $lines[$index]
                $index++
            }
        }
        else {
            # 未加引號的值：移除行內註解。
            $value = ($rest -replace '\s+#.*$', '').Trim()
        }

        $map[$name] = $value
    }

    return $map
}

function Read-DiniuConfig {
    param([Parameter(Mandatory = $true)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @{}
    }

    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    return ConvertFrom-DiniuConfigText -Text $text
}

# ------------------------------------------------------------
# 決定設定檔位置
#
# 不寫死單一路徑。依序尋找，第一個存在的就採用：
#   1. 環境變數 DINIU_TELEGRAM_CONFIG
#   2. <腳本資料夾>\.config\earthdragon-wakeup_telegram.conf
#   3. <腳本資料夾>\earthdragon-wakeup_telegram.conf
#   4. %USERPROFILE%\.config\earthdragon-wakeup_telegram.conf
#   5. %APPDATA%\earthdragon-wakeup_telegram\earthdragon-wakeup_telegram.conf
#
# 把 .config 放在腳本旁邊是最省事的用法：整包複製到哪裡都能跑，不需要設定環境變數，也不受使用者設定檔目錄影響。
#
# ------------------------------------------------------------

function Resolve-DiniuConfigPath {
    param(
        [AllowEmptyString()][string]$ExplicitPath = '',
        [AllowEmptyString()][string]$ScriptDirectory = ''
    )

    $candidates = New-Object System.Collections.Generic.List[string]

    if (-not [string]::IsNullOrWhiteSpace($ExplicitPath)) {
        $candidates.Add($ExplicitPath)
    }

    if (-not [string]::IsNullOrWhiteSpace($ScriptDirectory)) {
        $candidates.Add((Join-Path $ScriptDirectory '.config\earthdragon-wakeup_telegram.conf'))
        $candidates.Add((Join-Path $ScriptDirectory 'earthdragon-wakeup_telegram.conf'))
    }

    try {
        $candidates.Add((Join-Path $HOME '.config\earthdragon-wakeup_telegram.conf'))
    }
    catch {
    }

    if (-not [string]::IsNullOrWhiteSpace($env:APPDATA)) {
        $candidates.Add((Join-Path $env:APPDATA 'earthdragon-wakeup_telegram\earthdragon-wakeup_telegram.conf'))
    }

    $searched = New-Object System.Collections.Generic.List[string]

    foreach ($candidate in $candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        if ($searched.Contains($candidate)) { continue }

        $searched.Add($candidate)

        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return @{ Path = $candidate; Searched = $searched }
        }
    }

    return @{ Path = ''; Searched = $searched }
}

function Get-ConfigString {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Default = ''
    )

    if ($Script:Config.ContainsKey($Name)) {
        $value = $Script:Config[$Name]
        if ($null -ne $value -and -not [string]::IsNullOrWhiteSpace([string]$value)) {
            return [string]$value
        }
    }

    return $Default
}

function Get-ConfigBool {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [bool]$Default = $false
    )

    if ($Script:Config.ContainsKey($Name)) {
        return (Test-IsTrue ([string]$Script:Config[$Name]))
    }

    return $Default
}

function Get-ConfigInt {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [int]$Default = 0
    )

    if ($Script:Config.ContainsKey($Name)) {
        $raw = [string]$Script:Config[$Name]
        $parsed = 0
        if ([int]::TryParse($raw.Trim(), [ref]$parsed)) {
            return $parsed
        }
    }

    return $Default
}

# ============================================================
# 基礎工具
# ============================================================

function Test-IsTrue {
    param([AllowEmptyString()][AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }

    return (@('1', 'true', 'yes', 'on') -contains $Value.Trim().ToLowerInvariant())
}

function Test-IsNumber {
    param([AllowEmptyString()][AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }

    return ($Value.Trim() -match '^[-+]?[0-9]+([.][0-9]+)?$')
}

function ConvertTo-Double {
    param(
        [AllowEmptyString()][AllowNull()][string]$Value,
        [double]$Default = 0
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return $Default }

    $parsed = 0.0
    if ([double]::TryParse(
            $Value.Trim(),
            [System.Globalization.NumberStyles]::Float,
            $Script:InvariantCulture,
            [ref]$parsed)) {
        return $parsed
    }

    return $Default
}

function ConvertTo-HtmlEscaped {
    param([AllowEmptyString()][AllowNull()][string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return '' }

    # Telegram 支援 &amp; &lt; &gt; &quot; 與 &#39;
    return [System.Net.WebUtility]::HtmlEncode($Text)
}

function Format-DisplayValue {
    param(
        [AllowEmptyString()][AllowNull()][string]$Value,
        [string]$Fallback = '未提供'
    )

    if ([string]::IsNullOrWhiteSpace($Value)) { return $Fallback }

    return $Value.Trim()
}

function Format-UnixTime {
    param([AllowEmptyString()][AllowNull()][string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return '未提供' }

    $trimmed = $Value.Trim()

    # 非純數字（例如上游直接傳了可讀時間）就原樣顯示。
    if ($trimmed -notmatch '^[0-9]+$') { return $trimmed }

    $timestamp = [long]0
    if (-not [long]::TryParse($trimmed, [ref]$timestamp)) { return $trimmed }

    # 支援 13 位數毫秒時間戳。
    if ($timestamp -gt 9999999999) {
        $timestamp = [long][Math]::Floor($timestamp / 1000)
    }

    $epoch = [DateTime]::SpecifyKind([DateTime]'1970-01-01', [System.DateTimeKind]::Utc)

    try {
        $utc = $epoch.AddSeconds([double]$timestamp)
        $local = [System.TimeZoneInfo]::ConvertTimeFromUtc($utc, $Script:TimeZone)
        return $local.ToString('yyyy-MM-dd HH:mm:ss', $Script:InvariantCulture)
    }
    catch {
        return $trimmed
    }
}

function Resolve-DiniuTimeZone {
    param([Parameter(Mandatory = $true)][string]$Id)

    $candidates = New-Object System.Collections.Generic.List[string]
    $candidates.Add($Id)

    # Windows 的 .NET Framework 只認 Windows 時區 ID，.NET 6 以上才同時接受 IANA ID，因此兩種都試。
    switch -Regex ($Id) {
        '^(Asia/Taipei|Taipei)$' { $candidates.Add('Taipei Standard Time') }
        '^(Asia/Tokyo|Tokyo)$' { $candidates.Add('Tokyo Standard Time') }
        '^(Asia/Shanghai|Shanghai|Asia/Hong_Kong|Hong_Kong)$' { $candidates.Add('China Standard Time') }
        '^(UTC|Etc/UTC)$' { $candidates.Add('UTC') }
    }

    foreach ($candidate in $candidates) {
        try {
            return [System.TimeZoneInfo]::FindSystemTimeZoneById($candidate)
        }
        catch {
            continue
        }
    }

    $fallback = [System.TimeZoneInfo]::CreateCustomTimeZone(
        'DiniuFallback',
        [TimeSpan]::FromHours(8),
        'UTC+08',
        'UTC+08')

    return $fallback
}

function Get-AlertIcon {
    param([AllowEmptyString()][AllowNull()][string]$Intensity)

    $key = ([string]$Intensity).Trim().ToUpperInvariant()

    switch -Regex ($key) {
        '^7$' { return '🚨' }
        '^6(\+|-)?$' { return '🚨' }
        '^5(\+|-)?$' { return '⚠️' }
        '^4$' { return '🟠' }
        '^3$' { return '🟡' }
        '^[012]$' { return '🌏' }
        default { return '🌐' }
    }
}

# ============================================================
# 命令列參數
#
# 地牛 Wake Up 會把參數接在程式後面，且不加上引號，例如： earthdragon-wakeup_telegram.cmd --epicenter-lat=23.85 --depth=10 
# cmd.exe 會把未加引號的 = 視為分隔符，因此實際可能收到： --epicenter-lat=23.85 --depth 10
# 兩種形式都必須支援。
#
# ============================================================

function Read-CliArguments {
    param([string[]]$Arguments)

    $options = @{
        ShowHelp      = $false
        DryRun        = $false
        EpicenterLat  = ''
        EpicenterLon  = ''
        Depth         = ''
        Magnitude     = ''
        MaxIntensity  = ''
        LocalIntensity = ''
        ArrivalTime   = ''
        RemainingTime = ''
    }

    $nameToKey = @{
        'epicenter-lat'   = 'EpicenterLat'
        'epicenter-lon'   = 'EpicenterLon'
        'depth'           = 'Depth'
        'magnitude'       = 'Magnitude'
        'max-intensity'   = 'MaxIntensity'
        'local-intensity' = 'LocalIntensity'
        'arrival-time'    = 'ArrivalTime'
        'remaining-time'  = 'RemainingTime'
    }

    $unknown = New-Object System.Collections.Generic.List[string]

    if ($null -eq $Arguments) { $Arguments = @() }

    $index = 0
    while ($index -lt $Arguments.Count) {
        $token = [string]$Arguments[$index]
        $index++

        if ([string]::IsNullOrWhiteSpace($token)) { continue }

        if (@('-h', '--help', '-help', '-?', '/?') -contains $token) {
            $options.ShowHelp = $true
            continue
        }

        if (@('--dry-run', '-dry-run', '--dryrun', '-dryrun') -contains $token) {
            $options.DryRun = $true
            continue
        }

        if ($token -notmatch '^(?:--?|/)([A-Za-z][A-Za-z0-9_-]*)(?:[=:](.*))?$') {
            $unknown.Add($token)
            continue
        }

        $name = $Matches[1].ToLowerInvariant()
        $hasInlineValue = $Matches.ContainsKey(2) -and $null -ne $Matches[2]
        $value = ''
        if ($hasInlineValue) { $value = [string]$Matches[2] }

        if (-not $nameToKey.ContainsKey($name)) {
            $unknown.Add($token)
            continue
        }

        if (-not $hasInlineValue) {
            if ($index -lt $Arguments.Count) {
                $next = [string]$Arguments[$index]
                if ($next -notmatch '^(?:--?|/)[A-Za-z]') {
                    $value = $next
                    $index++
                }
            }
        }

        $options[$nameToKey[$name]] = $value
    }

    foreach ($item in $unknown) {
        Write-Log "忽略無法識別的參數：$item" 'WARN'
    }

    return $options
}

function Show-Usage {
    $text = @'
地牛 Wake Up → Telegram 地震通知（Windows / PowerShell 版）

用法：

  earthdragon-wakeup_telegram.cmd --epicenter-lat=23.85 --epicenter-lon=120.82 ^
    --depth=10 --magnitude=7.3 --max-intensity=7 ^
    --local-intensity=5+ --arrival-time=1717142400 --remaining-time=20

參數（與 macOS／Linux 版相同）：

  --epicenter-lat    震央緯度
  --epicenter-lon    震央經度
  --depth            震源深度（公里）
  --magnitude        地震規模
  --max-intensity    最大震度
  --local-intensity  所在地震度
  --arrival-time     震波抵達時間（Unix 時間戳，10 或 13 位數）
  --remaining-time   震波預計幾秒後抵達

同時支援：

  --參數=值
  --參數 值

額外選項：

  --dry-run          只輸出訊息內容，不傳送、不呼叫 API
  -h, --help         顯示本說明

設定檔搜尋順序（第一個存在的就採用）：

  1. 環境變數 DINIU_TELEGRAM_CONFIG
  2. <本程式資料夾>\.config\earthdragon-wakeup_telegram.conf
  3. <本程式資料夾>\earthdragon-wakeup_telegram.conf
  4. %USERPROFILE%\.config\earthdragon-wakeup_telegram.conf
  5. %APPDATA%\earthdragon-wakeup_telegram\earthdragon-wakeup_telegram.conf
'@

    Write-Output $text
}

# ============================================================
# HTTP
#
# 使用 HttpWebRequest 而非 Invoke-WebRequest：
#   1. PowerShell 5.1 的 Invoke-WebRequest 對 form/multipart 的非 ASCII 編碼處理不一致，自行組 body 才能確保 UTF-8。
#   2. 可分別設定整體逾時與讀寫逾時。
# 請求與回應一律以 UTF-8 處理。
#
# ============================================================

function Initialize-HttpRuntime {
    try {
        $protocols = [System.Net.SecurityProtocolType]::Tls12
        $names = [Enum]::GetNames([System.Net.SecurityProtocolType])
        if ($names -contains 'Tls13') {
            $protocols = $protocols -bor [System.Net.SecurityProtocolType]'Tls13'
        }
        [System.Net.ServicePointManager]::SecurityProtocol = $protocols
    }
    catch {
        # 舊版 .NET 不支援 TLS 1.3 時忽略即可，TLS 1.2 已足夠。
    }

    try {
        [System.Net.ServicePointManager]::Expect100Continue = $false
    }
    catch {
    }
}

function Test-IsLoopbackUri {
    param([Parameter(Mandatory = $true)][string]$Uri)

    try {
        $candidate = [Uri]$Uri
        return $candidate.IsLoopback
    }
    catch {
        return $false
    }
}

function Invoke-DiniuHttp {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [string]$Method = 'GET',
        [byte[]]$Body = $null,
        [string]$ContentType = '',
        [int]$TimeoutSeconds = 20,
        [string]$OutFile = ''
    )

    $result = @{
        Ok         = $false
        StatusCode = 0
        Content    = ''
        Error      = ''
    }

    if ($TimeoutSeconds -lt 1) { $TimeoutSeconds = 1 }

    $request = $null
    $response = $null

    try {
        $request = [System.Net.HttpWebRequest]::Create($Uri)
        $request.Method = $Method
        $request.Timeout = $TimeoutSeconds * 1000
        $request.ReadWriteTimeout = $TimeoutSeconds * 1000
        $request.AllowAutoRedirect = $true
        $request.KeepAlive = $false
        $request.UserAgent = 'earthdragon-wakeup_telegram-powershell/' + $Script:ScriptVersion

        # 本機位址一律不經 Proxy，其餘沿用系統（IE／WinHTTP）設定。
        if (Test-IsLoopbackUri -Uri $Uri) {
            $request.Proxy = $null
        }

        if ($null -ne $Body) {
            $request.ContentType = $ContentType
            $request.ContentLength = $Body.Length

            $requestStream = $request.GetRequestStream()
            try {
                $requestStream.Write($Body, 0, $Body.Length)
            }
            finally {
                $requestStream.Dispose()
            }
        }

        $response = $request.GetResponse()
        $result.StatusCode = [int]$response.StatusCode
        $result.Ok = ($result.StatusCode -ge 200 -and $result.StatusCode -lt 300)

        $responseStream = $response.GetResponseStream()

        if (-not [string]::IsNullOrWhiteSpace($OutFile)) {
            $fileStream = [System.IO.File]::Create($OutFile)
            try {
                $responseStream.CopyTo($fileStream)
            }
            finally {
                $fileStream.Dispose()
            }
        }
        else {
            $memoryStream = New-Object System.IO.MemoryStream
            try {
                $responseStream.CopyTo($memoryStream)
                $result.Content = [System.Text.Encoding]::UTF8.GetString($memoryStream.ToArray())
            }
            finally {
                $memoryStream.Dispose()
            }
        }

        $responseStream.Dispose()
    }
    catch [System.Net.WebException] {
        $webException = $_.Exception
        $errorResponse = $webException.Response

        if ($null -ne $errorResponse) {
            try {
                $result.StatusCode = [int]$errorResponse.StatusCode
                $errorStream = $errorResponse.GetResponseStream()
                $memoryStream = New-Object System.IO.MemoryStream
                try {
                    $errorStream.CopyTo($memoryStream)
                    $result.Content = [System.Text.Encoding]::UTF8.GetString($memoryStream.ToArray())
                }
                finally {
                    $memoryStream.Dispose()
                    $errorStream.Dispose()
                    $errorResponse.Dispose()
                }
                $result.Error = 'HTTP ' + $result.StatusCode
            }
            catch {
                $result.Error = $webException.Message
            }
        }
        else {
            # Status 會是 Timeout / NameResolutionFailure / TrustFailure 等，
            # 比本地化的 Message 更容易判讀。
            $result.Error = [string]$webException.Status + ': ' + $webException.Message
        }
    }
    catch {
        $result.Error = $_.Exception.Message
    }
    finally {
        if ($null -ne $response) {
            try { $response.Dispose() } catch { }
        }
    }

    return $result
}

function Get-TelegramErrorDescription {
    param([AllowEmptyString()][string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) { return '' }

    try {
        $parsed = $Content | ConvertFrom-Json
        if ($null -ne $parsed -and $null -ne $parsed.description) {
            return [string]$parsed.description
        }
    }
    catch {
    }

    if ($Content.Length -gt 300) { return $Content.Substring(0, 300) }
    return $Content
}

function Test-TelegramResponseOk {
    param([AllowEmptyString()][string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) { return $false }

    try {
        $parsed = $Content | ConvertFrom-Json
        return ($null -ne $parsed -and $parsed.ok -eq $true)
    }
    catch {
        return $false
    }
}

# ============================================================
# Telegram 文字通知
# ============================================================

function Send-TelegramMessage {
    param(
        [Parameter(Mandatory = $true)][string]$ChatId,
        [Parameter(Mandatory = $true)][string]$Text
    )

    $fields = New-Object System.Collections.Generic.List[string]
    $fields.Add('chat_id=' + [Uri]::EscapeDataString($ChatId))

    if (-not [string]::IsNullOrWhiteSpace($Script:MessageThreadId)) {
        $fields.Add('message_thread_id=' + [Uri]::EscapeDataString($Script:MessageThreadId))
    }

    $fields.Add('text=' + [Uri]::EscapeDataString($Text))
    $fields.Add('parse_mode=HTML')
    $fields.Add('disable_web_page_preview=true')
    $fields.Add('disable_notification=' + [Uri]::EscapeDataString($Script:DisableNotification))
    $fields.Add('protect_content=' + [Uri]::EscapeDataString($Script:ProtectContent))

    $url = $Script:TelegramApiBase.TrimEnd('/') + '/bot' + $Script:BotToken + '/sendMessage'
    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($fields -join '&'))

    $result = Invoke-DiniuHttp `
        -Uri $url `
        -Method 'POST' `
        -Body $bytes `
        -ContentType 'application/x-www-form-urlencoded; charset=utf-8' `
        -TimeoutSeconds $Script:TelegramMaxTime

    if (-not $result.Ok) {
        $detail = Get-TelegramErrorDescription -Content $result.Content
        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = $result.Error }
        Write-Log "文字通知傳送至 Chat ID $ChatId 失敗：$detail" 'ERROR'
        return $false
    }

    if (-not (Test-TelegramResponseOk -Content $result.Content)) {
        $detail = Get-TelegramErrorDescription -Content $result.Content
        Write-Log "文字通知傳送至 Chat ID $ChatId 失敗：$detail" 'ERROR'
        return $false
    }

    Write-Log "文字通知已成功傳送至 Chat ID：$ChatId"
    return $true
}

# ============================================================
# Telegram 地圖圖片
#
# 自行組 multipart/form-data： PowerShell 5.1 沒有 -Form 參數，且需要精確控制各欄位的 UTF-8 編碼。
#
# ============================================================

function Send-TelegramPhoto {
    param(
        [Parameter(Mandatory = $true)][string]$ChatId,
        [Parameter(Mandatory = $true)][string]$Caption,
        [Parameter(Mandatory = $true)][string]$FilePath
    )

    if (-not (Test-Path -LiteralPath $FilePath -PathType Leaf)) {
        Write-Log "找不到暫存地圖檔：$FilePath" 'ERROR'
        return $false
    }

    $boundary = '----DiniuTelegram' + [Guid]::NewGuid().ToString('N')
    $crlf = "`r`n"

    $fields = New-Object System.Collections.Generic.List[object]
    $fields.Add(@('chat_id', $ChatId))

    if (-not [string]::IsNullOrWhiteSpace($Script:MessageThreadId)) {
        $fields.Add(@('message_thread_id', $Script:MessageThreadId))
    }

    $fields.Add(@('caption', $Caption))
    $fields.Add(@('parse_mode', 'HTML'))
    $fields.Add(@('disable_notification', $Script:MapDisableNotification))
    $fields.Add(@('protect_content', $Script:ProtectContent))

    $builder = New-Object System.Text.StringBuilder

    foreach ($field in $fields) {
        [void]$builder.Append('--' + $boundary + $crlf)
        [void]$builder.Append('Content-Disposition: form-data; name="' + $field[0] + '"' + $crlf)
        [void]$builder.Append($crlf)
        [void]$builder.Append([string]$field[1] + $crlf)
    }

    [void]$builder.Append('--' + $boundary + $crlf)
    [void]$builder.Append('Content-Disposition: form-data; name="photo"; filename="earthquake-map.png"' + $crlf)
    [void]$builder.Append('Content-Type: image/png' + $crlf)
    [void]$builder.Append($crlf)

    $headerBytes = [System.Text.Encoding]::UTF8.GetBytes($builder.ToString())
    $footerBytes = [System.Text.Encoding]::UTF8.GetBytes($crlf + '--' + $boundary + '--' + $crlf)
    $fileBytes = [System.IO.File]::ReadAllBytes($FilePath)

    $body = New-Object byte[] ($headerBytes.Length + $fileBytes.Length + $footerBytes.Length)
    [Array]::Copy($headerBytes, 0, $body, 0, $headerBytes.Length)
    [Array]::Copy($fileBytes, 0, $body, $headerBytes.Length, $fileBytes.Length)
    [Array]::Copy($footerBytes, 0, $body, $headerBytes.Length + $fileBytes.Length, $footerBytes.Length)

    $url = $Script:TelegramApiBase.TrimEnd('/') + '/bot' + $Script:BotToken + '/sendPhoto'

    $result = Invoke-DiniuHttp `
        -Uri $url `
        -Method 'POST' `
        -Body $body `
        -ContentType ('multipart/form-data; boundary=' + $boundary) `
        -TimeoutSeconds $Script:TelegramMaxTime

    if (-not $result.Ok) {
        $detail = Get-TelegramErrorDescription -Content $result.Content
        if ([string]::IsNullOrWhiteSpace($detail)) { $detail = $result.Error }
        Write-Log "震央地圖傳送至 Chat ID $ChatId 失敗：$detail" 'ERROR'
        return $false
    }

    if (-not (Test-TelegramResponseOk -Content $result.Content)) {
        $detail = Get-TelegramErrorDescription -Content $result.Content
        Write-Log "震央地圖傳送至 Chat ID $ChatId 失敗：$detail" 'ERROR'
        return $false
    }

    Write-Log "震央地圖已成功傳送至 Chat ID：$ChatId"
    return $true
}

# ============================================================
# 反向地理編碼結果解析
#
# 對應 sh 版的 jq／python3 邏輯： county → city → district → suburb，去重後以空白串接；若全部為空則改用 formatted。
#
# ============================================================

function ConvertFrom-ReverseGeocodeJson {
    param([AllowEmptyString()][string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) { return '' }

    try {
        $data = $Content | ConvertFrom-Json
    }
    catch {
        return ''
    }

    $results = @($data.results)
    if ($results.Count -eq 0) { return '' }

    $first = $results[0]
    $values = New-Object System.Collections.Generic.List[string]

    foreach ($name in @('county', 'city', 'district', 'suburb')) {
        $value = $null
        try { $value = $first.$name } catch { $value = $null }

        if ($value -is [string]) {
            $trimmed = $value.Trim()
            if ($trimmed.Length -gt 0 -and -not $values.Contains($trimmed)) {
                $values.Add($trimmed)
            }
        }
    }

    $location = ''

    if ($values.Count -gt 0) {
        $location = $values -join ' '
    }
    else {
        $formatted = $null
        try { $formatted = $first.formatted } catch { $formatted = $null }

        if ($formatted -is [string]) {
            $location = $formatted.Trim()
        }
    }

    $location = ($location -replace '\s+', ' ').Trim()

    # 只回傳國名等級的結果時視為不可用，避免顯示「台灣」。
    foreach ($blocked in @('', '台灣', '臺灣', 'Taiwan')) {
        if ($location -eq $blocked) { return '' }
    }

    return $location
}

function Get-EpicenterLocation {
    $Script:EpicenterLocation = ''

    if (-not (Test-IsTrue $Script:ReverseGeocodingEnabled)) {
        Write-Log '震央反向地理編碼已停用'
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($Script:GeoapifyApiKey)) {
        Write-Log '未設定 GEOAPIFY_API_KEY，無法查詢震央附近地區' 'WARN'
        return $false
    }

    if (-not (Test-IsNumber $Script:EpicenterLat) -or -not (Test-IsNumber $Script:EpicenterLon)) {
        Write-Log '震央經緯度無效，略過反向地理編碼' 'WARN'
        return $false
    }

    Write-Log '正在查詢震央附近地區'

    $query = @(
        'lat=' + [Uri]::EscapeDataString($Script:EpicenterLat.Trim())
        'lon=' + [Uri]::EscapeDataString($Script:EpicenterLon.Trim())
        'lang=' + [Uri]::EscapeDataString($Script:ReverseGeocodingLang)
        'format=json'
        'limit=1'
        'apiKey=' + [Uri]::EscapeDataString($Script:GeoapifyApiKey)
    ) -join '&'

    $url = $Script:GeoapifyGeocodeBase.TrimEnd('/') + '/v1/geocode/reverse?' + $query

    $result = Invoke-DiniuHttp -Uri $url -TimeoutSeconds $Script:ReverseGeocodingMaxTime

    if (-not $result.Ok) {
        Write-Log '震央地區查詢失敗，震央地圖將省略地名' 'WARN'
        return $false
    }

    $location = ConvertFrom-ReverseGeocodeJson -Content $result.Content

    if ([string]::IsNullOrWhiteSpace($location)) {
        Write-Log 'Geoapify 未回傳可用地名，震央地圖將省略地名' 'WARN'
        return $false
    }

    $Script:EpicenterLocation = $location
    Write-Log "震央附近地區：$location"
    return $true
}

# ============================================================
# 地圖範圍：以台灣為基礎，再擴張至震央
#
# area 參數格式為 rect:lon1,lat1,lon2,lat2（西北角 → 東南角），因此輸出順序是 west,north,east,south。
#
# ============================================================

function Get-MapArea {
    $padding = ConvertTo-Double $Script:MapPadding 0.35
    $west = ConvertTo-Double $Script:TaiwanWest 119.0
    $east = ConvertTo-Double $Script:TaiwanEast 123.0
    $north = ConvertTo-Double $Script:TaiwanNorth 26.0
    $south = ConvertTo-Double $Script:TaiwanSouth 21.5

    $lat = ConvertTo-Double $Script:EpicenterLat 0
    $lon = ConvertTo-Double $Script:EpicenterLon 0

    if ($lon -lt $west) { $west = $lon }
    if ($lon -gt $east) { $east = $lon }
    if ($lat -gt $north) { $north = $lat }
    if ($lat -lt $south) { $south = $lat }

    $west -= $padding
    $east += $padding
    $north += $padding
    $south -= $padding

    return [string]::Format(
        $Script:InvariantCulture,
        'rect:{0:F6},{1:F6},{2:F6},{3:F6}',
        $west, $north, $east, $south)
}

function Test-PngSignature {
    param([Parameter(Mandatory = $true)][string]$Path)

    try {
        $bytes = [System.IO.File]::ReadAllBytes($Path)
    }
    catch {
        return $false
    }

    if ($bytes.Length -lt 8) { return $false }

    $signature = @(0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A)
    for ($i = 0; $i -lt $signature.Count; $i++) {
        if ($bytes[$i] -ne $signature[$i]) { return $false }
    }

    return $true
}

# ============================================================
# 產生 Geoapify 靜態地圖
# ============================================================

function New-EpicenterMap {
    if (-not (Test-IsTrue $Script:MapEnabled)) {
        Write-Log '震央地圖功能已停用'
        return $false
    }

    if ([string]::IsNullOrWhiteSpace($Script:GeoapifyApiKey)) {
        Write-Log '未設定 GEOAPIFY_API_KEY，略過震央地圖' 'WARN'
        return $false
    }

    if (-not (Test-IsNumber $Script:EpicenterLat) -or -not (Test-IsNumber $Script:EpicenterLon)) {
        Write-Log '震央經緯度無效，略過震央地圖' 'WARN'
        return $false
    }

    $path = Join-Path ([System.IO.Path]::GetTempPath()) ('diniu-map-' + [Guid]::NewGuid().ToString('N') + '.png')

    $area = Get-MapArea
    $marker = [string]::Format(
        $Script:InvariantCulture,
        'lonlat:{0},{1};type:circle;color:{2};size:{3};text:!;contentsize:{4};contentcolor:{5};whitecircle:no;shadow:auto;strokecolor:{6}',
        (ConvertTo-Double $Script:EpicenterLon 0),
        (ConvertTo-Double $Script:EpicenterLat 0),
        $Script:MarkerColor,
        $Script:MarkerSize,
        $Script:MarkerContentSize,
        $Script:MarkerContentColor,
        $Script:MarkerStrokeColor)

    $query = @(
        'style=' + [Uri]::EscapeDataString($Script:MapStyle)
        'width=' + $Script:MapWidth
        'height=' + $Script:MapHeight
        'format=png'
        'scaleFactor=' + $Script:MapScaleFactor
        'lang=' + [Uri]::EscapeDataString($Script:MapLang)
        'area=' + [Uri]::EscapeDataString($area)
        'marker=' + [Uri]::EscapeDataString($marker)
        'apiKey=' + [Uri]::EscapeDataString($Script:GeoapifyApiKey)
    ) -join '&'

    $url = $Script:GeoapifyMapBase.TrimEnd('/') + '/v1/staticmap?' + $query

    Write-Log '正在向 Geoapify 產生震央地圖'

    $result = Invoke-DiniuHttp `
        -Uri $url `
        -TimeoutSeconds $Script:MapMaxTime `
        -OutFile $path

    if (-not $result.Ok) {
        Write-Log 'Geoapify 地圖產生失敗，文字警報不受影響' 'WARN'
        if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue }
        return $false
    }

    if (-not (Test-Path -LiteralPath $path)) {
        Write-Log 'Geoapify 未回傳地圖檔' 'WARN'
        return $false
    }

    $file = Get-Item -LiteralPath $path
    if ($file.Length -eq 0) {
        Write-Log 'Geoapify 回傳空白地圖' 'WARN'
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        return $false
    }

    if (-not (Test-PngSignature -Path $path)) {
        Write-Log 'Geoapify 回傳的內容不是有效 PNG，已捨棄' 'WARN'
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
        return $false
    }

    $Script:MapFile = $path
    Write-Log 'Geoapify 震央地圖產生完成'
    return $true
}

# ============================================================
# 主流程
# ============================================================

$exitCode = 0

try {
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
    }
    catch {
    }

    Initialize-HttpRuntime

    # ---- 命令列參數 ----

    $options = Read-CliArguments -Arguments $args

    if ($options.ShowHelp) {
        Show-Usage
        exit 0
    }

    $Script:EpicenterLat = $options.EpicenterLat
    $Script:EpicenterLon = $options.EpicenterLon
    $Script:Depth = $options.Depth
    $Script:Magnitude = $options.Magnitude
    $Script:MaxIntensity = $options.MaxIntensity
    $Script:LocalIntensity = $options.LocalIntensity
    $Script:ArrivalTime = $options.ArrivalTime
    $Script:RemainingTime = $options.RemainingTime

    # ---- 設定檔 ----

    $explicitConfig = $env:DINIU_TELEGRAM_CONFIG

    $configResolution = Resolve-DiniuConfigPath `
        -ExplicitPath $explicitConfig `
        -ScriptDirectory $Script:ScriptDirectory

    $configPath = $configResolution.Path

    if ([string]::IsNullOrWhiteSpace($configPath)) {
        Write-Log '找不到設定檔，已搜尋以下位置：' 'WARN'
        foreach ($searchedPath in $configResolution.Searched) {
            Write-Log ('  ' + $searchedPath) 'WARN'
        }
        $Script:Config = @{}
    }
    else {
        if (-not [string]::IsNullOrWhiteSpace($explicitConfig) -and
            -not [string]::Equals($configPath, $explicitConfig, [System.StringComparison]::OrdinalIgnoreCase)) {
            Write-Log "DINIU_TELEGRAM_CONFIG 指定的檔案不存在，改用：$configPath" 'WARN'
        }

        $Script:Config = Read-DiniuConfig -Path $configPath
        Write-Log "已載入設定檔：$configPath"
    }

    # 後續錯誤訊息要指路；沒有設定檔時給的是「怎麼指定」，不是一個空路徑。
    $configHint = '請參考 --help 或改用 DINIU_TELEGRAM_CONFIG 指定'
    if (-not [string]::IsNullOrWhiteSpace($configPath)) {
        $configHint = "請檢查 $configPath"
    }

    $Script:BotToken = Get-ConfigString 'TELEGRAM_BOT_TOKEN'

    $Script:ChatIdsRaw = Get-ConfigString 'TELEGRAM_CHAT_IDS'
    if ([string]::IsNullOrWhiteSpace($Script:ChatIdsRaw)) {
        $Script:ChatIdsRaw = Get-ConfigString 'TELEGRAM_CHAT_ID'
    }

    $Script:MessageThreadId = Get-ConfigString 'TELEGRAM_MESSAGE_THREAD_ID'
    $Script:DisableNotification = if (Get-ConfigBool 'TELEGRAM_DISABLE_NOTIFICATION' $false) { 'true' } else { 'false' }
    $Script:MapDisableNotification = if (Get-ConfigBool 'TELEGRAM_MAP_DISABLE_NOTIFICATION' $true) { 'true' } else { 'false' }
    $Script:ProtectContent = if (Get-ConfigBool 'TELEGRAM_PROTECT_CONTENT' $false) { 'true' } else { 'false' }
    $Script:TelegramConnectTimeout = Get-ConfigInt 'TELEGRAM_CONNECT_TIMEOUT' 10
    $Script:TelegramMaxTime = Get-ConfigInt 'TELEGRAM_MAX_TIME' 20
    $Script:TelegramApiBase = Get-ConfigString 'TELEGRAM_API_BASE' 'https://api.telegram.org'

    $Script:AlertLocation = Get-ConfigString 'ALERT_LOCATION'
    $Script:AlertTimeZoneId = Get-ConfigString 'ALERT_TIMEZONE' 'Asia/Taipei'
    $Script:TimeZone = Resolve-DiniuTimeZone -Id $Script:AlertTimeZoneId

    $Script:GeoapifyApiKey = Get-ConfigString 'GEOAPIFY_API_KEY'
    $Script:GeoapifyMapBase = Get-ConfigString 'GEOAPIFY_MAP_BASE' 'https://maps.geoapify.com'
    $Script:GeoapifyGeocodeBase = Get-ConfigString 'GEOAPIFY_GEOCODE_BASE' 'https://api.geoapify.com'

    $Script:MapEnabled = if (Get-ConfigBool 'MAP_ENABLED' $true) { 'true' } else { 'false' }
    $Script:MapStyle = Get-ConfigString 'MAP_STYLE' 'osm-bright'
    $Script:MapLang = Get-ConfigString 'MAP_LANG' 'zh'
    $Script:MapWidth = Get-ConfigInt 'MAP_WIDTH' 900
    $Script:MapHeight = Get-ConfigInt 'MAP_HEIGHT' 900
    $Script:MapScaleFactor = Get-ConfigInt 'MAP_SCALE_FACTOR' 1
    $Script:MapConnectTimeout = Get-ConfigInt 'MAP_CONNECT_TIMEOUT' 10
    $Script:MapMaxTime = Get-ConfigInt 'MAP_MAX_TIME' 30

    $Script:ReverseGeocodingEnabled = if (Get-ConfigBool 'REVERSE_GEOCODING_ENABLED' $true) { 'true' } else { 'false' }
    $Script:ReverseGeocodingLang = Get-ConfigString 'REVERSE_GEOCODING_LANG' 'zh'
    $Script:ReverseGeocodingConnectTimeout = Get-ConfigInt 'REVERSE_GEOCODING_CONNECT_TIMEOUT' 10
    $Script:ReverseGeocodingMaxTime = Get-ConfigInt 'REVERSE_GEOCODING_MAX_TIME' 15

    $Script:TaiwanWest = Get-ConfigString 'MAP_TAIWAN_WEST' '119.0'
    $Script:TaiwanEast = Get-ConfigString 'MAP_TAIWAN_EAST' '123.0'
    $Script:TaiwanNorth = Get-ConfigString 'MAP_TAIWAN_NORTH' '26.0'
    $Script:TaiwanSouth = Get-ConfigString 'MAP_TAIWAN_SOUTH' '21.5'
    $Script:MapPadding = Get-ConfigString 'MAP_PADDING' '0.35'

    $Script:MarkerColor = Get-ConfigString 'MAP_MARKER_COLOR' '#e53935'
    $Script:MarkerStrokeColor = Get-ConfigString 'MAP_MARKER_STROKE_COLOR' '#8b0000'
    $Script:MarkerContentColor = Get-ConfigString 'MAP_MARKER_CONTENT_COLOR' '#ffffff'
    $Script:MarkerSize = Get-ConfigString 'MAP_MARKER_SIZE' '72'
    $Script:MarkerContentSize = Get-ConfigString 'MAP_MARKER_CONTENT_SIZE' '34'

    $Script:LogFile = Get-ConfigString 'LOG_FILE'

    # ---- 檢查必要設定 ----

    if (-not $options.DryRun) {
        if ([string]::IsNullOrWhiteSpace($Script:BotToken)) {
            Stop-Diniu "尚未設定 TELEGRAM_BOT_TOKEN，$configHint"
        }

        if ([string]::IsNullOrWhiteSpace($Script:ChatIdsRaw)) {
            Stop-Diniu "尚未設定 TELEGRAM_CHAT_IDS，$configHint"
        }

        if ([string]::IsNullOrWhiteSpace($Script:AlertLocation)) {
            Stop-Diniu "尚未設定 ALERT_LOCATION，$configHint"
        }
    }

    # ---- 整理文字警報內容 ----

    $arrivalTimeText = Format-UnixTime $Script:ArrivalTime
    $receivedTime = (Get-DiniuNow).ToString('yyyy-MM-dd HH:mm:ss', $Script:InvariantCulture)

    $locationHtml = ConvertTo-HtmlEscaped (Format-DisplayValue $Script:AlertLocation)
    $localIntensityHtml = ConvertTo-HtmlEscaped (Format-DisplayValue $Script:LocalIntensity)
    $maxIntensityHtml = ConvertTo-HtmlEscaped (Format-DisplayValue $Script:MaxIntensity)
    $latHtml = ConvertTo-HtmlEscaped (Format-DisplayValue $Script:EpicenterLat)
    $lonHtml = ConvertTo-HtmlEscaped (Format-DisplayValue $Script:EpicenterLon)
    $arrivalHtml = ConvertTo-HtmlEscaped $arrivalTimeText
    $receivedHtml = ConvertTo-HtmlEscaped $receivedTime

    # 單位只在有值時才接上，避免出現「未提供 公里」。
    if ([string]::IsNullOrWhiteSpace($Script:Magnitude)) {
        $magnitudeHtml = '未提供'
    }
    else {
        $magnitudeHtml = 'M' + (ConvertTo-HtmlEscaped $Script:Magnitude.Trim())
    }

    if ([string]::IsNullOrWhiteSpace($Script:Depth)) {
        $depthHtml = '未提供'
    }
    else {
        $depthHtml = (ConvertTo-HtmlEscaped $Script:Depth.Trim()) + ' 公里'
    }

    if ([string]::IsNullOrWhiteSpace($Script:RemainingTime)) {
        $remainingHtml = '未提供'
    }
    else {
        $remainingHtml = (ConvertTo-HtmlEscaped $Script:RemainingTime.Trim()) + ' 秒'
    }

    $iconIntensity = $Script:LocalIntensity
    if ([string]::IsNullOrWhiteSpace($iconIntensity)) {
        $iconIntensity = $Script:MaxIntensity
    }
    $alertIcon = Get-AlertIcon $iconIntensity

    $mapLinkLine = ''
    if (-not [string]::IsNullOrWhiteSpace($Script:EpicenterLat) -and
        -not [string]::IsNullOrWhiteSpace($Script:EpicenterLon)) {

        $googleMapUrl = 'https://www.google.com/maps/search/?api=1&query=' +
            [Uri]::EscapeDataString($Script:EpicenterLat.Trim()) + ',' +
            [Uri]::EscapeDataString($Script:EpicenterLon.Trim())

        $mapLinkLine = "`n🗺 <a href=`"$(ConvertTo-HtmlEscaped $googleMapUrl)`">開啟互動式震央地圖</a>"
    }

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($alertIcon + ' <b>地牛 Wake Up 地震速報</b>')
    $lines.Add('')
    $lines.Add('🏠 所在地區：<b>' + $locationHtml + '</b>')
    $lines.Add('📍 所在地震度：<b>' + $localIntensityHtml + '</b>')
    $lines.Add('📊 最大震度：<b>' + $maxIntensityHtml + '</b>')
    $lines.Add('📏 地震規模：<b>' + $magnitudeHtml + '</b>')
    $lines.Add('🌊 震源深度：<b>' + $depthHtml + '</b>')
    $lines.Add('')
    $lines.Add('🌐 震央座標：<code>' + $latHtml + ', ' + $lonHtml + '</code>')
    $lines.Add('⏰ 預計抵達：<b>' + $arrivalHtml + '</b>')
    $lines.Add('⏳ 剩餘時間：<b>' + $remainingHtml + '</b>')
    $lines.Add('')
    $lines.Add('⚡️ <b>就近掩護，牢記「趴下、掩護、穩住」</b>')
    $lines.Add('')
    $lines.Add('🕒 收到時間：' + $receivedHtml + $mapLinkLine)

    $message = $lines -join "`n"

    # ---- Dry run ----

    if ($options.DryRun) {
        $mapCaptionPreview = '🗺 <b>震央位置示意</b>' + "`n" +
            '📍 震央座標：<code>' + $latHtml + ', ' + $lonHtml + '</code>' + "`n" +
            '📏 地震規模：<b>' + $magnitudeHtml + '</b>' + "`n" +
            '🌊 震源深度：<b>' + $depthHtml + '</b>'

        Write-Output '--- 文字警報（不會傳送） ---'
        Write-Output $message
        Write-Output ''
        Write-Output '--- 震央地圖（不會傳送） ---'
        Write-Output $mapCaptionPreview
        Write-Output ''
        Write-Output '--- 地圖範圍 ---'
        if (Test-IsNumber $Script:EpicenterLat -and Test-IsNumber $Script:EpicenterLon) {
            Write-Output (Get-MapArea)
        }
        else {
            Write-Output '（震央座標無效，不會產生地圖）'
        }
        exit 0
    }

    # ---- 正規化 Chat ID ----

    $chatIds = New-Object System.Collections.Generic.List[string]

    foreach ($item in ($Script:ChatIdsRaw -split '[,\s;]+')) {
        $chatId = $item.Trim()
        if ($chatId.Length -eq 0) { continue }
        if ($chatIds.Contains($chatId)) {
            Write-Log "忽略重複的 Chat ID：$chatId" 'WARN'
            continue
        }
        $chatIds.Add($chatId)
    }

    if ($chatIds.Count -eq 0) {
        Stop-Diniu 'TELEGRAM_CHAT_IDS 中沒有有效的 Chat ID'
    }

    # ---- 第一階段：先傳送文字警報 ----

    $textSuccessCount = 0
    $textFailCount = 0

    foreach ($chatId in $chatIds) {
        if (Send-TelegramMessage -ChatId $chatId -Text $message) {
            $textSuccessCount++
        }
        else {
            $textFailCount++
        }
    }

    Write-Log "文字通知完成：成功 $textSuccessCount 個，失敗 $textFailCount 個"

    # ---- 第二階段：查詢震央附近地區（文字警報送出後才執行） ----

    Get-EpicenterLocation | Out-Null

    $mapCaptionLines = New-Object System.Collections.Generic.List[string]
    $mapCaptionLines.Add('🗺 <b>震央位置示意</b>')
    if (-not [string]::IsNullOrWhiteSpace($Script:EpicenterLocation)) {
        $mapCaptionLines.Add('📌 震央附近：<b>' + (ConvertTo-HtmlEscaped $Script:EpicenterLocation) + '</b>')
    }
    $mapCaptionLines.Add('📍 震央座標：<code>' + $latHtml + ', ' + $lonHtml + '</code>')
    $mapCaptionLines.Add('📏 地震規模：<b>' + $magnitudeHtml + '</b>')
    $mapCaptionLines.Add('🌊 震源深度：<b>' + $depthHtml + '</b>')
    $mapCaption = $mapCaptionLines -join "`n"

    # ---- 第三階段：產生一次地圖，再傳給所有 Chat ID ----

    if (New-EpicenterMap) {
        $photoSuccessCount = 0
        $photoFailCount = 0

        foreach ($chatId in $chatIds) {
            if (Send-TelegramPhoto -ChatId $chatId -Caption $mapCaption -FilePath $Script:MapFile) {
                $photoSuccessCount++
            }
            else {
                $photoFailCount++
            }
        }

        Write-Log "震央地圖完成：成功 $photoSuccessCount 個，失敗 $photoFailCount 個"
    }
    else {
        Write-Log '震央地圖已略過；文字警報已照常處理'
    }

    # 只有核心文字警報失敗時，腳本才回傳錯誤。
    if ($textFailCount -gt 0) {
        $exitCode = 1
    }
}
catch {
    Write-Log ('錯誤：' + $_.Exception.Message) 'ERROR'
    $exitCode = 1
}
finally {
    if (-not [string]::IsNullOrWhiteSpace($Script:MapFile)) {
        if (Test-Path -LiteralPath $Script:MapFile) {
            Remove-Item -LiteralPath $Script:MapFile -Force -ErrorAction SilentlyContinue
        }
    }
}

exit $exitCode
