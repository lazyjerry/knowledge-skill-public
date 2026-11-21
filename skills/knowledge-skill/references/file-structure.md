# 檔案結構詳細說明

## 目錄結構

任務資料夾留在**各專案內**；知識庫是**跨專案共用**，放在工作區外的全域路徑。

```
# 專案內（每個專案各自一份）
[工作區根目錄]/
└── docs/                              # 尋找現有或建立
    └── knowledge-skill/                           # 確認或建立
        └── [任務名稱]-[流水號]/        # 任務資料夾
            ├── prompt.md             # 使用者提示詞
            ├── task_plan.md          # 任務計劃
            ├── notes.md              # 研究筆記
            └── report-<任務名稱英文>.md  # 最終交付物

# 全域（所有專案共用，預設 ~/.knowledge-skill/，可用 KNOWLEDGE_BASE_DIR 覆寫）
$KNOWLEDGE_BASE_DIR/                   # 預設 $HOME/.knowledge-skill/knowledge/
├── index.md                          # 頂層索引（必須）：只列分類目錄與各分類知識標題
├── ui/ ux/ dev/ ops/ data/ else/     # 分類目錄（第二層依語言/框架）
│   └── {語言-框架}/
│       ├── index.md                  # 分類子索引：完整六欄清單（含創建／更新時間），連結相對本目錄
│       └── [topic].md                # MADR 格式知識檔
└── deprecated/                       # 已停用（被取代）的知識，結構同上
    ├── index.md                      # 停用頂層索引（分類目錄）
    └── {鏡像分類路徑}/
        ├── index.md                  # 停用分類子索引
        └── [topic].md                # 停用知識（保留原分類路徑）
```

> 知識檔格式與規範以 `references/knowledge-base.md` 為單一來源。

## 目錄探測流程

```bash
# 1. 解析公用知識庫路徑（環境變數 KNOWLEDGE_BASE_DIR > 設定檔 ~/.config/knowledge-skill/config > 預設 $HOME/.knowledge-skill/knowledge）
# 2. 驗證該路徑可讀寫（實際寫入探針檔測試）
#    - 可寫 → 建立目錄、若無 index.md 則由範本建立
#    - 不可寫 → 印出三個路徑選項並 exit 2，交由使用者選擇後重跑（重跑會重新驗證）
# 3. 從工作區根目錄開始
# 4. 確認 docs/knowledge-skill/ 資料夾（若無則建立）
# 5. 建立任務資料夾
```

### 知識庫路徑無法讀寫時的選項（腳本 exit 2）

工作區外的全域路徑可能被權限或沙盒阻擋。腳本驗證失敗時印出三選項；代理依 `references/rules.md` 的原生互動選單路由呈現，工具不可用才退回文字編號：

| 選項 | 動作 | 說明 |
|------|------|------|
| 1 | 維持原路徑，先開權限 | 依目前 AI 工具開啟存取（Claude Code `additionalDirectories`／Codex `writable_roots`／Antigravity `--add-dir`／Copilot OS 權限），再重跑相同指令 |
| 2 | 改用專案內路徑 | `<工作區>/docs/knowledge-skill/knowledge`，必定可寫，但知識庫退回單一專案、不跨專案共用 |
| 3 | 指定其他路徑 | 以 `KNOWLEDGE_BASE_DIR="<路徑>"` 重跑 |

> 重跑都會重新驗證；仍不可寫則再次出選項，直到成功（exit 0）。

## 任務命名規則

任務資料夾使用 `[票號-]任務名稱-[流水號]` 格式（票號為選填前綴）。

### 命名四原則

1. **任務名稱使用繁體中文**，簡短描述任務目的，例如 `AI_工具記憶優化`。
2. **票號/編號作為前綴**：任務開始前於「啟動提問」依原生互動選單路由詢問。先嘗試從 git 分支、目錄或上下文**推斷**票號，再提供選項：〔推斷票號：`<推斷值>`〕／沒有票號／自行輸入票號（如 Jira、GitHub Issue、工單號）。
   - 有（推斷或自行輸入）→ 以 `票號-任務名稱` 組合，例如 `T-0001-AI_工具記憶優化`。
   - 無 → 直接使用任務名稱，例如 `AI_工具記憶優化`。
3. **空格與特殊符號一律以底線 `_` 取代**，避免資料夾或檔案名稱損毀。
   - 區段分隔符 `-`（票號／任務名稱／流水號之間）保留，不取代。
   - 各區段「內部」的空格與特殊符號才轉為 `_`。
4. **報告英文名稱（slug）另外決定**，作為報告檔名 `report-<slug>.md`，見下方「報告英文名稱」。

### 字元轉換規則

| 原始輸入 | 轉換後 | 說明 |
|----------|--------|------|
| 空格 ` ` | `_` | `AI 工具記憶優化` → `AI_工具記憶優化` |
| `/ \ : * ? " < > \|` 等檔名禁用字元 | `_` | `登入/登出 修復` → `登入_登出_修復` |
| 連續多個底線 | 合併為單一 `_` | `A__B` → `A_B` |
| 票號內部的空格 | `_` | `T 0001` → `T_0001` |

> ⚠️ **重要**：組合完成的最終名稱會原樣傳入 `init-session.sh` 並接上 `-[流水號]`。
> 若名稱含空格或特殊符號，會導致流水號計算（glob 比對）與資料夾建立失敗，務必先完成轉換再傳入腳本。

### 命名範例

| 票號 | 原始任務名稱 | 最終任務資料夾 |
|------|--------------|----------------|
| `T-0001` | `AI 工具記憶優化` | `T-0001-AI_工具記憶優化-001` |
| 無 | `API 重構` | `API_重構-001` |
| `ISSUE-42` | `修復 登入/登出 流程` | `ISSUE-42-修復_登入_登出_流程-001` |

### 報告英文名稱

報告檔名為 `report-<slug>.md`。同一專案累積多個任務資料夾時，檔名自帶語意才分得出內容。

slug 由代理在決定中文任務名稱時**同步翻譯**產生，不另外詢問使用者，格式為網址式 kebab-case：

| 規則 | 說明 |
|------|------|
| 允許字元 | 小寫英文 `a-z`、數字 `0-9`、連字號 `-` |
| 連字號位置 | 不可置於開頭或結尾，也不可連續兩個以上 |
| 大小寫 | 一律小寫；不使用底線 `_`（與任務資料夾名稱的規則不同） |
| 正規表示式 | `^[a-z0-9]+(-[a-z0-9]+)*$` |

| 中文任務名稱 | slug | 報告檔名 |
|--------------|------|----------|
| `AI_工具記憶優化` | `ai-memory-optimization` | `report-ai-memory-optimization.md` |
| `API_重構` | `api-refactor` | `report-api-refactor.md` |
| `修復_登入_登出_流程` | `login-logout-flow-fix` | `report-login-logout-flow-fix.md` |

> ⚠️ slug 作為第三個參數傳入 `init-session.sh`，格式不符會 `exit 1`。
> 腳本本身不建立報告檔（報告是任務完成時的交付物），但會印出完成時要用的檔名；
> 該檔名需寫進 `task_plan.md` 的「報告檔名」區塊，分階段任務跨 session 續作時才不會取到不同名字。

### 流水號規則

| 情境 | 命名方式 | 範例 |
|------|----------|------|
| 新任務 | `任務名稱-001` | `AI_工具記憶優化-001` |
| 同 session 相同目的 | 沿用現有資料夾 | `AI_工具記憶優化-001` |
| 同 session 不同目的 | 建立新任務 | `登入_修復-001` |
| 不同 session 相同任務 | 遞增流水號 | `AI_工具記憶優化-002` |

## 任務資料夾內容

| 檔案 | 用途 | 更新時機 |
|------|------|----------|
| `prompt.md` | 使用者的提示詞 | 任務開始前 |
| `task_plan.md` | 追蹤階段與進度 | 每階段完成後 |
| `notes.md` | 儲存發現與研究 | 研究過程中 |
| `report-<slug>.md` | 最終交付物；slug 見「報告英文名稱」，開頭帶 YAML meta（見「報告 YAML meta」） | 任務完成時；再次變更以最後結論改寫（見 [`rules.md`](rules.md) 的「報告改寫規範」） |

### 必要檔案清單

任務完成時必須包含以下檔案，此清單供 `validate-task-completion.sh` 腳本驗證使用：

```bash
# 腳本參數：固定檔名的必要檔案清單
REQUIRED_FILES="prompt.md task_plan.md notes.md"

# 報告檔名不固定，改以 glob 找出候選再驗證命名
REPORT_PATTERN='^report-[a-z0-9]+(-[a-z0-9]+)*\.md$'
```

報告檔的判定條件：`report-*.md` 恰好一份、檔名符合 `REPORT_PATTERN`、且內容非空。
找不到時若偵測到舊格式的 `report.md`，腳本會額外提示改名。

> 📌 若需新增或移除必要檔案，請同步更新 `scripts/validate-task-completion.sh` 中的 `REQUIRED_FILES` 變數；
> 報告命名規則另有 `knowledge-tools-skill/scripts/kb-consolidate.sh` 使用同一份 `REPORT_PATTERN`，改動要一併確認。

### 報告 YAML meta

`report-<slug>.md` 第一行起是 YAML front matter，只有報告帶，`prompt.md`／`task_plan.md`／`notes.md` 不帶。值在「啟動提問」取得後先寫進 `task_plan.md` 的「報告 meta」區塊（分階段任務跨 session 才取得到同一組值），建立報告時原樣複製到報告開頭：

```yaml
---
日期: YYYY-MM-DD
作者: <作者>
遠端連結:
票號: <票號>
執行模式: <一次完成／分階段執行／部分執行>
研究計畫確認: <先確認／不先確認>
---
```

| 欄位 | 值 |
|------|----|
| `日期` | 報告首次建立日；之後依「報告改寫規範」改寫內文時不變動 |
| `作者` | 啟動提問第五題的選擇，預設取工作區的 `git config user.name` |
| `遠端連結` | 一律留空，報告同步到遠端（Notion、Confluence 等）後由使用者自行填入 |
| `票號` | 啟動提問第一題的票號；選「沒有票號」時留空 |
| `執行模式` | 啟動提問第二題的選擇 |
| `研究計畫確認` | 啟動提問第四題的選擇 |

報告保存路徑（第三題）不寫入 meta：報告本身就在該路徑下，且會帶出裝置路徑。

`validate-task-completion.sh` 會檢查報告第一行為 `---`，且上述六個欄位都存在（`遠端連結`、`票號` 可為空值）。

## 範本檔案

所有範本位於 `assets/` 目錄：

| 範本檔案 | 用途 |
|----------|------|
| [assets/prompt.md](../assets/prompt.md) | 任務請求範本 |
| [assets/task_plan.md](../assets/task_plan.md) | 任務計劃範本 |
| [assets/notes.md](../assets/notes.md) | 研究筆記範本 |
| [assets/knowledge-index.md](../assets/knowledge-index.md) | 知識庫頂層索引範本 |
| [assets/knowledge-category-index.md](../assets/knowledge-category-index.md) | 知識庫分類子索引範本 |
| [assets/knowledge.md](../assets/knowledge.md) | 知識檔案範本 |

## 知識庫結構

公用知識庫位於全域路徑（預設 `$HOME/.knowledge-skill/knowledge/`，可用 `KNOWLEDGE_BASE_DIR` 覆寫），所有專案共用，知識檔依分類目錄歸檔，並以 MADR 格式記錄。

> **完整規範（分類、MADR 欄位、收錄判準、覆蓋／停用機制、索引流程）以 [`knowledge-base.md`](knowledge-base.md) 為單一來源。** 以下僅列重點。

- **分類目錄**：頂層 `ui` / `ux` / `dev` / `ops` / `data` / `else`，第二層依語言／框架（如 `dev/php-laravel/`）。
- **索引分兩層**：頂層 `index.md` 只有 `分類` / `筆數` / `知識標題`；完整的 `觸發時機` 與 `摘要` 在各分類的 `{分類}/index.md`，第一欄連結相對該分類目錄。讀取時逐層下探，不要一次讀完整棵樹。
- **停用索引** `deprecated/` 下為同構的兩層，子索引欄位多一欄 `被取代於`。
- 索引一律由 `kb-reindex.sh` 重建，**代理不手動編輯**。

### 範本檔案（canonical，集中於本 skill 的 `assets/`）

| 範本 | 用途 |
|------|------|
| [assets/knowledge.md](../assets/knowledge.md) | MADR 知識檔範本 |
| [assets/knowledge-index.md](../assets/knowledge-index.md) | 生效頂層索引範本（分類目錄） |
| [assets/knowledge-category-index.md](../assets/knowledge-category-index.md) | 生效分類子索引範本 |
| [assets/knowledge-deprecated-index.md](../assets/knowledge-deprecated-index.md) | 停用頂層索引範本 |
| [assets/knowledge-deprecated-category-index.md](../assets/knowledge-deprecated-category-index.md) | 停用分類子索引範本 |

