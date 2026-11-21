# 操作規則：1 檢查／2 整理索引／3 重置／4 刪除／5 整理知識內容／6 匯入／7 晉升／8 內容健康檢查／9 注入與更新注入區塊／10 自動修復／11 跨位置同步

所有腳本位於 `scripts/`，以 `kb-tools.sh` 為單一進入點分派。人類可用無參數 TTY 選單；代理一律用 `kb-tools.sh menu` 取得資料後，以 `AskUserQuestion`／`request_user_input` 呈現原生選單。選單編號與命令名仍一一對應，保留文字 fallback。知識庫位置依序取環境變數 `KNOWLEDGE_BASE_DIR` > 設定檔 `~/.config/knowledge-skill/config` 的 `KNOWLEDGE_BASE_DIR=` > 預設 `$HOME/.knowledge-skill/knowledge`（皆指向 knowledge 目錄本身）。解析邏輯以 `kb-resolve-dir` 區塊逐字內嵌在每支腳本（部分腳本會被其他工具單檔內嵌，無法共用 lib），改動後執行 `sh scripts/test-kb-resolve-dir.sh` 確認各份一致。

知識檔以 MADR 格式、依分類目錄（`ui`/`ux`/`dev`/`ops`/`data`/`else`，第二層依語言/框架）遞迴存放；索引登錄**相對 knowledge/ 的路徑**。知識格式與覆蓋／停用機制的完整規範以 `knowledge-skill/references/knowledge-base.md` 為單一來源。範本（`knowledge.md`、`knowledge-index.md`、`knowledge-deprecated-index.md`）集中於 `knowledge-skill/assets/`，本 skill 腳本以相對路徑指向。

## 子命令對照

| 編號 | 子命令 | 腳本 | 改檔 | 說明 |
|------|--------|------|------|------|
| - | `menu` | `kb-tools.sh menu` | 否 | 只印出主選單，永不讀取 stdin，供代理路由 |
| 1 | `status` | `kb-status.sh` | 否 | 解析位置 + 健康檢查（含 deprecated/ 回報、舊單層索引提示） |
| 2 | `reindex` | `kb-reindex.sh` | 是 | 遞迴依知識檔內容重建生效與停用的**兩層**索引（頂層分類目錄 + 各分類子索引）；缺 `index.md` 但六個分類目錄齊全時直接重建，並把各層索引標記為 Dropbox 忽略（macOS）；子索引的創建時間從舊索引沿用、更新時間取 mtime（規則見 `knowledge-base.md` 七） |
| 3 | `reset [--yes]` | `kb-reset.sh` | 是 | 備份壓縮後清空並重建分類骨架與空索引 |
| 4 | `delete [編號/相對路徑] [--yes]` | `kb-delete.sh` | 是 | 列出條目並刪除指定單一知識檔，刪後 reindex |
| 5 | `curate` | `kb-tools.sh curate` | 否 | 印出沉澱／盤點／取代三個子步驟導引 |
| 5-1 | `consolidate [路徑]` | `kb-consolidate.sh` | 否 | 任務資料夾格式檢查 + 候選列舉 |
| 5-1b | `new <相對路徑> [--out <草稿路徑>]` | `kb-new.sh` | 否 | 從 canonical 範本產生知識草稿；預檢路徑合法性與目標是否已存在 |
| 5-2 | `reconcile [分類前綴]` | `kb-reconcile.sh` | 否 | 列出生效知識供比對新舊矛盾 |
| 5-3 | `supersede <舊> <新> [--yes]` | `kb-supersede.sh` | 是 | 以新知識取代舊知識、停用舊檔後 reindex |
| 6 | `import <tool> [來源]` | `kb-import.sh`（分派 `kb-import-<tool>.sh`） | 預設否 | read-only 匯入 vendor memory 為候選；`--write` 才落地 |
| 7 | `promote <候選> <相對路徑> [--yes]` | `kb-promote.sh` | 是 | 把審核通過的候選 MADR 安裝成生效知識後 reindex |
| 8 | `health [--format text\|json] [--source ...]` | `kb-health.sh` | 僅 log | 檢查 MADR 內容，保存最新快照與 JSONL 歷史 |
| 9 | `injection [list [目標路徑]\|inject <檔案路徑> [--create] [--yes]\|update <檔案路徑> [--yes]]` | `kb-injection.sh` | inject、update 才改檔 | 首次注入或更新各 AI 指令檔的共用知識庫注入區塊，改前自動備份 |
| 10 | `repair [--dry-run] [--yes] [相對路徑...]` | `kb-repair.sh` | 是 | 修復健康檢查中修法唯一的問題（取代關係互惠、關係欄位），改前備份，收尾 reindex |
| 11 | `sync <pull\|push> <路徑> [--dry-run] [--overwrite] [--yes]` | `kb-sync.sh` | 是 | 與指定位置的知識庫單向搬運知識檔（只新增不刪除），收尾在接收端 reindex |
| 12 | `setup [--dry-run] [--yes]` | `kb-ensure-setup.sh` | 是 | 把舊版寫在 `~/.zshrc`／`~/.zshenv`／`~/.bashrc`／`~/.profile` 的 `KNOWLEDGE_BASE_DIR` 搬到設定檔並從 rc 移除（改前備份），再確保知識庫目錄、六個分類目錄與 `index.md` 齊全（新裝置一次建好，缺索引時呼叫 `kb-reindex.sh`）。值無法靜態解析、與設定檔衝突，或知識庫位置落在暫存區時不動（結束碼 `2`）；建立或重建失敗為結束碼 `1`。供升級腳本每次執行，已是現行狀態時不改檔 |

## 代理原生選單路由

1. 執行 `sh kb-tools.sh menu` 取得十二項功能。
2. 以最多三個選項的兩層原生選單分派：檢查與索引／維護與設定／知識內容與候選。
3. 原生工具可用時不得要求輸入數字或命令名；不可用時才把 script 編號清單作為文字 fallback。
4. 無上限清單逐筆詢問「選擇此項／下一項／取消」。
5. `reset`、`delete`、`injection inject`、`injection update`、`supersede`、`promote` 由代理先取得原生確認，之後才帶 `--yes`。
6. 自訂路徑、分類、檔名與相對目標路徑可使用自由文字。

`kb-tools.sh` 無參數與各破壞性 script 的 TTY `yes` prompt 保留給人類直接使用，不作為代理入口。

## 功能 1：檢查（kb-status.sh）

唯讀。輸出知識庫位置來源（環境變數／設定檔／預設）、絕對與顯示路徑，並逐項檢查：

- knowledge 目錄是否存在
- `index.md` 是否存在
- **斷鏈**：`index.md` 登錄的相對路徑、但檔案不存在
- **孤兒檔**：遞迴掃描（排除 `index.md` 與 `deprecated/` 子樹）存在、但索引未登錄
- 生效知識檔數量、`deprecated/` 已停用知識檔數量

索引解析：以 `awk -F'|'` 取表格第一欄的**連結目標**（括號內 `(相對路徑)`），跳過表頭（`知識`／`檔案`）、分隔列、空白列與 `<!--` 註解列，並去除反引號。

### 結束碼

| 碼 | 意義 |
|----|------|
| 0 | 健康且一致 |
| 1 | 結構缺失（無目錄或無 `index.md`） |
| 2 | 有斷鏈、孤兒檔，或索引仍是舊的單層結構 |

## 功能 8：內容健康檢查（kb-health.sh）

`sh kb-health.sh [--format text|json] [--source cli|tray|ui]`。知識內容唯讀，但會保存檢查紀錄。

- 索引結構：頂層索引若仍直接登錄知識（舊的單層全量索引），回報 `index_single_tier`，動作為 `reindex`。索引解析對單層刻意向後相容，不靠這個 finding 就完全沒有徵兆——停在舊結構、或被落後版本的 `kb-reindex.sh` 寫回單層，都要能被指出來。
- 生效知識：檢查允許分類、索引／磁碟一致、索引欄位與來源一致、四個 front matter 欄位、九個 MADR 標準段落、非範本內容及互惠取代關係。
- 停用知識：只檢查鏡像分類、索引／磁碟一致、索引欄位及 `被取代於` 的互惠關係，不要求歷史頁補齊現行 MADR。
- 結構化輸出 schema version 為 `1`，包含 `run_id`、`checked_at`、`source`、`healthy`、`counts` 與 `findings[]`。
- log：`$HOME/.knowledge-skill/logs/health/latest.json` 原子覆寫，`history.jsonl` append-only；目錄 `0700`、檔案 `0600`。
- 結束碼：`0` 健康；`1` 執行／結構錯誤；`2` 檢查成功但發現不健康項目。

## 健康檢查 code → 修法對照

`kb-health.sh` 的每個 finding 都帶 `actions`，代理與 UI 依它決定入口。三群的修法性質不同：

### A 群：索引與磁碟一致性 — `reindex` 可全自動修復

| code | 觸發條件 | 修法 |
|------|----------|------|
| `index_single_tier` | 頂層 `index.md` 仍登錄含 `/` 的知識路徑（舊單層結構） | `reindex` |
| `broken_link` | 生效索引有登錄但檔案不存在 | `reindex` |
| `orphan_file` | 檔案存在但生效索引未登錄 | `reindex`；確認是垃圾檔才 `delete` |
| `deprecated_index_missing` | 有停用檔卻缺 `deprecated/index.md` | `reindex` |
| `deprecated_broken_link` | 停用索引登錄但檔案不存在 | `reindex` |
| `deprecated_orphan_file` | 停用檔存在但停用索引未登錄 | `reindex` |
| `index_title_stale` | 索引標題 ≠ front matter `標題` | `reindex` |
| `index_trigger_stale` | 索引觸發時機 ≠ front matter `觸發時機` | `reindex` |
| `index_summary_stale` | 索引摘要 ≠ `## 摘要` 第一行 | `reindex` |

> 索引欄位裡的 `|` 會打斷 Markdown 表格，`kb-reindex.sh` 的 `parse_fields` 一律把它換成 `/`。
> `kb-health.sh` 的 `normalize_cell` 比對前套用同一規則——兩邊必須同步，否則含 `|` 的知識檔
> 會永遠回報 `index_*_stale` 且 reindex 修不掉。

### B 群：front matter 與 MADR 結構

| code | 觸發條件 | 修法 |
|------|----------|------|
| `frontmatter_missing` | 缺 `標題`/`觸發時機`/`取代`/`被取代於` 任一欄 | 缺關係欄位可 `repair` 補 `-`；缺標題／觸發時機需人工或 AI 補寫 |
| `invalid_title` | `標題` 空白或殘留範本佔位字 | 人工／AI 改寫 |
| `invalid_trigger` | `觸發時機` 空白或範本字 | 人工／AI 改寫 |
| `active_marked_superseded` | 生效知識的 `被取代於` 不是 `-` | 人工判斷：清成 `-`，或改用 `supersede` 正式停用。兩種方向相反，`repair` 刻意不動 |
| `section_count` | 九個 MADR 段落中某個不是恰好一次 | 缺段落用編輯頁「新增區塊」補；重複段落需人工合併 |
| `section_content` | 段落空白／範本字／只填 `-` | 人工／AI 補寫 |
| `invalid_category` | 檔案不在 `ui`/`ux`/`dev`/`ops`/`data`/`else` 下的 `.md` | 人工搬到正確分類後 `reindex`；目標分類需判斷，無自動化 |

### C 群：取代關係（雙向互惠）

| code | 觸發條件 | 修法 |
|------|----------|------|
| `supersede_not_reciprocal` | 停用檔沒回填對應的 `被取代於` | `repair` 回填（目標欄位為空且只有一個生效檔宣稱取代它時） |
| `superseded_by_not_reciprocal` | 生效檔沒回填對應的 `取代` | `repair` 回填（條件同上） |
| `superseded_by_missing` | 停用檔未登記 `被取代於` | 恰有一個生效檔的 `取代` 指向它時 `repair` 可推回；否則需人工指定 |
| `supersede_target_invalid` | 生效檔 `取代` 不是合法相對路徑 | 人工改正或清成 `-` |
| `supersede_target_missing` | `取代` 指向的停用檔不存在 | 人工改正 |
| `superseded_by_target_invalid` | 停用檔 `被取代於` 不是合法相對路徑 | 人工改正 |
| `superseded_by_target_missing` | `被取代於` 指向的生效檔不存在 | 人工改正 |

## 功能 10：自動修復（kb-repair.sh）

`sh kb-repair.sh [--dry-run] [--yes] [相對路徑...]`

只處理**修法唯一、不需語意判斷**的項目：兩個方向的取代關係互惠回填、缺少的 `取代`／`被取代於` 補 `-`，最後呼叫 `kb-reindex.sh`。需要判斷的項目一律不動，改列在「需人工或 AI 判斷」清單並附上 code。

刻意不修的三類與理由：

- `active_marked_superseded`：清成 `-` 與移進 `deprecated/` 是相反的兩種修法，只有使用者知道哪個對。
- `section_count` 缺段落補空骨架：只會把一個 finding 換成另一個 `section_content`，而編輯頁的「新增區塊」下拉已覆蓋。
- `invalid_category` 搬移：搬移本身可腳本化，但目標分類需要判斷。

安全契約：

- 目標欄位已有**不同**的值時一律跳過並回報衝突，不覆寫既有取代關係。
- 多個生效知識同時宣稱取代同一停用檔時跳過——無從判定該回填哪一個。
- 改檔前備份至 `<KB 上層>/backups/repair-<路徑>-<時間戳>.md`。
- 結束碼：`0` 完成（含無事可做與 `--dry-run`）；`1` 結構錯誤；`3` 未取得授權而中止。

## 功能 2：整理索引（kb-reindex.sh）

把「補索引／修復斷鏈」改為**確定性腳本**，不由代理手動編輯索引。

流程：

1. **遞迴**掃描 knowledge（`find ... ! -name index.md ! -path deprecated/*`），對每個知識檔以 `awk` 解析：
   - front matter 的 `標題:` → 標題（連結文字）；`觸發時機:` → 觸發時機欄；`取代:` / `被取代於:` → 取代關係
   - `## 摘要` 段第一行 → 摘要欄
   - **舊格式相容**：缺 front matter `觸發時機:` 時回退 `## 觸發時機` 段；缺 `標題:` 時回退 H1，再退回相對路徑
2. 以 canonical 範本（`knowledge-skill/assets/knowledge-index.md`）表頭 + 每檔一列（`| [標題](相對路徑) | 觸發時機 | 摘要 | 取代 |`）重建整份 `index.md`；`deprecated/` 存在時另以 `knowledge-deprecated-index.md` 表頭重建 `deprecated/index.md`（欄位末改為 `被取代於`）。
   - 孤兒檔自然被納入；指向不存在檔案的舊列自然被排除。
   - 無任何知識檔時保留 placeholder 註解列。
3. **idempotent**：新內容與現有索引相同則不寫入。
4. 內容有變更才把原索引備份到 `<knowledge 上層>/backups/`（`index-backup-<時戳>.md`、`deprecated-index-backup-<時戳>.md`），再覆寫，並回報新增／移除筆數。

> 欄內 `|` 會被換成 `/` 以免破壞表格。內容品質由建檔時負責，整理只做機械重建。

## 功能 3：重置（kb-reset.sh）

⚠️ 不可逆。`sh kb-reset.sh [--yes]`。

- **授權規則**：
  - 帶 `--yes` → 視為已授權。
  - 未帶 `--yes` 且為互動 tty → 要求輸入 `yes` 才繼續，否則中止（結束碼 3）。
  - 未帶 `--yes` 且非 tty → 直接中止（結束碼 3），不誤刪。
- **備份位置**：`<knowledge 上層>/backups/knowledge-backup-<時戳>.tar.gz`，刻意放在 knowledge **之外**，避免被清空波及。
- **流程**：先 `tar -czf` 壓縮整個 knowledge，再以 `tar -tzf` 與檔案大小驗證；備份或驗證失敗即中止、不清空。通過後 `find "$KB_DIR" -mindepth 1 -delete` 清空，重建分類目錄骨架（`ui`/`ux`/`dev`/`ops`/`data`/`else`），再從 canonical 範本 `knowledge-skill/assets/knowledge-index.md`（範本不存在時用內嵌備援）重建空 `index.md`。

### 結束碼

| 碼 | 意義 |
|----|------|
| 0 | 完成 |
| 1 | 目錄不存在或備份失敗 |
| 3 | 未取得授權而中止 |

## 功能 4：刪除單一條目（kb-delete.sh）

⚠️ 不可逆。`sh kb-delete.sh [list|<編號或相對路徑> [--yes]]`。手動整理共用知識庫，逐筆刪除單一知識檔。

- **條目來源**：knowledge 內**遞迴**的知識檔（排除 `index.md` 與 `deprecated/`），以排序後的相對路徑編號，確保編號穩定。列表同時顯示各檔觸發時機（front matter `觸發時機:`，回退 `## 觸發時機`）作為提示。
- **選擇方式**：代理執行 `list` 後逐筆使用原生選單；文字 fallback 與人類 CLI 仍可用清單編號或相對路徑（可省略 `.md`）。
- **授權規則**（與 reset 一致）：
  - 帶 `--yes` → 視為已授權。
  - 未帶 `--yes` 且為互動 tty → 要求輸入 `yes` 才繼續，否則取消（結束碼 3）。
  - 未帶 `--yes` 且非 tty → 直接中止（結束碼 3），不誤刪。
- **流程**：解析選擇 → 取得授權 → `rm` 對應知識檔 → 呼叫 `kb-reindex.sh` 確定性重建索引（移除剛刪檔造成的斷鏈，不手改 `index.md`）。
- **list-only**：明確傳入 `list` 時，即使 stdin 是 TTY 也只列出並結束；無參數且為 TTY 才讀取一個編號。
- **無論刪除或取消**，動作後都重列最新條目清單。

### 結束碼

| 碼 | 意義 |
|----|------|
| 0 | 完成（含唯讀列表） |
| 1 | 結構缺失（無目錄或無 `index.md`）或選擇無效 |
| 3 | 未取得授權而中止 |

## 功能 9：注入與更新注入區塊（kb-injection.sh）

`sh kb-injection.sh [list [目標路徑]|inject <檔案路徑> [--create] [--yes]|update <檔案路徑> [--yes]]`。維護各 AI 指令檔開頭由 `<!-- BEGIN knowledge-skill:shared-kb -->` ／ `<!-- END knowledge-skill:shared-kb -->` 包夾的注入區塊。

- **inject 與 update 分工**：`inject` 只做首次注入（區塊置於檔頭、原內容接在其後），檔案已有 marker 時不動並提示改用 `update`（結束碼 0）；`update` 只更新既有區塊，沒有 marker 時拒絕（結束碼 1）並提示改用 `inject`。兩者都在 skill 內，只裝 skill、沒 clone repo 也能完成首次注入；repo 的 `scripts/init-injection.sh` 保留給未裝 skill 的遠端單檔執行。
- **inject 的目標**：只接受檔名為 `AGENTS.md`／`CLAUDE.md`／`GEMINI.md` 的檔案。檔案不存在時預設拒絕（結束碼 1）；帶 `--create` 才建立，且只限四個全域指令檔、該工具目錄已存在、不是失效的 symlink。專案目錄的指令檔一律不憑空建立。
- **保留 symlink**：`inject` 以 `cat` 寫回而非 `mv`，全域指令檔若是指向 `~/.ai-global/AGENTS.md` 的 symlink，注入後仍是 symlink。
- **檢查對象**：不給路徑時為 `~/.codex/AGENTS.md`、`~/.claude/CLAUDE.md`、`~/.gemini/GEMINI.md`、`~/.ai-global/AGENTS.md`；給目錄則為其下三個檔名；給單一檔案則只該檔。不存在的檔案略過；只有不給路徑時，工具目錄已在、指令檔還沒建的全域檔會列為「未建立」，供 `inject --create`。
- **狀態判定**：把檔內既有區塊與 `make_block()` 產生的現行區塊**逐字比對**，分「最新／需更新／無區塊」。用逐字比對而非關鍵字比對，區塊文字再改也不必改判定邏輯。
- **就地置換**：以 awk 取代 `BEGIN … END` 之間內容，保留區塊在檔案中的**原位置**與區塊外所有內容；改檔前備份 `<檔案>.knowledge-skill.bak.<timestamp>`。已是現行版本則不動檔案（idempotent）。
- **授權規則**（與 delete 一致）：帶 `--yes` 視為已授權；未帶且為互動 tty 要求輸入 `yes`；未帶且非 tty 直接中止（結束碼 3）。
- **list-only**：`list` 即使 stdin 是 TTY 也只列出、不讀取選擇。
- **區塊文字的單一來源問題**：`kb-injection.sh` 與 `scripts/init-injection.sh` 各有一份 `make_block()`（skill 目錄可獨立安裝、`init-injection.sh` 支援單檔遠端執行，無法共用來源）。改任一邊後必須執行 `sh scripts/test-injection-block.sh` 確認兩份逐字一致。

### 結束碼

| 碼 | 意義 |
|----|------|
| 0 | 完成（含唯讀列表、已是現行版本、inject 遇既有區塊） |
| 1 | 參數錯誤、檔案不存在、該檔沒有既有區塊（update）、檔名不符或不允許建立（inject） |
| 3 | 未取得授權而中止 |

## 功能 11：跨位置同步（kb-sync.sh）

`sh kb-sync.sh <pull|push> <對方 knowledge 路徑> [--dry-run] [--overwrite] [--yes]`。在本機知識庫（`KNOWLEDGE_BASE_DIR`）與另一份指定位置的知識庫之間**單向**搬運知識檔：`pull` 為對方→本機，`push` 為本機→對方。

- **目標形態**：本機／掛載路徑（另一個雲端資料夾、外接碟、另一台裝置的副本）。不處理 git remote 與 ssh。
- **合併語意**：只新增、不刪除。接收端獨有的知識檔一律保留，同步不會讓兩端變得一模一樣，也不該用它做「鏡像」。
- **搬運範圍**：遞迴的 `*.md`，排除各層 `index.md`，**含 `deprecated/` 子樹**——取代關係是雙向互惠的，只搬生效知識會讓接收端的 `被取代於` 指向不存在的檔案，`kb-health.sh` 的 C 群檢查會整批報錯。
- **比對方式**：以 `cmp` 比對檔案內容，**不看 mtime**。跨裝置與雲端同步資料夾的 mtime 不可信，用它判斷新舊會誤覆蓋。
- **三種分類**：接收端沒有 → 新增；內容一致 → 略過；同路徑但內容不同 → **衝突**。
- **衝突預設不動**：只列出，結束碼 `2`。帶 `--overwrite` 才以來源覆蓋，覆蓋前把接收端原檔備份到 `<接收端上層>/backups/sync-<時戳>/<相對路徑>`（保留目錄結構）。
- **兩端都須是既有知識庫**：目錄存在且有 `index.md`，否則中止（結束碼 1）。**不代建**對方目錄——路徑打錯而默默長出一棵假知識庫比報錯難救。兩端解析成絕對路徑後相同時亦中止。
- **索引不複製**：搬完以 `KNOWLEDGE_BASE_DIR=<接收端> sh kb-reindex.sh` 在接收端重建。複製 `index.md` 會讓兩邊各自演化的索引互相覆蓋，產生斷鏈。
- **授權規則**（與 delete／repair 一致）：帶 `--yes` 視為已授權；未帶且為互動 tty 要求輸入 `yes`；未帶且非 tty 直接中止（結束碼 3）。`--dry-run` 唯讀，不需授權。

### 結束碼

| 碼 | 意義 |
|----|------|
| 0 | 完成（含 `--dry-run` 與無事可做） |
| 1 | 參數錯誤、任一端不是知識庫、兩端為同一目錄，或收尾 reindex 失敗 |
| 2 | 完成，但有跳過未處理的衝突 |
| 3 | 未取得授權而中止 |

## 功能 5：整理知識內容（curate）

`sh kb-tools.sh curate` 印出沉澱／盤點／取代三個子步驟導引，本身不改檔。三個子命令皆為獨立命令、可單獨執行，常見順序為 沉澱 → 盤點 → 取代：

- **5-1 收束沉澱（kb-consolidate.sh）**：掃描任務資料夾、檢查格式、列出沉澱候選（唯讀）；判斷與建檔流程見 `consolidate.md`。
- **5-1b 建檔草稿（kb-new.sh）**：從 canonical 範本產生草稿供代理填寫（唯讀於知識庫）；填完以功能 7 `promote` 安裝。
- **5-2 盤點矛盾（kb-reconcile.sh）**：列出生效知識供比對新舊矛盾（唯讀）。
- **5-3 取代（kb-supersede.sh）**：以新知識取代舊知識、停用舊檔（不可逆，需 `--yes`）。

## 功能 5-1b：建檔草稿（kb-new.sh）

`sh kb-new.sh <knowledge-相對路徑> [--out <草稿路徑>]`。從 canonical 範本 `knowledge-skill/assets/knowledge.md` 產生草稿供代理填寫，**不寫入知識庫**。

- **預檢**：路徑需為 `.md`、不得為絕對路徑／含 `..`／位於 `deprecated/`；知識庫需完整；目標已存在即拒絕（同主題應合併，淘汰請走 `supersede`）。預檢在填寫前失敗，省下白填一份被 `promote` 拒收的成本。
- **範本來源**：`knowledge-skill` 未並存安裝時找不到範本，中止並提示（結束碼 1）。
- **輸出**：stdout 最後一行是草稿絕對路徑，供呼叫端取用；未帶 `--out` 時建於暫存目錄。
- 結束碼：`0` 完成；`1` 參數／結構錯誤、目標已存在或找不到範本。

## 功能 5-2：盤點矛盾（kb-reconcile.sh）

唯讀。`sh kb-reconcile.sh [分類前綴]`。遞迴列出生效知識（排除 `deprecated/`）的相對路徑、標題、觸發時機、摘要、決策結果，作為代理判斷新舊知識是否矛盾的素材。可帶分類前綴（如 `dev` 或 `dev/php-laravel`）只盤點該範圍。

- 本身不改檔；判斷矛盾與後續取代由代理在取得使用者同意後以 `kb-supersede.sh` 執行。
- 結束碼：`0` 完成（含無條目）；`1` 結構缺失。

## 功能 5-3：取代（kb-supersede.sh）

`sh kb-supersede.sh <舊檔相對路徑> <新檔相對路徑> [--yes]`。以新知識取代舊知識並停用舊檔。

- **前置檢查**：新舊檔皆須為生效知識檔（不可位於 `deprecated/`），且新檔須已存在。
- **授權規則**（與 reset／delete 一致）：帶 `--yes` 視為已授權；互動 tty 需輸入 `yes`；非 tty 未帶 `--yes` 直接中止（結束碼 3）。
- **流程**：舊檔 front matter 寫入 `被取代於: <新檔>`、新檔寫入 `取代: <舊檔>`（idempotent，無 front matter 時前置最小區塊）→ 把舊檔移入 `deprecated/` 下的**鏡像相對路徑** → 呼叫 `kb-reindex.sh` 重建生效與停用兩份索引。
- 屬可回復操作（檔案僅移位），但停用知識仍需明確同意。

### 結束碼

| 碼 | 意義 |
|----|------|
| 0 | 完成 |
| 1 | 參數或結構錯誤（缺檔、新舊相同、位於 deprecated 等） |
| 3 | 未取得授權而中止 |

## 功能 6：匯入跨工具記憶（kb-import.sh 與 adapter）

唯讀。`sh kb-import.sh <claude|codex|copilot> [來源] [--write] [選項...]`。把 vendor memory 轉成候選任務資料夾，**只進候選區**，不直接建立生效知識。完整來源、metadata 與安全門檻見 `import.md`。

- **預設 dry-run**：只輸出規模統計（掃描筆數、排除原因、合格候選、scope 分布）；`--write` 才產生 `docs/knowledge-skill/記憶候選_<tool>-NNN/`。
- 候選**只存摘要 + evidence 指標，不複製 vendor 全文**；通過 `validate-task-completion.sh`。
- secret scan 命中（private key／`api_key`／`token`／`password`／各家金鑰樣式／連線字串等）或來源檔讀不到即排除；預設排除 `*.jsonl`／SQLite。
- 去重鍵 `source_hash + scope + repository + source_kind`，記錄於 `docs/knowledge-skill/.import-ledger/<tool>.tsv`；同來源重跑不重複。
- 規模控制：`--limit N`、`--scope`、`--repository`、`--since`（需 find 支援 `-newermt`）。
- 不支援的 schema → 非零退出與明確訊息，不臆測解析。
- Copilot 無公開 export API：須 `--from-file`；`copilot-memory` 與 `copilot-session` 以 `source_kind` 區分。

### 結束碼

| 碼 | 意義 |
|----|------|
| 0 | 完成（含 dry-run） |
| 1 | 來源錯誤、未知工具或 schema 不支援 |
| 2 | 無合格候選（全被排除或去重） |

## 功能 7：晉升候選為生效知識（kb-promote.sh）

`sh kb-promote.sh <候選-MADR.md> <knowledge-相對路徑> [--yes] [--source <來源說明>]`。把審核通過的候選 MADR 確定性安裝成生效知識。

- **格式驗證**：front matter `標題`／`觸發時機` 非範本佔位；必要段落 `## 摘要`／`## 決策結果`。
- **拒絕覆蓋**：目標已存在即中止（結束碼 1）；要取代請改用 `supersede`。
- **授權規則**（與 reset／delete／supersede 一致）：`--yes` 視為已授權；互動 tty 需輸入 `yes`；非 tty 未帶 `--yes` 直接中止（結束碼 3）。
- **流程**：原子安裝（`mktemp` + `mv`）→ 檔尾補 provenance（來源與 sha256，idempotent）→ 呼叫 `kb-reindex.sh` → 提示跑 `status`。
- **`--source`**：覆寫 provenance 的來源描述，省略時記錄候選檔路徑。草稿來自 `kb-new.sh` 的暫存目錄時（如 `knowledge-record-skill` 的沉澱流程），暫存路徑沒有追溯價值，改填任務資料夾或對話來源。

### 結束碼

| 碼 | 意義 |
|----|------|
| 0 | 完成 |
| 1 | 參數／格式／結構錯誤或目標已存在 |
| 3 | 未取得授權而中止 |
