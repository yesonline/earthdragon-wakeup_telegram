# 地牛 Wake Up to Telegram 地震通知（Windows / PowerShell 版）說明

將地牛 Wake Up 收到的預警震度轉發給外部程式。這支程式把參數整理排版成 Telegram 訊息格式送出，再用 Geoapify 畫一張震央示意圖。全程只用到 Windows 內建的 PowerShell 5.1，不需要額外安裝 curl、jq、python 或任何外掛模組。

一次事件會產生兩則訊息：**文字警報**（所在地區、所在地震度、最大震度、規模、深度、抵達倒數、避難警語、互動地圖連結）與**震央地圖**（位置示意圖、震央附近地名、座標）。文字先送，地圖後送；地圖失敗不影響文字。

| 項目 | 內容 |
|---|---|
| 適用系統 | Windows 10 / 11 |
| 執行環境 | Windows PowerShell 5.1（系統內建，不需 PowerShell 7） |
| 外部相依 | 無 |
| 地牛 Wake Up 連動目標 | `earthdragon-wakeup_telegram.cmd` |
| 主程式 | `earthdragon-wakeup_telegram.ps1`（UTF-8 with BOM） |
| 設定檔 | 自動搜尋，不綁固定路徑（見第三章） |
| 需要連線 | `api.telegram.org`、`maps.geoapify.com`、`api.geoapify.com` |
| 結束碼 | `0` 成功、`1` 失敗 |

## 如何閱讀說明

| 章節 | 內容 | 什麼時候看 |
|---|---|---|
| 一 | 四步上線 | 第一次安裝 |
| 二 | 接上地牛 Wake Up  | 設定連動、確認參數怎麼進來 |
| 三 | 設定檔逐項 | 調整行為、加第二個群組 |
| 四 | 參數與訊息對照 | 核對欄位、確認格式 |
| 五 | 症狀排查 | 沒有訊息、沒有地圖、時間不對 |
| 六 | 附錄 | 指令速查、申請 Token、設計取捨 |

---

## 一、四步上線

### ① 放檔案

來源資料夾長這樣（以本專案為例）：

```text
C:\Workspace\earthdragon-wakeup_telegram\
├── earthdragon-wakeup_telegram.ps1
├── earthdragon-wakeup_telegram.cmd
└── .config\
    └── earthdragon-wakeup_telegram.conf
```

搬完之後變成這樣（`C:\Users\請換成你的帳號` ）：

```text
C:\Users\請換成你的帳號\
├── Scripts\
│   ├── earthdragon-wakeup_telegram.ps1
│   └── earthdragon-wakeup_telegram.cmd
└── .config\
    └── earthdragon-wakeup_telegram.conf
```

```console
$ProjectDir = "C:\Workspace\earthdragon-wakeup_telegram"

New-Item -ItemType Directory -Force "$HOME\Scripts", "$HOME\.config" | Out-Null
Copy-Item "$ProjectDir\earthdragon-wakeup_telegram.ps1", "$ProjectDir\earthdragon-wakeup_telegram.cmd" "$HOME\Scripts\"
Copy-Item "$ProjectDir\.config\earthdragon-wakeup_telegram.conf" "$HOME\.config\"
```

換位置只要改 `$ProjectDir` 那一行。

不想搬檔案、直接在專案資料夾執行也可以：`.config` 留在程式旁邊就會自動被找到，不必設任何環境變數。只有想強制指定某一份設定檔時，才需要 `setx DINIU_TELEGRAM_CONFIG "完整路徑"`（設定後要重啟地牛 Wake Up）。

### ② 解除網路封鎖

只有「從網路下載或解壓縮」的檔案需要這步。Windows 會在檔案上留下來源標記，沒解除可能直接被攔下來。

```console
Get-ChildItem "$HOME\Scripts\earthdragon-wakeup_telegram.*" | Unblock-File
```

### ③ 填四個值

打開 `%USERPROFILE%\.config\earthdragon-wakeup_telegram.conf`，先補這四行就好：

```ini
TELEGRAM_BOT_TOKEN='123456789:AAH...'
TELEGRAM_CHAT_IDS='123456789,-1001234567890'
ALERT_LOCATION='台北市'
GEOAPIFY_API_KEY='...'
```

Token、Chat ID、Geoapify Key 怎麼拿，見附錄 B。其餘設定都有預設值，第三節再處理。

### ④ 試跑一次

`--dry-run` 只印訊息，不送出、不呼叫任何 API。

```console
$Diniu = "$HOME\Scripts\earthdragon-wakeup_telegram.ps1"

# 還沒搬檔案、直接在專案資料夾試跑的話，改用這一行：
# $Diniu = "C:\Workspace\earthdragon-wakeup_telegram\earthdragon-wakeup_telegram.ps1"

powershell -NoProfile -ExecutionPolicy Bypass -File $Diniu `
  --dry-run `
  --epicenter-lat=23.85 --epicenter-lon=120.82 `
  --depth=10 --magnitude=7.3 `
  --max-intensity=7 --local-intensity=5+ `
  --remaining-time=20
```

```text
--- 文字警報（不會傳送） ---
⚠️ <b>地牛 Wake Up 地震預警</b>

🏠 所在地區：<b>台北市</b>
📍 所在地震度：<b>5+</b>
...
```

看到這段就代表設定檔讀得到、格式正確，`$LASTEXITCODE` 應該是 `0`。四步都過，接著第二章。

---

## 二、接上地牛 Wake Up

| # | 動作 |
|---|---|
| 1 | 地牛 Wake Up  → 設定 → 進階 → 連動設定 |
| 2 | 註冊地牛 Wake Up 帳號 |
| 3 | 勾選「收到警報且符合預警震度後執行程式」 |
| 4 | 瀏覽，選擇 `earthdragon-wakeup_telegram.cmd` |
| 5 | 勾選「僅執行一次」，避免同一筆預警重複通知 |

### 為什麼只能選 `.cmd`

連動設定吃的是可執行檔，`.ps1` 不是。`.cmd` 只做一件事：用正確的旗標把 `.ps1` 叫起來。

```bat
powershell.exe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0earthdragon-wakeup_telegram.ps1" %*
```

`-ExecutionPolicy Bypass` 讓執行原則的設定不會擋住這支程式；`-NoProfile` 避免使用者的 PowerShell 設定檔干擾。

### 參數實際長什麼樣

地牛 Wake Up 接在程式後面，不加引號：

```text
earthdragon-wakeup_telegram.cmd --epicenter-lat=23.85 --epicenter-lon=120.82 --depth=10 --magnitude=7.3 ...
```

`cmd.exe` 把未加引號的 `=` 當參數分隔符，所以進到程式時可能是這兩種形狀之一：

```text
--epicenter-lat=23.85     ← 原樣
--epicenter-lat 23.85     ← 被 = 切開
```

主程式兩種都收，不必手動處理。

### 版本差異

地牛 Wake Up  4.1.x 期間曾停止傳遞「所在地預估震度」與「震波抵達秒數」。缺這兩項時，訊息對應欄位顯示「未提供」，其餘照送；換到有傳遞的版本就自動補上。

---

## 三、設定檔逐項

`KEY='value'` 一行一項，UTF-8 編碼（有無 BOM 都可）。位置不寫死，執行時依序找，第一個存在的就採用：

| 順序 | 位置 | 用途 |
|---|---|---|
| 1 | 環境變數 `DINIU_TELEGRAM_CONFIG` | 強制指定，永遠優先 |
| 2 | `<程式資料夾>\.config\earthdragon-wakeup_telegram.conf` | 整包放哪就跑哪，最省事 |
| 3 | `<程式資料夾>\earthdragon-wakeup_telegram.conf` | 設定檔與程式放一起 |
| 4 | `%USERPROFILE%\.config\earthdragon-wakeup_telegram.conf` | 安裝到 `Scripts\` 時的慣例位置 |
| 5 | `%APPDATA%\earthdragon-wakeup_telegram\earthdragon-wakeup_telegram.conf` | 多使用者共用程式時 |

日誌會印出實際載入哪一個；全都找不到時，會把搜過的路徑列出來，不會只丟一句「找不到」。

值裡面的 `$HOME` **不會**被展開，要寫完整路徑。

### Telegram

| 鍵 | 預設 | 說明 |
|---|---|---|
| `TELEGRAM_BOT_TOKEN` | 必填 | BotFather 發的 Token |
| `TELEGRAM_CHAT_IDS` | 必填 | 逗號、分號、空白或換行分隔；也接受舊鍵 `TELEGRAM_CHAT_ID` |
| `TELEGRAM_MESSAGE_THREAD_ID` | 空 | Forum Topic 的 topic id；私人聊天與一般群組留空 |
| `TELEGRAM_DISABLE_NOTIFICATION` | `false` | 文字警報是否靜音 |
| `TELEGRAM_MAP_DISABLE_NOTIFICATION` | `true` | 地圖圖片是否靜音（建議保持 true，避免響兩次） |
| `TELEGRAM_PROTECT_CONTENT` | `false` | 禁止轉傳與儲存 |
| `TELEGRAM_MAX_TIME` | `20` | 整體逾時（秒） |
| `TELEGRAM_CONNECT_TIMEOUT` | `10` | 相容保留。`HttpWebRequest` 沒有獨立連線逾時，實際以 `TELEGRAM_MAX_TIME` 為上限 |
| `TELEGRAM_API_BASE` | `https://api.telegram.org` | 只有在走自架 Proxy 或測試伺服器時才改 |

### 顯示

| 鍵 | 預設 | 說明 |
|---|---|---|
| `ALERT_LOCATION` | 必填 | 收警報的人所在位置，只出現在文字警報 |
| `ALERT_TIMEZONE` | `Asia/Taipei` | 會自動對應成 Windows 的 `Taipei Standard Time` |
| `LOG_FILE` | 空 | 日誌檔完整路徑；無人值守時建議設定 |

### Geoapify 與地圖

| 鍵 | 預設 | 說明 |
|---|---|---|
| `GEOAPIFY_API_KEY` | 空 | 沒填就只送文字，地圖整段略過 |
| `MAP_ENABLED` | `true` | 關閉後完全不產生地圖 |
| `MAP_STYLE` | `osm-bright` | Geoapify 樣式名稱 |
| `MAP_LANG` | `zh` | 地圖標籤語言 |
| `MAP_WIDTH` / `MAP_HEIGHT` | `900` | 像素，上限 4096 |
| `MAP_SCALE_FACTOR` | `1` | `2` 為高解析度，API 用量與檔案大小都會增加 |
| `MAP_MAX_TIME` | `30` | 地圖下載逾時（秒） |
| `MAP_CONNECT_TIMEOUT` | `10` | 同上，相容保留 |
| `GEOAPIFY_MAP_BASE` | `https://maps.geoapify.com` | 選用 |
| `GEOAPIFY_GEOCODE_BASE` | `https://api.geoapify.com` | 選用 |

### 反向地理編碼

| 鍵 | 預設 | 說明 |
|---|---|---|
| `REVERSE_GEOCODING_ENABLED` | `true` | 依震央座標查縣市／行政區 |
| `REVERSE_GEOCODING_LANG` | `zh` | 地名語言 |
| `REVERSE_GEOCODING_MAX_TIME` | `15` | 逾時（秒） |
| `REVERSE_GEOCODING_CONNECT_TIMEOUT` | `10` | 同上，相容保留 |

### 地圖範圍與標記

一般不需要動。腳本以台灣為基礎範圍，再往外擴到震央。

| 鍵 | 預設 | 說明 |
|---|---|---|
| `MAP_TAIWAN_WEST` / `EAST` / `NORTH` / `SOUTH` | `119.0` / `123.0` / `26.0` / `21.5` | 基礎框 |
| `MAP_PADDING` | `0.35` | 邊緣留白（經緯度） |
| `MAP_MARKER_COLOR` | `#e53935` | 標記底色 |
| `MAP_MARKER_STROKE_COLOR` | `#8b0000` | 標記外框 |
| `MAP_MARKER_CONTENT_COLOR` | `#ffffff` | 標記文字色 |
| `MAP_MARKER_SIZE` | `72` | 標記像素高 |
| `MAP_MARKER_CONTENT_SIZE` | `34` | 標記內文字像素 |

### 多個群組、不同 Topic

`TELEGRAM_MESSAGE_THREAD_ID` 是全域的，所有 Chat ID 共用。要分開就拆成多個設定檔，各自指定：

```console
$env:DINIU_TELEGRAM_CONFIG = "$HOME\.config\diniu-group-a.conf"
```

### 檔案權限

設定檔裡有 Token 與 Key，建議只留給目前使用者：

```console
icacls "$HOME\.config\earthdragon-wakeup_telegram.conf" /inheritance:r /grant:r "$($env:USERNAME):(R,W)"
```

---

## 四、參數與訊息對照

官方目前提供 8 個參數。

| 參數 | 說明 | 範例 | 訊息中的位置 |
|---|---|---|---|
| `--epicenter-lat` | 震央緯度 | `23.85` | 🌐 震央座標、地圖範圍、Google Maps 連結 |
| `--epicenter-lon` | 震央經度 | `120.82` | 同上 |
| `--magnitude` | 規模 | `7.3` | 📏 地震規模 |
| `--depth` | 深度（公里） | `10` | 🌊 震源深度 |
| `--max-intensity` | 最大震度 | `7` | 📊 最大震度 |
| `--local-intensity` | 所在地震度 | `5+` | 📍 所在地震度、標題圖示 |
| `--arrival-time` | 抵達時間（Unix 時間戳） | `1717142400` | ⏰ 預計抵達 |
| `--remaining-time` | 多久後抵達（秒） | `20` | ⏳ 剩餘時間 |

官方範例：

```text
--epicenter-lat=23.85 --epicenter-lon=120.82 --magnitude=7.3 --depth=10 --max-intensity=7 --local-intensity=5+ --arrival-time=1717142400 --remaining-time=20
```

幾個實測過的邊界：

| 情況 | 行為 |
|---|---|
| 任一參數缺少 | 該欄位顯示「未提供」，不做單位拼接，其餘照送 |
| 經緯度缺漏或非數字 | 跳過地圖與連結，文字警報照送 |
| 震度 `0`～`7`、`5+`、`5-`、`6+`、`6-` | 全部解析；圖示對應 `🌏`、`🟡`、`🟠`、`⚠️`、`🚨` |
| 13 位數毫秒時間戳 | 自動換算，結果與 10 位數相同 |
| 參數表以外的未知參數 | 忽略，日誌記一行 `忽略無法識別的參數：...` |

### 文字警報長這樣

```text
⚠️ 地牛 Wake Up 地震預警

🏠 所在地區：台北市
📍 所在地震度：5+
📊 最大震度：7
📏 地震規模：M7.3
🌊 震源深度：10 公里

🌐 震央座標：23.85, 120.82
⏰ 預計抵達：2026-07-26 11:45:30
⏳ 剩餘時間：20 秒

⚡️ 就近掩護，牢記「趴下、掩護、穩住」

🕒 收到時間：2026-07-26 11:45:10
🗺 開啟互動式震央地圖
```

### 地圖說明長這樣

```text
🗺 震央位置示意

📌 震央附近：南投縣 魚池鄉
📍 震央座標：23.85, 120.82
📏 地震規模：M7.3
🌊 震源深度：10 公里
```

「震央附近」是拿經緯度回頭查的行政區，查不到就整行省略——不會拿 `ALERT_LOCATION` 冒充震央。

---

## 五、症狀排查

| 症狀 | 先查 | 怎麼確認 |
|---|---|---|
| 日誌出現「找不到設定檔」 | 設定檔放在哪 | 放進 `<程式資料夾>\.config\`，或設 `DINIU_TELEGRAM_CONFIG`；日誌會列出搜過的路徑 |
| 完全沒收到訊息 | Token、Chat ID、Bot 是否在群組／頻道管理員 | `Invoke-RestMethod "https://api.telegram.org/bot<TOKEN>/getMe"` |
| 只有文字，沒有地圖 | `MAP_ENABLED`、`GEOAPIFY_API_KEY`、額度 | 看日誌有沒有 `略過震央地圖` |
| 有地圖，沒有「震央附近」 | `REVERSE_GEOCODING_ENABLED`、Geoapify 回傳內容 | 看日誌 `未回傳可用地名` |
| 時間差 8 小時 | `ALERT_TIMEZONE`、系統時鐘 | 試跑一次比對 `預計抵達` |
| 中文變亂碼或直接語法錯誤 | `.ps1` 是否為 UTF-8 with BOM | 用 VS Code 看右下角編碼 |
| 「已停用指令碼執行」 | 是不是直接雙擊 `.ps1` | 改走 `.cmd`，或加 `-ExecutionPolicy Bypass` |
| 連線失敗 | 日誌錯誤類型 | `TrustFailure` / `ConnectFailure` / `Timeout` / `NameResolutionFailure` 各自對應不同原因 |
| 地牛 Wake Up 已連動但沒動靜 | 連動是否勾選、路徑是否還在 | 設 `LOG_FILE` 後手動跑一次 `.cmd` |

### 編碼問題

Windows PowerShell 5.1 讀沒有 BOM 的 `.ps1` 時，會用系統 ANSI 碼頁解讀，中文字串直接爆掉，錯誤訊息還可能指向莫名其妙的地方。改檔案請維持 `UTF-8 with BOM`，記事本另存時選「UTF-8」，不要選「ANSI」。

### 連線問題

`TrustFailure` 幾乎都是企業 Proxy 或防毒軟體攔截 HTTPS；`Timeout` 是超過 `TELEGRAM_MAX_TIME`／`MAP_MAX_TIME`。程式預設跟隨系統 Proxy（Internet 選項），要繞過就把 `TELEGRAM_API_BASE`、`GEOAPIFY_MAP_BASE`、`GEOAPIFY_GEOCODE_BASE` 指到自架端點。

### 地牛 Wake Up 沒有任何反應

依序確認：

1. 連動設定的勾選還在（地牛 Wake Up 更新後偶爾會被重置）
2. `.cmd` 與 `.ps1` 放在同一個資料夾——`.cmd` 是用自己所在目錄去找 `.ps1` 的
3. 路徑沒有被 OneDrive 之類的同步機制搬走
4. 設了 `LOG_FILE`，手動執行 `.cmd`，看日誌停在哪一行
5. 預警震度門檻沒有設得比平常地震還高

---

## 六、附錄

### A. 指令速查

| 目的 | 指令 |
|---|---|
| 試跑（不送出） | `powershell -NoProfile -ExecutionPolicy Bypass -File .\earthdragon-wakeup_telegram.ps1 --dry-run --epicenter-lat=23.85 --epicenter-lon=120.82 --magnitude=7.3 --depth=10 --max-intensity=7 --local-intensity=5+ --arrival-time=1717142400 --remaining-time=20` |
| 真的送一次 | 同上，去掉 `--dry-run` |
| 走地牛 Wake Up 同一條路徑 | `& "$HOME\Scripts\earthdragon-wakeup_telegram.cmd" --epicenter-lat=23.85 --epicenter-lon=120.82 --magnitude=7.3` |
| 看說明 | 同第一列，把 `--dry-run` 換成 `--help` |
| 換設定檔 | `$env:DINIU_TELEGRAM_CONFIG = "C:\path\to\other.conf"` |

結束碼只有兩種：

| 值 | 意思 |
|---|---|
| `0` | 文字警報全部送達（地圖失敗仍算 0）；`--dry-run`、`--help` 也是 0 |
| `1` | 設定缺漏、參數錯誤，或任一 Chat ID 的文字警報失敗 |

### B. 申請 Token 與 Key

**Telegram Bot** — Telegram 搜 `@BotFather` → `/newbot` → 照指示命名 → 取得 `123456789:AAH...` 這串。Bot 要加入目標群組；發頻道則需設為管理員。

**Chat ID** — 先對 Bot 傳一句話，再開 `https://api.telegram.org/bot<TOKEN>/getUpdates`，找 `chat":{"id":...}`。群組與頻道是負數，超級群組與頻道常見 `-100` 開頭。

**Geoapify** `https://www.geoapify.com/` — 註冊 → 建 Project → 建 API Key。免費用戶有每日額度，靜態地圖會自動保留資料來源標示。

### C. 離線測試

專案附一組端對端測試，不需要任何 Token：

```console
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\run-tests.ps1
```

涵蓋 52 項斷言（現況快照）：語法與編碼、試跑輸出、兩個 Chat ID 的完整流程、UTF-8 表單編碼、multipart 圖片完整性、反向地理編碼去重、單一 Chat ID 失敗時的隔離與結束碼、Forum Topic、多行 Chat ID、毫秒時間戳、設定檔自動搜尋（同層 `.config`、環境變數優先）。

之所以算「離線」：`tests/mock-server.ps1` 會在本機開一個 TCP 監聽，代替 Telegram 與 Geoapify 回應，並把收到的每個請求存成檔案供斷言比對。整個過程不解析 DNS、不對外連線、不送出任何訊息。

測試工具會在執行期間把主控台輸出編碼切換為 UTF-8（結束後還原），所以繁中 Windows 的 CP950 主控台也能正確比對中文；若環境不允許切換，會直接印出提示，而不是讓一堆中文斷言默默失敗。

### D. 設計取捨

| 決策 | 原因 |
|---|---|
| 自組 request body，不用 `Invoke-WebRequest` | PowerShell 5.1 對表單與 multipart 的非 ASCII 編碼不一致，容易送出亂碼 |
| 用 `HttpWebRequest` | 可分別設定整體逾時與讀寫逾時，5.1 與 7 行為一致 |
| 設定檔只解析、不 dot-source | 設定檔是資料不是程式；順帶讓既有 `.conf` 原封不動沿用 |
| 不自動重試 | 預警分秒必爭，重試可能延後或重複送出；失敗只記日誌 |
| 震央地圖失敗不影響文字警報 | 文字警報為核心通知，震央地圖為視覺輔助 |

### E. 免責

- 非官方專案，與地牛 Wake Up、Telegram、Geoapify 無隸屬關係。
- 預警可能因網路、裝置、資料來源或第三方 API 而延遲。
- 本工具是輔助通知，不能取代政府災防告警與現場判斷。
- 收到警報請依「趴下、掩護、穩住」就地避難。

---

`earthdragon-wakeup_telegram.ps1` 1.0.0 ｜ Windows PowerShell 5.1 
