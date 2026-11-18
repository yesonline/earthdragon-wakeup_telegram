#Requires -Version 5.1
<#
    測試用的最小 HTTP 伺服器（TcpListener，不需系統管理員權限）。

    用途：在不呼叫真實 Telegram／Geoapify API 的前提下，驗證 earthdragon-wakeup_telegram.ps1 送出的請求內容（表單編碼、multipart、標頭）。

    - 每個請求的原始 body 存成 req-<n>.bin，UTF-8 解碼結果存成 req-<n>.txt
    - body 中含有 FAILME 時回傳 400，用來驗證失敗處理
    - 處理完 -MaxRequests 個請求後結束

#>

param(
    [int]$Port = 18471,
    [string]$OutDir = (Join-Path $PSScriptRoot 'out'),
    [int]$MaxRequests = 20,
    [int]$IdleSeconds = 30
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
}

# 1x1 透明 PNG
$pngBase64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=='
$pngBytes = [Convert]::FromBase64String($pngBase64)

$reverseJson = '{"results":[{"county":"南投縣","city":"南投縣","district":"魚池鄉","suburb":"","formatted":"南投縣 魚池鄉"}]}'
$okMessageJson = '{"ok":true,"result":{"message_id":1,"date":1717142400,"chat":{"id":1},"text":"ok"}}'
$okPhotoJson = '{"ok":true,"result":{"message_id":2}}'
$badJson = '{"ok":false,"error_code":400,"description":"Bad Request: chat not found"}'

$listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $Port)
$listener.Start()

Set-Content -LiteralPath (Join-Path $OutDir 'READY') -Value 'ready' -Encoding ASCII

function Read-HttpRequest {
    param([System.Net.Sockets.NetworkStream]$Stream)

    $buffer = New-Object byte[] 8192
    $accumulated = New-Object System.IO.MemoryStream
    $headerEnd = -1

    while ($true) {
        $read = $Stream.Read($buffer, 0, $buffer.Length)
        if ($read -le 0) { return $null }
        $accumulated.Write($buffer, 0, $read)
        $bytes = $accumulated.ToArray()
        for ($i = 3; $i -lt $bytes.Length; $i++) {
            if ($bytes[$i - 3] -eq 13 -and $bytes[$i - 2] -eq 10 -and
                $bytes[$i - 1] -eq 13 -and $bytes[$i] -eq 10) {
                $headerEnd = $i
                break
            }
        }
        if ($headerEnd -ge 0) { break }
    }

    $all = $accumulated.ToArray()
    $headerText = [System.Text.Encoding]::ASCII.GetString($all, 0, $headerEnd - 3)
    $lines = $headerText -split "`r`n"

    $requestLine = $lines[0] -split ' '
    $method = $requestLine[0]
    $path = $requestLine[1]

    $contentLength = 0
    if ($lines.Count -gt 1) {
        foreach ($line in $lines[1..($lines.Count - 1)]) {
            if ($line -match '^(?i)Content-Length:\s*(\d+)') {
                $contentLength = [int]$Matches[1]
            }
        }
    }

    $bodyStart = $headerEnd + 1
    $body = New-Object byte[] $contentLength
    $have = $all.Length - $bodyStart
    if ($have -gt 0) {
        $copy = [Math]::Min($have, $contentLength)
        [Array]::Copy($all, $bodyStart, $body, 0, $copy)
    }

    $received = $have
    while ($received -lt $contentLength) {
        $read = $Stream.Read($body, $received, $contentLength - $received)
        if ($read -le 0) { break }
        $received += $read
    }

    return @{
        Method = $method
        Path   = $path
        Headers = $headerText
        Body   = $body
    }
}

function Send-Response {
    param(
        [System.Net.Sockets.NetworkStream]$Stream,
        [int]$StatusCode,
        [string]$Reason,
        [byte[]]$Body,
        [string]$ContentType
    )

    $head = "HTTP/1.1 $StatusCode $Reason`r`n" +
    "Content-Type: $ContentType`r`n" +
    "Content-Length: $($Body.Length)`r`n" +
    "Connection: close`r`n`r`n"

    $headBytes = [System.Text.Encoding]::ASCII.GetBytes($head)
    $Stream.Write($headBytes, 0, $headBytes.Length)
    $Stream.Write($Body, 0, $Body.Length)
    $Stream.Flush()
}

$served = 0

try {
    while ($served -lt $MaxRequests) {
        $listener.Server.ReceiveTimeout = $IdleSeconds * 1000

        $client = $listener.AcceptTcpClient()
        $client.ReceiveTimeout = 10000

        try {
            $stream = $client.GetStream()
            $request = Read-HttpRequest -Stream $stream
            if ($null -eq $request) { continue }

            $served++
            $index = $served

            [System.IO.File]::WriteAllBytes(
                (Join-Path $OutDir ("req-{0}.bin" -f $index)), $request.Body)
            [System.IO.File]::WriteAllText(
                (Join-Path $OutDir ("req-{0}.txt" -f $index)),
                ($request.Method + ' ' + $request.Path + "`r`n`r`n" + $request.Headers + "`r`n`r`n" +
                    [System.Text.Encoding]::UTF8.GetString($request.Body)),
                [System.Text.Encoding]::UTF8)

            $bodyText = [System.Text.Encoding]::UTF8.GetString($request.Body)

            if ($bodyText -like '*FAILME*') {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($badJson)
                Send-Response -Stream $stream -StatusCode 400 -Reason 'Bad Request' -Body $bytes -ContentType 'application/json'
            }
            elseif ($request.Path -like '*/sendMessage*') {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($okMessageJson)
                Send-Response -Stream $stream -StatusCode 200 -Reason 'OK' -Body $bytes -ContentType 'application/json'
            }
            elseif ($request.Path -like '*/sendPhoto*') {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($okPhotoJson)
                Send-Response -Stream $stream -StatusCode 200 -Reason 'OK' -Body $bytes -ContentType 'application/json'
            }
            elseif ($request.Path -like '*/geocode/reverse*') {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes($reverseJson)
                Send-Response -Stream $stream -StatusCode 200 -Reason 'OK' -Body $bytes -ContentType 'application/json'
            }
            elseif ($request.Path -like '*/staticmap*') {
                Send-Response -Stream $stream -StatusCode 200 -Reason 'OK' -Body $pngBytes -ContentType 'image/png'
            }
            else {
                $bytes = [System.Text.Encoding]::UTF8.GetBytes('{"ok":false,"description":"unknown path"}')
                Send-Response -Stream $stream -StatusCode 404 -Reason 'Not Found' -Body $bytes -ContentType 'application/json'
            }
        }
        finally {
            $client.Close()
        }
    }
}
finally {
    $listener.Stop()
    Set-Content -LiteralPath (Join-Path $OutDir 'DONE') -Value "$served" -Encoding ASCII
}
