---
name: knowledge-tools-skill
description: 由使用者以 `/knowledge-tools-skill` 指令手動啟動的共用知識庫維運工具，不會被 AI 自動觸發。提供檢查知識庫位置與健康度、整理索引、自動修復修法唯一的健康問題、重置／備份、刪除單一條目、首次注入或更新各 AI 指令檔中的共用知識庫注入區塊、把任務資料夾的成果收束沉澱進共用 knowledge、盤點新舊知識矛盾並停用被取代的知識，以及把 Claude Code／Codex／GitHub Copilot 的記憶匯入為候選並晉升成生效知識。以互動選單呈現選項，所有固定流程都由 shell 腳本自動完成，代理只負責路由與取得不可逆操作的同意。
disable-model-invocation: true
model: sonnet
metadata:
  version: "1.7.1"
  author: "LazyJerry"
---

# 知識庫輔助工具

維運共用知識庫（預設 `$HOME/.knowledge-skill/knowledge/`，可用 `KNOWLEDGE_BASE_DIR` 覆寫）。以單一進入點 `kb-tools.sh` 提供十三項功能，分組見下方兩層選單。

知識檔以 MADR 格式、依分類目錄（`ui`/`ux`/`dev`/`ops`/`data`/`else`，第二層依語言/框架）遞迴存放，索引登錄相對路徑；已停用（被取代）的知識移入 `deprecated/` 並另記於 `deprecated/index.md`。知識格式與覆蓋／停用機制以 `knowledge-skill/references/knowledge-base.md` 為單一規範來源，範本集中於 `knowledge-skill/assets/`。

> 💡 **設計原則**：固定流程一律由 `scripts/` 下的 shell 腳本自動完成（降低隨機性）；代理的工作是**路由調度**與**取得不可逆操作的明確同意**，不手動編輯 `index.md`。

`<SKILL_DIR>` 為此 skill 安裝目錄。所有命令以 `sh <SKILL_DIR>/scripts/...` 形式執行。

## 原生互動選單路由

代理處理使用者選擇時沿用 `knowledge-skill` 的路由：

- Claude Code：`AskUserQuestion` 可用時必須呼叫。
- Codex：`request_user_input` 可用時必須呼叫；Plan mode 預設提供，Default mode 只有在 client 提供工具時可用。
- 工具不可用：說明限制後退回文字編號清單。
- 固定選項每題最多三個；原生工具可用時不得要求使用者輸入編號或命令名。
- 無上限條目清單逐筆詢問「選擇此項／下一項／取消」；只有自訂路徑、分類或檔名才收自由文字。

十三項主功能以兩層選單呈現：

1. **檢查與索引** → `status`／`health`／`reindex`／`repair`
2. **維護與設定** → `reset`／`delete`／`injection`／`sync`／`setup`
3. **知識內容與候選** → `curate`／`import`／`promote`／`auto`

執行 shell script 時：

- 代理以 `sh <SKILL_DIR>/scripts/kb-tools.sh menu` 取得選單文字，避免 script 從 stdin 讀取選項。
- 刪除候選以 `sh <SKILL_DIR>/scripts/kb-delete.sh list` 唯讀列出；注入區塊狀態以 `sh <SKILL_DIR>/scripts/kb-injection.sh list` 唯讀列出。
- `reset`、`delete`、`injection inject`、`injection update`、`supersede`、`promote`、`repair`、`sync`、`setup`、`auto on`、`auto off`、`auto confirm` 先由原生選單取得明確同意，再傳入 `--yes`。
- 無參數 script 的 TTY 互動保留給人類直接使用，不作為代理入口。

## 主流程

1. **先讀共用知識庫索引**（依全域規範）：`$KNOWLEDGE_BASE_DIR/index.md`（預設 `$HOME/.knowledge-skill/knowledge/index.md`）。
2. **取得選單資料**：執行 `menu` 取得選單文字，不讓 script 讀取 stdin：
   ```bash
   sh <SKILL_DIR>/scripts/kb-tools.sh menu
   ```
3. **依使用者選擇分派**：用原生兩層選單取得選擇後，代理直接執行對應命令；只有工具不可用時才請使用者回覆編號。

## 功能對照（選單編號＝輸入數字）

| 編號 | 命令 | 功能 | 改檔 | 注意 |
|------|------|------|------|------|
| 1 | `status` | 檢查知識庫位置與健康度 | 否 | 唯讀 |
| 2 | `reindex` | 整理索引：依知識檔重建索引 | 是 | 改前自動備份 |
| 3 | `reset` | 重置：備份壓縮後清空並重建空索引 | 是 | ⚠️ 不可逆，需 `--yes` |
| 4 | `delete` | 手動整理：刪除單一知識檔 | 是 | ⚠️ 不可逆，需 `--yes` |
| 5 | `curate` | 整理知識內容：沉澱／建檔／盤點／取代 | 視子步驟 | 子步驟 `new` 只產草稿、不動知識庫 |
| 6 | `import` | 匯入跨工具記憶為候選 | 預設否 | 唯讀來源 |
| 7 | `promote` | 晉升候選為生效知識 | 是 | ⚠️ 需 `--yes`，拒絕覆蓋 |
| 8 | `health` | 檢查 MADR 內容與取代關係 | 僅 log | 知識內容唯讀；保存 JSON 結果 |
| 9 | `injection` | 首次注入或更新各 AI 指令檔的共用知識庫注入區塊 | 是 | `list` 唯讀；`inject`、`update` 需 `--yes`，改前自動備份 |
| 10 | `repair` | 自動修復健康檢查中修法唯一的問題 | 是 | `--dry-run` 唯讀；改檔需 `--yes`，改前自動備份 |
| 11 | `sync` | 與指定位置的知識庫單向搬運知識檔（pull／push） | 是 | `--dry-run` 唯讀；只新增不刪除，需 `--yes` |
| 12 | `setup` | 確認設定：搬移舊版 shell 設定檔的位置設定、確保目錄／分類／索引齊全 | 是 | `--dry-run` 唯讀；改檔需 `--yes`，改前備份 |
| 13 | `auto` | 免詢問自動收錄：開關、列出 `AI 自動確認` 的知識、確認為 `人工審核確認` | 視子命令 | `status`、`list` 唯讀；`on`、`off`、`confirm` 需 `--yes` |

各子命令的腳本、流程與結束碼詳見 `references/operations.md`。

## 功能 1：檢查（status）

唯讀。回報知識庫位置與健康度：
```bash
sh <SKILL_DIR>/scripts/kb-tools.sh status
```
依結束碼回報：

| 結束碼 | 意義 | 動作 |
|--------|------|------|
| 0 | 健康且一致 | 回報健康，結束 |
| 1 | 結構缺失（無目錄或無 index） | 無目錄：提示先用 `init-knowledge-base.sh` 建立；只缺 index（索引不參與雲端同步，其他裝置上缺索引是常態）：執行 **功能 2 整理索引** 重建 |
| 2 | 有斷鏈或孤兒檔 | 告知差異，建議執行 **功能 2 整理索引** |

## 功能 8：內容健康檢查（health）

以 canonical MADR 規範檢查生效知識的分類、front matter、九個標準段落、索引欄位與取代關係；停用知識只檢查索引及互惠取代關係：

```bash
sh <SKILL_DIR>/scripts/kb-tools.sh health [--format text|json] [--source cli|tray|ui]
```

不修改知識檔；每次結果寫入 `$HOME/.knowledge-skill/logs/health/latest.json`，並追加至 `history.jsonl`。結束碼 `0` 健康、`1` 執行／結構錯誤、`2` 檢查成功但發現不健康項目。

每個 finding 帶 `actions` 欄位（`reindex`／`repair`／`edit`／`delete`），代理依它決定下一步。完整的 **code → 修法對照表**（哪些能由 `reindex` 全自動修、哪些能由 `repair` 確定性修、哪些只能人工或 AI 改寫）見 `references/operations.md`。

## 功能 10：自動修復（repair）

修復健康檢查中**修法唯一、不需語意判斷**的問題：回填斷裂的取代關係、補上缺少的 `取代`／`被取代於` 欄位、替沒有 `狀態` 欄的生效知識補上 `人工審核確認`，最後自動 `reindex`。需要判斷的項目一律不動，只列出並附上 code。

1. **先看修復計畫**（唯讀）：
   ```bash
   sh <SKILL_DIR>/scripts/kb-tools.sh repair --dry-run
   ```
2. 依原生路由詢問「套用修復／取消」，**取得明確同意後**才執行：
   ```bash
   sh <SKILL_DIR>/scripts/kb-tools.sh repair --yes
   ```

> 屬可回復操作（改檔前備份至 `<KB 上層>/backups/`），但仍須明確同意才帶 `--yes`；未帶且非互動環境會中止（結束碼 3）。目標欄位已有不同值、或多個生效知識同時宣稱取代同一停用檔時一律跳過，不臆測。

## 功能 2：整理索引（reindex）

由腳本確定性重建索引（補登錄孤兒、清除斷鏈），不由代理手動編輯：
```bash
sh <SKILL_DIR>/scripts/kb-tools.sh reindex
```
回報新增登錄與移除斷鏈的筆數；改檔前自動備份原 `index.md`。建檔或取代後一律執行，再跑 `status` 驗證。

## 功能 3：重置（reset，不可逆）

⚠️ **不可逆操作，需明確同意**。

1. 先以 `status` 顯示現況。
2. 向使用者說明：會**先備份壓縮**整個 knowledge（備份檔放在 knowledge 之外的 `backups/`），再**清空**並**重建空索引**。
3. 依原生路由詢問「確認重置／取消」，**取得明確同意後**才執行（`--yes` 代表已獲授權）：
   ```bash
   sh <SKILL_DIR>/scripts/kb-tools.sh reset --yes
   ```
4. 回報備份檔路徑與大小。

> 未取得同意前不要帶 `--yes`。腳本在非互動環境若未帶 `--yes` 會中止（結束碼 3），不會誤刪。

## 功能 4：手動整理 — 刪除單一條目（delete，不可逆）

⚠️ **不可逆操作，需明確同意**。刪除後由腳本自動重建索引（不手改 `index.md`）。

1. **列出條目**（唯讀，依磁碟知識檔編號）：
   ```bash
   sh <SKILL_DIR>/scripts/kb-delete.sh list
   ```
   逐筆呈現條目路徑與觸發時機，詢問「選擇此項／下一項／取消」。
2. 選定條目後依原生路由詢問「確認刪除／取消」。
3. **取得明確同意後**才執行（`--yes` 代表已獲授權）：
   ```bash
   sh <SKILL_DIR>/scripts/kb-delete.sh <相對路徑> --yes
   ```
   腳本刪除對應知識檔、自動 `reindex`，並重列最新條目清單。
4. **若未同意則取消**：不帶 `--yes` 且非互動環境會中止（結束碼 3），不誤刪。無論刪除或取消，動作後都會回傳最新條目清單。

> 條目來源為磁碟上遞迴的知識檔（排除 `index.md` 與 `deprecated/`），以相對路徑編號。刪除採確定性腳本＋刪後 `reindex`，避免手動編輯索引產生斷鏈。

## 功能 9：注入與更新注入區塊（injection）

各 AI 指令檔（`AGENTS.md`／`CLAUDE.md`／`GEMINI.md`）開頭的「共用知識庫優先參考」區塊，讓各 AI 工具在動手前先查共用知識庫。本功能負責**首次注入**（`inject`）與**更新落後的既有區塊**（`update`），只裝 skill、沒 clone repo 也能完成。首次安裝時先跑功能 12 `setup` 建好知識庫，再用本功能注入。

1. **列出狀態**（唯讀，即使 stdin 是 tty 也不讀取）：
   ```bash
   sh <SKILL_DIR>/scripts/kb-injection.sh list [目標路徑]
   ```
   不給路徑時檢查四個全域指令檔（`~/.codex/AGENTS.md`、`~/.claude/CLAUDE.md`、`~/.gemini/GEMINI.md`、`~/.ai-global/AGENTS.md`）；給目錄則檢查其下三個檔名，給單一檔案則只檢查該檔。狀態分「最新／需更新／無區塊」，判定方式是把檔內既有區塊與現行區塊逐字比對；不給路徑時，工具目錄已在、指令檔還沒建的全域檔另列為「未建立」。
2. **逐份取得同意**：依狀態決定動作——「需更新」→ `update`、「無區塊」→ `inject`、「未建立」→ `inject --create`。一份用「執行／略過」；多份先問「全部執行／逐份決定／全部略過」，逐份時用「選擇此項／下一項／取消」。
3. **取得明確同意後**才執行（`--yes` 代表已獲授權）：
   ```bash
   sh <SKILL_DIR>/scripts/kb-injection.sh inject <檔案路徑> --yes            # 無區塊：區塊插在檔頭
   sh <SKILL_DIR>/scripts/kb-injection.sh inject <檔案路徑> --create --yes   # 未建立：建立後注入（限全域指令檔）
   sh <SKILL_DIR>/scripts/kb-injection.sh update <檔案路徑> --yes            # 需更新：就地置換
   ```
   `inject` 把區塊放在檔頭、原內容接在其後，已有區塊則不動；`update` 置換 `BEGIN … END` 之間的內容，保留區塊原位置與其餘內容。兩者改檔前都備份為 `<檔案>.knowledge-skill.bak.<timestamp>`，目標是 symlink 時寫入連結目標、保留 symlink。

> 屬可回復操作（有備份），但改的是使用者正在使用的 AI 指令檔，仍須明確同意才帶 `--yes`。未帶 `--yes` 且非互動環境會中止（結束碼 3）。`update` 遇到沒有區塊的檔案、`inject` 遇到不存在又不允許建立的檔案，都拒絕並以結束碼 1 結束；`--create` 不建立專案目錄的指令檔。

## 功能 11：跨位置同步（sync）

知識庫可能同時存在多份（另一個雲端資料夾、外接碟、另一台裝置的副本）。本功能在本機知識庫與**指定位置**之間**單向**搬運知識檔：

- `pull`：對方 → 本機
- `push`：本機 → 對方

採**合併語意**：只新增、不刪除，接收端獨有的知識檔一律保留。**索引不複製**，搬完由 `kb-reindex.sh` 在接收端重建——兩邊索引各自演化時互相覆蓋會造成斷鏈。`deprecated/` 下的知識檔一併搬運，否則接收端的取代關係會指向不存在的檔案。

1. **先看搬運計畫**（唯讀）：
   ```bash
   sh <SKILL_DIR>/scripts/kb-tools.sh sync <pull|push> <對方 knowledge 路徑> --dry-run
   ```
   回報新增／相同／衝突各幾筆並逐筆列出路徑。
2. 依原生路由詢問「執行同步／取消」，**取得明確同意後**才執行：
   ```bash
   sh <SKILL_DIR>/scripts/kb-tools.sh sync <pull|push> <對方 knowledge 路徑> --yes
   ```
3. **衝突**（兩端同路徑但內容不同）預設**不動**、只列出，結束碼 `2`。確認要以來源為準時，另行取得同意再加 `--overwrite`（覆蓋前備份至 `<接收端上層>/backups/sync-<時戳>/`）：
   ```bash
   sh <SKILL_DIR>/scripts/kb-tools.sh sync <pull|push> <路徑> --overwrite --yes
   ```

> 比對用檔案內容（`cmp`），不看 mtime——跨裝置與雲端同步的 mtime 不可信。兩端都必須是既有知識庫（目錄存在且有 `index.md`），對方目錄不存在時**不代建**，以免路徑打錯而長出一棵假知識庫（結束碼 1）。未帶 `--yes` 且非互動環境會中止（結束碼 3）。

## 功能 5：整理知識內容（curate：收束沉澱／盤點矛盾／取代）

把任務成果沉澱進共用知識庫，並盤點新舊矛盾、以新知識取代被淘汰的舊知識。三個子步驟皆為獨立命令，依需要選用，常見順序為 沉澱 → 盤點 → 取代。執行 `curate` 可取得子步驟導引：
```bash
sh <SKILL_DIR>/scripts/kb-tools.sh curate
```

### 5-1 收束沉澱（consolidate，從任務資料夾）

把各專案 `docs/knowledge-skill/` 任務資料夾的成果，沉澱成共用知識檔。

1. **詢問來源路徑**：依原生路由詢問「目前工作區／自訂路徑」；只有選擇自訂才收自由文字。
2. **格式檢查與候選列舉**（唯讀腳本）：
   ```bash
   sh <SKILL_DIR>/scripts/kb-tools.sh consolidate <來源路徑>
   ```
   腳本回報各任務資料夾合格／缺檔，並列出合格任務的 `notes.md`、`report-<任務名稱英文>.md` 作為候選來源。
3. **判斷與選擇候選**：一項用「沉澱／略過」；多項先問「全部沉澱／逐項決定／全部略過」，逐項時依序使用「選擇此項／下一項／取消」。
4. **建檔**（詳見 `references/consolidate.md`）：代理讀取選定來源、依收錄判準篩出跨專案可重用內容並決定分類路徑；相同主題直接合併進既有知識檔，新主題走腳本：
   ```bash
   sh <SKILL_DIR>/scripts/kb-tools.sh new <分類>/<語言-框架>/<topic>.md   # 從 canonical 範本產草稿
   # 代理填寫草稿內容
   sh <SKILL_DIR>/scripts/kb-tools.sh promote <草稿路徑> <相對路徑> --yes --source "<來源任務資料夾>"
   ```
   `promote` 會驗證格式、拒絕覆蓋並自動重建索引。**僅在使用者明確同意後才傳 `--yes`。**

> **跨工具來源（方法 1）**：要沉澱 Claude Code／Codex／GitHub Copilot 的記憶，最簡路徑是讓各工具先以 `knowledge-skill` 把已審核、跨專案可重用的結論寫成完整任務資料夾，再走本步驟的 `consolidate`。要批次匯入既有 vendor memory 則用功能 6 的 `import`。

### 5-2 盤點矛盾並取代（reconcile / supersede）

盤點生效知識中**新舊矛盾**（同一觸發情境給出相衝突的決策結果），確認後以新知識取代舊知識。

1. **盤點**（唯讀，可帶分類前綴）：
   ```bash
   sh <SKILL_DIR>/scripts/kb-tools.sh reconcile [分類前綴]
   ```
   腳本列出生效知識的相對路徑、標題、觸發時機、摘要、決策結果。
2. **判斷與呈現**（代理）：依語意找出矛盾項，把「舊知識 vs 新知識」與處理建議呈現給使用者。
3. 依原生路由詢問「以新知識取代／保留舊知識」，**取得明確同意後取代**（移舊檔入 `deprecated/`、寫入取代關係、自動 `reindex`）：
   ```bash
   sh <SKILL_DIR>/scripts/kb-tools.sh supersede <舊檔相對路徑> <新檔相對路徑> --yes
   ```

### 5-3 重建索引與驗證

`promote`、`supersede`、`delete` 已自動重建索引。只有**直接編輯知識檔**（合併進既有檔）才需手動執行功能 2 `reindex`，一律不手改 `index.md`：
```bash
sh <SKILL_DIR>/scripts/kb-tools.sh reindex
```
再跑 `status` 確認生效／停用各自一致、無斷鏈／孤兒。

> 收束建檔僅在使用者明確同意後寫入；取代屬可回復（檔案僅移位），但停用知識仍須使用者明確同意才帶 `--yes`。

## 功能 6：匯入跨工具記憶為候選（import）

把 Claude Code／Codex／GitHub Copilot 的記憶以 read-only adapter 轉成候選任務資料夾。詳見 `references/import.md`。

1. **選擇來源工具**：以原生三選一呈現 Claude Code／Codex／GitHub Copilot；自訂來源路徑另行收自由文字。
2. **dry-run 先看規模**（預設不落地）：
   ```bash
   sh <SKILL_DIR>/scripts/kb-tools.sh import <claude|codex|copilot> [來源]
   ```
   回報掃描筆數、排除原因（機密／重複／超過上限）、合格候選數與 scope 分布。
3. dry-run 後依原生路由詢問「產生候選／保持 dry-run」，確認後落地（產生 `docs/knowledge-skill/記憶候選_<tool>-NNN/`，只存摘要與來源 metadata，不複製 vendor 全文）：
   ```bash
   sh <SKILL_DIR>/scripts/kb-tools.sh import <tool> [來源] --write
   ```
4. **接回現行流程**：用 `consolidate` 列舉候選 → 人工審核 → 建 MADR → 功能 7 `promote`。

> 唯讀來源、絕不改寫 vendor state；命中機密樣式或 `*.jsonl`／SQLite 自動排除。Copilot 無公開 export API，須以 `--from-file` 指定整理後檔案。

## 功能 7：晉升候選為生效知識（promote）

把審核通過的候選 MADR 確定性安裝成生效知識。

先逐筆呈現候選摘要，使用「選擇此項／下一項／取消」取得候選；目標相對路徑屬自訂值，可收自由文字。再依原生路由詢問「確認晉升／取消」。

⚠️ **取得明確同意後才傳 `--yes`**。目標已存在則拒絕覆蓋（要取代請用功能 5 的 `supersede`）。

```bash
sh <SKILL_DIR>/scripts/kb-tools.sh promote <候選-MADR.md> <knowledge-相對路徑> --yes
```

驗證 front matter 與必要段落 → 原子安裝、把 `狀態` 寫為 `人工審核確認` 並補來源 provenance → 自動 `reindex` → 提示跑 `status`。

`--auto`（免詢問自動收錄）只供 `knowledge-record-skill` 使用，本功能由使用者逐筆確認，一律帶 `--yes`。

## 功能 13：自動收錄（auto）

`knowledge-record-skill` 會把五條閘門全過的全新知識不經詢問直接寫入，狀態標為 `AI 自動確認`。本功能管理這條通道的開關，以及把審核過的知識改為 `人工審核確認`。

1. **先看現況**（唯讀）：
   ```bash
   sh <SKILL_DIR>/scripts/kb-tools.sh auto status   # 開關狀態與 AI 自動確認的數量
   sh <SKILL_DIR>/scripts/kb-tools.sh auto list     # 列出 AI 自動確認的知識
   ```
2. 依原生路由詢問要做哪一項，**取得明確同意後**才執行：
   ```bash
   sh <SKILL_DIR>/scripts/kb-tools.sh auto off --yes                      # 關閉自動收錄（之後一律先徵詢）
   sh <SKILL_DIR>/scripts/kb-tools.sh auto on --yes                       # 開啟
   sh <SKILL_DIR>/scripts/kb-tools.sh auto confirm <相對路徑>... --yes    # 審核過的改為人工審核確認
   sh <SKILL_DIR>/scripts/kb-tools.sh auto confirm --all --yes            # 全部確認
   ```

確認清單無上限時逐筆詢問「確認此項／下一項／取消」，不要的走功能 4 `delete`。開關預設開啟，寫在設定檔 `~/.config/knowledge-skill/config` 的 `KNOWLEDGE_AUTO_RECORD=`；環境變數 `KNOWLEDGE_AUTO_RECORD` 有設定時優先。細節與結束碼見 `references/operations.md`。
