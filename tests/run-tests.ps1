#Requires -Version 5.1
<#
    離線端對端測試：不需要真實 Telegram Bot Token 或 Geoapify Key。

    執行方式：
        powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1

    測試內容：
        A. 語法檢查
        B. --dry-run 輸出格式（含缺值處理、地圖範圍計算）
        C. 完整流程：2 個 Chat ID、反向地理編碼、地圖產生、圖片上傳
        D. 失敗隔離：其中一個 Chat ID 回 400，文字警報仍應送達其他 Chat ID，
           且退出碼為 1
        E. 相容性選項：Forum Topic、多行 Chat ID、毫秒時間戳、未知參數
        F. 設定檔自動搜尋：同層 .config 生效、環境變數優先

#>

$ErrorActionPreference = 'Stop'

# ------------------------------------------------------------
# 子行程（earthdragon-wakeup_telegram.ps1）以 UTF-8 輸出，但 Windows PowerShell 5.1
# 預設用主控台代碼頁解讀原生程式輸出；繁中系統是 CP950，
# 會讓所有比對中文的斷言變成亂碼而失敗（純 ASCII 的斷言不受影響）。
# 這裡統一改用 UTF-8 解碼，跑完再還原主控台設定。
# ------------------------------------------------------------
$originalOutputEncoding = $null
try {
    $originalOutputEncoding = [Console]::OutputEncoding
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
}
catch {
    Write-Host '警告：無法將主控台輸出編碼設為 UTF-8，中文斷言可能失敗。' -ForegroundColor Yellow
}

if ([Console]::OutputEncoding.WebName -ne 'utf-8') {
    Write-Host ('提示：目前主控台輸出編碼為 {0}，中文斷言可能全部失敗；請改用 powershell.exe 直接執行。' -f [Console]::OutputEncoding.WebName) -ForegroundColor Yellow
}

$script:Failures = 0
$script:Passes = 0

$root = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $root 'earthdragon-wakeup_telegram.ps1'
$mockPath = Join-Path $PSScriptRoot 'mock-server.ps1'
$tmpDir = Join-Path $PSScriptRoot 'tmp'

if (Test-Path -LiteralPath $tmpDir) {
    Remove-Item -LiteralPath $tmpDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null

function Assert-True {
    param([bool]$Condition, [string]$Name)

    if ($Condition) {
        $script:Passes++
        Write-Host ('  [PASS] ' + $Name)
    }
    else {
        $script:Failures++
        Write-Host ('  [FAIL] ' + $Name) -ForegroundColor Red
    }
}

function Invoke-Client {
    param(
        [string]$ConfigPath = '',
        [string[]]$ClientArgs,
        [string]$Script = $scriptPath
    )

    if ([string]::IsNullOrEmpty($ConfigPath)) {
        Remove-Item Env:\DINIU_TELEGRAM_CONFIG -ErrorAction SilentlyContinue
    }
    else {
        $env:DINIU_TELEGRAM_CONFIG = $ConfigPath
    }

    # 子行程的日誌走 stderr；在 ErrorActionPreference=Stop 下 PowerShell 會把它當成終止性錯誤，因此這裡暫時放寬。
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $Script @ClientArgs 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    return @{
        # 日誌含完整路徑，預設 80 欄會折行導致比對失敗。
        Output = ($output | Out-String -Width 400)
        Code   = $code
    }
}

function Start-Mock {
    param([int]$Port, [string]$OutDir, [int]$MaxRequests)

    if (Test-Path -LiteralPath $OutDir) { Remove-Item -LiteralPath $OutDir -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

    # 路徑可能含空白（例如專案資料夾 Wake Up），必須自行加引號。
    $quotedScript = '"' + $mockPath + '"'
    $quotedOutDir = '"' + $OutDir + '"'

    $process = Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $quotedScript,
        '-Port', $Port, '-OutDir', $quotedOutDir, '-MaxRequests', $MaxRequests) `
        -PassThru -WindowStyle Hidden

    $ready = Join-Path $OutDir 'READY'
    $deadline = (Get-Date).AddSeconds(15)
    while (-not (Test-Path -LiteralPath $ready)) {
        if ((Get-Date) -gt $deadline) { throw "mock server 未在時限內啟動（port $Port）" }
        Start-Sleep -Milliseconds 100
    }

    return $process
}

function Get-Requests {
    param([string]$OutDir)

    $items = @()
    foreach ($file in (Get-ChildItem -LiteralPath $OutDir -Filter 'req-*.txt' | Sort-Object Name)) {
        $items += (Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8)
    }
    return $items
}

# ============================================================
# A. 語法檢查
# ============================================================

Write-Host ''
Write-Host 'A. 語法與編碼檢查'

$parseErrors = $null
[System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors) | Out-Null
Assert-True ($parseErrors.Count -eq 0) 'earthdragon-wakeup_telegram.ps1 語法正確'

$bytes = [System.IO.File]::ReadAllBytes($scriptPath)
$hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
Assert-True $hasBom 'earthdragon-wakeup_telegram.ps1 為 UTF-8 with BOM（PowerShell 5.1 必要）'

# ============================================================
# B. dry-run
# ============================================================

Write-Host ''
Write-Host 'B. --dry-run 輸出'

$dryConfig = Join-Path $tmpDir 'dry.conf'
@"
TELEGRAM_BOT_TOKEN='123456:TEST'
TELEGRAM_CHAT_IDS='111111'
ALERT_LOCATION='台北市'
"@ | Set-Content -LiteralPath $dryConfig -Encoding UTF8

$dry = Invoke-Client -ConfigPath $dryConfig -ClientArgs @(
    '--dry-run',
    '--epicenter-lat=23.85', '--epicenter-lon=120.82',
    '--depth=10', '--magnitude=7.3', '--max-intensity=7',
    '--local-intensity=5+', '--arrival-time=1717142400', '--remaining-time=20')

Assert-True ($dry.Code -eq 0) 'dry-run 退出碼為 0'
Assert-True ($dry.Output -like '*M7.3*') '規模顯示為 M7.3'
Assert-True ($dry.Output -like '*10 公里*') '深度顯示含單位'
Assert-True ($dry.Output -like '*2024-05-31 16:00:00*') 'Unix 時間戳換算為 Asia/Taipei'
Assert-True ($dry.Output -like '*剩餘時間：<b>20 秒</b>*') '剩餘時間顯示秒數'
Assert-True ($dry.Output -like '*rect:118.650000,26.350000,123.350000,21.150000*') '地圖範圍計算正確'
Assert-True ($dry.Output -like '*⚠️*') '震度 5+ 對應警示圖示'

$dryMissing = Invoke-Client -ConfigPath $dryConfig -ClientArgs @(
    '--dry-run', '--epicenter-lat=24.10', '--epicenter-lon=121.60', '--max-intensity=6')

Assert-True ($dryMissing.Output -notlike '*未提供 公里*') '缺值時不會出現「未提供 公里」'
Assert-True ($dryMissing.Output -like '*🚨*') '震度 6 對應強震圖示'
Assert-True ($dryMissing.Output -like '*規模：<b>未提供</b>*') '缺規模時顯示未提供'

$drySplit = Invoke-Client -ConfigPath $dryConfig -ClientArgs @(
    '--dry-run', '--epicenter-lat', '24.10', '--epicenter-lon', '121.60', '--magnitude', '6.2')

Assert-True ($drySplit.Output -like '*M6.2*') '支援空白分隔的參數形式（cmd.exe 切割後）'

# ============================================================
# C. 完整流程（mock）
# ============================================================

Write-Host ''
Write-Host 'C. 完整流程（2 個 Chat ID + 反向地理編碼 + 地圖）'

$portC = 18471
$outC = Join-Path $tmpDir 'out-c'
$configC = Join-Path $tmpDir 'e2e.conf'

@"
TELEGRAM_BOT_TOKEN='123456:TEST'
TELEGRAM_CHAT_IDS='111111,-1002222222'
ALERT_LOCATION='台北市'
TELEGRAM_API_BASE='http://127.0.0.1:$portC'
GEOAPIFY_API_KEY='testkey'
GEOAPIFY_MAP_BASE='http://127.0.0.1:$portC'
GEOAPIFY_GEOCODE_BASE='http://127.0.0.1:$portC'
"@ | Set-Content -LiteralPath $configC -Encoding UTF8

$mockC = Start-Mock -Port $portC -OutDir $outC -MaxRequests 6

$runC = Invoke-Client -ConfigPath $configC -ClientArgs @(
    '--epicenter-lat=23.85', '--epicenter-lon=120.82',
    '--depth=10', '--magnitude=7.3', '--max-intensity=7',
    '--local-intensity=5+', '--arrival-time=1717142400', '--remaining-time=20')

Start-Sleep -Milliseconds 500
if (-not $mockC.HasExited) { Stop-Process -Id $mockC.Id -Force -ErrorAction SilentlyContinue }

$requests = Get-Requests -OutDir $outC
$textRequests = @($requests | Where-Object { $_ -like 'POST */sendMessage*' })
$photoRequests = @($requests | Where-Object { $_ -like 'POST */sendPhoto*' })
$mapRequests = @($requests | Where-Object { $_ -like 'GET */staticmap*' })
$geocodeRequests = @($requests | Where-Object { $_ -like 'GET */geocode/reverse*' })

Assert-True ($runC.Code -eq 0) '整體退出碼為 0'
Assert-True ($requests.Count -eq 6) "共 6 個請求（實際 $($requests.Count)）"
Assert-True ($textRequests.Count -eq 2) "文字警報送出 2 次（實際 $($textRequests.Count)）"
Assert-True ($photoRequests.Count -eq 2) "地圖送出 2 次（實際 $($photoRequests.Count)）"
Assert-True ($mapRequests.Count -eq 1) '地圖只產生一次'
Assert-True ($geocodeRequests.Count -eq 1) '反向地理編碼只查詢一次'

$decodedTexts = @()
foreach ($request in $textRequests) {
    $body = ($request -split "`r`n`r`n")[-1]
    $pair = ($body -split '&') | Where-Object { $_ -like 'text=*' }
    $decodedTexts += [Uri]::UnescapeDataString(($pair -replace '^text=', ''))
}

Assert-True ($decodedTexts.Count -eq 2) '可解析出 2 段文字內容'
Assert-True (($decodedTexts | Where-Object { $_ -like '*地牛 Wake Up 地震速報*' }).Count -eq 2) '中文以 UTF-8 正確送出'
Assert-True (($decodedTexts | Where-Object { $_ -like '*所在地區：<b>台北市</b>*' }).Count -eq 2) '設定檔中文值正確'
Assert-True (($decodedTexts | Where-Object { $_ -like '*趴下、掩護、穩住*' }).Count -eq 2) '避難警語完整'
Assert-True (($textRequests | Where-Object { $_ -like '*chat_id=111111*' }).Count -eq 1) 'Chat ID 111111 已送出'
Assert-True (($textRequests | Where-Object { $_ -like '*chat_id=-1002222222*' }).Count -eq 1) 'Chat ID -1002222222 已送出'
Assert-True (($textRequests | Where-Object { $_ -like '*disable_notification=false*' }).Count -eq 2) '文字通知預設不靜音'
Assert-True (($textRequests | Where-Object { $_ -like '*parse_mode=HTML*' }).Count -eq 2) '使用 HTML 解析模式'

$photoRequest = $photoRequests[0]
$photoBinPath = $null
foreach ($txtFile in (Get-ChildItem -LiteralPath $outC -Filter 'req-*.txt' | Sort-Object Name)) {
    $content = Get-Content -LiteralPath $txtFile.FullName -Raw -Encoding UTF8
    if ($content -like 'POST */sendPhoto*') {
        $photoBinPath = ($txtFile.FullName -replace '\.txt$', '.bin')
        break
    }
}

$hasPngSignature = $false
if ($photoBinPath) {
    $photoRaw = [System.IO.File]::ReadAllBytes($photoBinPath)
    for ($i = 0; $i -lt ($photoRaw.Length - 8); $i++) {
        if ($photoRaw[$i] -eq 0x89 -and $photoRaw[$i + 1] -eq 0x50 -and $photoRaw[$i + 2] -eq 0x4E -and $photoRaw[$i + 3] -eq 0x47) {
            $hasPngSignature = $true
            break
        }
    }
}

Assert-True ($photoRequest -like '*filename="earthquake-map.png"*') 'multipart 含圖片檔名'
Assert-True $hasPngSignature 'multipart 內含 PNG 二進位內容'
Assert-True ($photoRequest -like '*震央附近：<b>南投縣 魚池鄉</b>*') '震央地名去重後正確（南投縣 魚池鄉）'
Assert-True ($photoRequest -like '*Content-Type: multipart/form-data; boundary=*') 'multipart 標頭正確'
Assert-True ($photoRequest -like '*🗺 <b>震央位置示意</b>*') '地圖說明含標題'
Assert-True ($mapRequests[0] -like '*area=rect%3A118.650000*') '地圖請求帶入 area 參數'
Assert-True ($mapRequests[0] -like '*marker*lonlat%3A120.82%2C23.85*') '地圖請求帶入震央標記'
Assert-True ($mapRequests[0] -like '*strokecolor*') '地圖標記樣式完整'
Assert-True ($geocodeRequests[0] -like '*lat=23.85*' -and $geocodeRequests[0] -like '*limit=1*') '反向地理編碼參數正確'

# ============================================================
# D. 失敗隔離
# ============================================================

Write-Host ''
Write-Host 'D. 失敗隔離（其中一個 Chat ID 回 400）'

$portD = 18472
$outD = Join-Path $tmpDir 'out-d'
$configD = Join-Path $tmpDir 'fail.conf'

@"
TELEGRAM_BOT_TOKEN='123456:TEST'
TELEGRAM_CHAT_IDS='111111,FAILME'
ALERT_LOCATION='台北市'
TELEGRAM_API_BASE='http://127.0.0.1:$portD'
GEOAPIFY_API_KEY='testkey'
GEOAPIFY_MAP_BASE='http://127.0.0.1:$portD'
GEOAPIFY_GEOCODE_BASE='http://127.0.0.1:$portD'
"@ | Set-Content -LiteralPath $configD -Encoding UTF8

$mockD = Start-Mock -Port $portD -OutDir $outD -MaxRequests 4

$runD = Invoke-Client -ConfigPath $configD -ClientArgs @(
    '--epicenter-lat=23.85', '--epicenter-lon=120.82', '--magnitude=5.8')

Start-Sleep -Milliseconds 500
if (-not $mockD.HasExited) { Stop-Process -Id $mockD.Id -Force -ErrorAction SilentlyContinue }

$requestsD = Get-Requests -OutDir $outD
$okText = @($requestsD | Where-Object { $_ -like 'POST */sendMessage*' -and $_ -like '*chat_id=111111*' })

Assert-True ($runD.Code -eq 1) '有 Chat ID 失敗時退出碼為 1'
Assert-True ($okText.Count -eq 1) '其他 Chat ID 仍收到文字警報'
Assert-True ($runD.Output -like '*chat not found*') '記錄 Telegram 回傳的錯誤描述'
Assert-True ($runD.Output -like '*文字通知完成：成功 1 個，失敗 1 個*') '統計數字正確'

# ============================================================
# E. 相容性選項
# ============================================================

Write-Host ''
Write-Host 'E. 相容性選項（Forum Topic、多行 Chat ID、毫秒時間戳）'

$portE = 18473
$outE = Join-Path $tmpDir 'out-e'
$configE = Join-Path $tmpDir 'topic.conf'

@"
TELEGRAM_BOT_TOKEN='123456:TEST'
TELEGRAM_CHAT_IDS='111111
-1002222222'
TELEGRAM_MESSAGE_THREAD_ID='77'
TELEGRAM_DISABLE_NOTIFICATION='true'
TELEGRAM_PROTECT_CONTENT='true'
ALERT_LOCATION='台北市'
TELEGRAM_API_BASE='http://127.0.0.1:$portE'
GEOAPIFY_API_KEY='testkey'
GEOAPIFY_MAP_BASE='http://127.0.0.1:$portE'
GEOAPIFY_GEOCODE_BASE='http://127.0.0.1:$portE'
"@ | Set-Content -LiteralPath $configE -Encoding UTF8

$mockE = Start-Mock -Port $portE -OutDir $outE -MaxRequests 6

$runE = Invoke-Client -ConfigPath $configE -ClientArgs @(
    '--epicenter-lat=23.85', '--epicenter-lon=120.82',
    '--magnitude=7.3', '--arrival-time=1717142400000', '--foo=bar')

Start-Sleep -Milliseconds 500
if (-not $mockE.HasExited) { Stop-Process -Id $mockE.Id -Force -ErrorAction SilentlyContinue }

$requestsE = Get-Requests -OutDir $outE
$textE = @($requestsE | Where-Object { $_ -like 'POST */sendMessage*' })
$photoE = @($requestsE | Where-Object { $_ -like 'POST */sendPhoto*' })

$decodedE = @()
foreach ($request in $textE) {
    $body = ($request -split "`r`n`r`n")[-1]
    $pair = ($body -split '&') | Where-Object { $_ -like 'text=*' }
    $decodedE += [Uri]::UnescapeDataString(($pair -replace '^text=', ''))
}

Assert-True ($runE.Code -eq 0) '含未知參數時仍正常結束'
Assert-True ($runE.Output -like '*忽略無法識別的參數：--foo=bar*') '未知參數會記錄並忽略'
Assert-True ($textE.Count -eq 2) '多行 Chat ID 解析為 2 個目標'
Assert-True (($textE | Where-Object { $_ -like '*message_thread_id=77*' }).Count -eq 2) '文字通知帶入 message_thread_id'
Assert-True (($textE | Where-Object { $_ -like '*disable_notification=true*' }).Count -eq 2) '靜音設定生效'
Assert-True (($textE | Where-Object { $_ -like '*protect_content=true*' }).Count -eq 2) '保護內容設定生效'
Assert-True (($decodedE | Where-Object { $_ -like '*2024-05-31 16:00:00*' }).Count -eq 2) '13 位數毫秒時間戳正確換算'
Assert-True (($photoE | Where-Object { $_ -like '*name="message_thread_id"*' }).Count -eq 2) '圖片訊息帶入 message_thread_id'

# ============================================================
# F. 設定檔自動搜尋
# ============================================================

Write-Host ''
Write-Host 'F. 設定檔自動搜尋（不依賴固定路徑）'

$discDir = Join-Path $tmpDir 'discovery'
New-Item -ItemType Directory -Force (Join-Path $discDir '.config') | Out-Null
Copy-Item -LiteralPath $scriptPath -Destination (Join-Path $discDir 'earthdragon-wakeup_telegram.ps1')

@"
TELEGRAM_BOT_TOKEN='123456:TEST'
TELEGRAM_CHAT_IDS='111111'
ALERT_LOCATION='測試市'
"@ | Set-Content -LiteralPath (Join-Path $discDir '.config\earthdragon-wakeup_telegram.conf') -Encoding UTF8

$runF = Invoke-Client `
    -ConfigPath '' `
    -Script (Join-Path $discDir 'earthdragon-wakeup_telegram.ps1') `
    -ClientArgs @('--dry-run', '--epicenter-lat=23.85', '--epicenter-lon=120.82')

Assert-True ($runF.Code -eq 0) '未設定環境變數時仍可執行'
Assert-True ($runF.Output -like '*所在地區：<b>測試市</b>*') '自動採用腳本同層 .config 內的設定檔'
Assert-True ($runF.Output -like '*discovery*earthdragon-wakeup_telegram.conf*') '日誌顯示實際載入的設定檔路徑'

$overrideConf = Join-Path $tmpDir 'override.conf'
@"
TELEGRAM_BOT_TOKEN='123456:TEST'
TELEGRAM_CHAT_IDS='111111'
ALERT_LOCATION='環境市'
"@ | Set-Content -LiteralPath $overrideConf -Encoding UTF8

$runF2 = Invoke-Client `
    -ConfigPath $overrideConf `
    -Script (Join-Path $discDir 'earthdragon-wakeup_telegram.ps1') `
    -ClientArgs @('--dry-run', '--epicenter-lat=23.85')

Assert-True ($runF2.Output -like '*所在地區：<b>環境市</b>*') '環境變數優先於腳本同層設定檔'

# ============================================================
# 結果
# ============================================================

Write-Host ''
Write-Host ('通過 {0} 項，失敗 {1} 項' -f $script:Passes, $script:Failures)

if ($null -ne $originalOutputEncoding) {
    try { [Console]::OutputEncoding = $originalOutputEncoding } catch { }
}

if ($script:Failures -gt 0) { exit 1 }
exit 0
