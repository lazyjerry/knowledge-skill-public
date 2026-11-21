# Knowledge Skill

<!-- 感謝 OthmanAdi/planning-with-files，本 skill 由其概念修改而來。 -->

把查詢、研究與長任務過程寫進持久性 markdown，並將驗證過、跨專案成立的發現沉澱到共用 `knowledge/`。下一次任務可先查索引，沿用既有慣例與已知陷阱，不必重查。

GitHub：<https://github.com/lazyjerry/knowledge-skill-public>

---

## 介紹

### 適用情境

- 研究、調查、分析資料，並希望成果可被後續任務重用
- 需要逐步累積、跨專案共用的知識整理
- 需要多步驟推進、跨多個檔案搜尋比對的開發或文件工作
- 需要產出報告、結論、設計決策或後續可查閱的知識
- 任務可能分多次對話完成，需要可恢復的上下文

不適合單一指令即可完成、且不留下可重用知識的小任務，例如改一行文案、查一個指令輸出、簡單翻譯。

### 核心概念

| 概念 | 做法 |
|------|------|
| 檔案系統是外部記憶 | 長輸出、查詢結果、研究材料寫入檔案；對話只保留路徑與必要摘要 |
| `task_plan.md` 是任務錨點 | 跨對話續作時先讀，讓目標、待辦與目前狀態接得上 |
| `notes.md` 保存發現 | 階段完成後先更新 `notes.md`，再更新 `task_plan.md` |
| 錯誤要記錄 | 工具呼叫失敗、找不到檔案、測試失敗、API timeout 都寫進 `task_plan.md` |
| 公用知識庫跨專案共用 | 只保存跨專案可重用知識；一般常識、一次性結果、單一專案細節不寫入 |

### 三個 Skill

| Skill | 角色 |
|-------|------|
| `knowledge-skill` | 主流程：建立任務資料夾、邊查邊記、產出報告、沉澱知識 |
| `knowledge-record-skill` | 知識沉澱：判斷候選、徵詢同意，再交給 subagent 由 `kb-new.sh`／`kb-promote.sh` 建檔並重建索引 |
| `knowledge-tools-skill` | 維運共用知識庫本體（檢查／整理／重置／收束沉澱／停用取代） |

`knowledge-skill` 與 `knowledge-tools-skill` 需由使用者以 `/knowledge-skill`、`/knowledge-tools-skill` 指令啟動，不會被 AI 自動觸發（front matter 設 `disable-model-invocation: true`）。該欄位僅 Claude Code 支援；Codex 與 GitHub Copilot 依 `description` 的措辭判斷，兩者需一併維護。Codex 另讀各 skill 的 `agents/openai.yaml`，手動啟動的 skill 在其中設 `policy.allow_implicit_invocation: false`。

`knowledge-record-skill` 則相反，**刻意不設**該欄位：知識沉澱要能在任何任務結束時由 AI 自動評估並徵詢，不只在手動啟動 `/knowledge-skill` 之後才發生。它仍可用 `/knowledge-record-skill` 手動啟動，且未取得使用者明確同意絕不寫入知識庫。

徵詢選單可選「本 session 都記錄」，一次同意本 session 後續的候選；開新 session、compaction 或撤回後回到逐次詢問。使用者明確說「記住」「以後都這樣做」時視為同意直接記錄，只有「這個」指向不明才詢問。舊知識過時或原本錯誤時直接改寫，只有衝突才詢問。寫入後只列檔名，並提示刪除與取得完整路徑的說法。

### 快速導覽

| 路徑 | 用途 |
|------|------|
| [skills/knowledge-skill/SKILL.md](skills/knowledge-skill/SKILL.md) | skill 主要執行規格 |
| [skills/knowledge-skill/references/file-structure.md](skills/knowledge-skill/references/file-structure.md) | 任務資料夾、命名規則、範本說明 |
| [skills/knowledge-skill/references/rules.md](skills/knowledge-skill/references/rules.md) | 執行規則、反模式、分階段任務規範 |
| [skills/knowledge-skill/references/knowledge-base.md](skills/knowledge-skill/references/knowledge-base.md) | 知識庫 MADR 格式、收錄判準、覆蓋／停用機制（單一規範來源） |
| [skills/knowledge-skill/assets/](skills/knowledge-skill/assets/) | `prompt.md`、`task_plan.md`、`notes.md` 等範本 |
| [skills/knowledge-skill/scripts/](skills/knowledge-skill/scripts/) | 初始化與驗證腳本 |
| [skills/knowledge-record-skill/SKILL.md](skills/knowledge-record-skill/SKILL.md) | 知識沉澱流程規格（可由 AI 自動觸發） |
| [skills/knowledge-record-skill/references/delegate.md](skills/knowledge-record-skill/references/delegate.md) | 建檔交給 subagent 的分工與交派 prompt 範本 |
| [skills/knowledge-tools-skill/SKILL.md](skills/knowledge-tools-skill/SKILL.md) | 知識庫輔助工具規格 |
| [scripts/init-injection.sh](scripts/init-injection.sh) | 將共用知識庫指引注入其他專案的 `AGENTS.md` / `CLAUDE.md` / `GEMINI.md` |
| [scripts/init-knowledge-base.sh](scripts/init-knowledge-base.sh) | 建立共用知識庫 `knowledge/` 與 `index.md` |
| [scripts/uninstall-knowledge-base.sh](scripts/uninstall-knowledge-base.sh) | 反向移除設定檔與注入區塊（改檔前備份）；知識庫目錄只印出位置，不代為刪除 |

---

## 安裝與使用

### 步驟一：安裝 Skill

**方法 A：`ai-global add-skill`（推薦）**

[ai-global](https://github.com/lazyjerry/ai-global) 會 `git clone` 本 repo、掃描 `skills/` 下的 `knowledge-skill`、`knowledge-record-skill` 與 `knowledge-tools-skill`，安裝至 `~/.ai-global/skills/`，再以 symlink 同步到各 AI 工具：

```bash
ai-global add-skill lazyjerry/knowledge-skill-public  # 列出找到的 skill 並請你確認安裝
ai-global relink                               # 首次安裝後建立 symlink，同步到各工具
```

只接受 `user/repo` 格式，不支援子路徑；`relink` 後 `~/.ai-global/skills/` 的內容自動同步至支援的 AI 工具。

**方法 B：手動遠端安裝**

未使用 ai-global 時，clone 後把 `skills/` 下三個 skill 複製到目標 AI 工具的 skills 目錄（如 Claude Code 的 `~/.claude/skills/`）：

```bash
tmp=$(mktemp -d)
git clone --depth 1 https://github.com/lazyjerry/knowledge-skill-public "$tmp"
cp -R "$tmp"/skills/knowledge-skill "$tmp"/skills/knowledge-record-skill "$tmp"/skills/knowledge-tools-skill ~/.claude/skills/
rm -rf "$tmp"
```

`knowledge-record-skill` 只負責判斷什麼值得記與寫 MADR 內容：範本取自 `knowledge-skill/assets/knowledge.md`，完整收錄判準指向 `knowledge-skill/references/knowledge-base.md`，建檔與索引一律呼叫 `knowledge-tools-skill` 的 `kb-new.sh`、`kb-promote.sh`、`kb-supersede.sh`。它不留任何副本，因此三者**必須並存安裝**。

徵詢同意之後的建檔與矛盾比對，`knowledge-record-skill` 會交給 subagent（Claude Code 內建的 `general-purpose`），讀索引與既有知識的內容不佔主對話的 context。判斷候選與徵詢留在主對話：subagent 看不到對話記錄，Claude Code 也不讓 subagent 使用 `AskUserQuestion`。這個 subagent 不需要另外安裝；不能派 subagent 的工具改由主代理照原步驟執行。

下列步驟的 `sh scripts/...` 命令需在本機 repo 內執行；若未完整 clone，改用「遠端執行」小節的方式。步驟二、三也可以只用已安裝的 skill 完成，不必 clone repo（見各步驟的方法 A）。

### 步驟二：注入共用知識庫指引

讓既有專案或全域 AI 指令檔先參考共用知識庫。注入的區塊會寫入當下解析到的知識庫位置；要放在非預設位置，先做步驟三再回來注入。

**方法 A：用 skill 內建的 `kb-injection.sh`（推薦，裝完 skill 即可用）**

在 Claude Code 輸入 `/knowledge-tools-skill`，選「維護與設定」→ `injection`：代理會列出全域指令檔的狀態，逐份取得同意後注入或更新。

也可以直接執行。腳本路徑依安裝方式而定：用 ai-global 安裝在 `~/.ai-global/skills/`，手動安裝到 Claude Code 則在 `~/.claude/skills/`。

```bash
KB_TOOLS=~/.ai-global/skills/knowledge-tools-skill/scripts
sh "$KB_TOOLS/kb-injection.sh" list                                     # 唯讀：列出全域指令檔狀態
sh "$KB_TOOLS/kb-injection.sh" inject ~/.claude/CLAUDE.md --yes         # 無區塊：插在檔頭
sh "$KB_TOOLS/kb-injection.sh" inject ~/.codex/AGENTS.md --create --yes # 未建立：建立後注入
```

- `list` 檢查 `~/.codex/AGENTS.md`、`~/.claude/CLAUDE.md`、`~/.gemini/GEMINI.md`（Antigravity CLI）、`~/.ai-global/AGENTS.md`，狀態分「最新／需更新／無區塊／未建立」，並印出各狀態該用的命令。
- `inject` 把區塊插在檔頭、原內容接在其後，改檔前備份為 `<檔案>.knowledge-skill.bak.<timestamp>`；已有區塊則不動，落後時改用 `update`。
- `--create` 只建立上述四個全域指令檔，且工具目錄（如 `~/.codex/`）要已存在；專案目錄的指令檔不會憑空建立。
- 指令檔是 symlink 時（例如 ai-global 把 `~/.claude/CLAUDE.md` 連到 `~/.ai-global/AGENTS.md`），寫入連結目標，symlink 保留。
- 專案的指令檔也能注入，一次一份：`sh "$KB_TOOLS/kb-injection.sh" inject /path/to/project/AGENTS.md --yes`。

**方法 B：repo 的 `init-injection.sh`（未安裝 skill，或要一次注入專案目錄下三個檔）**

```bash
sh scripts/init-injection.sh
```

未提供目標路徑時，腳本會檢查常用 AI 工具全域指令檔是否存在，再列出可注入的選項：`~/.codex/AGENTS.md`、`~/.claude/CLAUDE.md`、`~/.gemini/GEMINI.md`（Antigravity CLI）、`~/.ai-global/AGENTS.md`。

也可以指定專案或單一檔案：

```bash
sh scripts/init-injection.sh /path/to/project          # 更新該目錄下的 AGENTS.md、CLAUDE.md、GEMINI.md
sh scripts/init-injection.sh /path/to/project CLAUDE.md # 只允許 AGENTS.md / CLAUDE.md / GEMINI.md
```

只更新既有檔案，不存在則略過。注入內容以 `knowledge-skill:shared-kb` marker 包夾，可重複執行；已存在同名區塊不覆蓋、不重複追加。

區塊本身改版時（例如索引結構演進後），用 `--refresh` 就地更新落後的區塊，旗標須放在第一個參數：

```bash
sh scripts/init-injection.sh --refresh /path/to/project           # 更新該目錄下既有區塊
sh scripts/init-injection.sh --refresh ~/.claude/CLAUDE.md        # 或指定單一檔案
```

`--refresh` 只置換標記之間的內容，保留區塊在檔案中的原位置、其餘內容不動，改檔前先備份為 `<檔案>.knowledge-skill.bak.<timestamp>`；已是現行版本則不動檔案。不帶旗標時仍維持既有區塊不覆蓋。日常維運全域指令檔請改用 `kb-tools` 的功能 9（見下），該腳本隨 skill 一起安裝。

### 步驟三：建立共用知識庫

`init-injection.sh` 只讓各專案「指向」知識庫，不建立本體。實際的 `knowledge/` 與 `index.md` 用此腳本初始化：

```bash
sh scripts/init-knowledge-base.sh          # 互動詢問位置，Enter 採用預設 ~/.knowledge-skill/
sh scripts/init-knowledge-base.sh ~/my-kb  # 直接指定位置
```

- 安裝位置為 `knowledge/` 的上層目錄；知識庫位置指向 `<安裝位置>/knowledge`
- 使用**非預設位置**時，腳本把 `KNOWLEDGE_BASE_DIR=<位置>` 寫入設定檔 `~/.config/knowledge-skill/config`，不再改 shell 設定檔；暫存區路徑（`/tmp`、`/var/folders`）會被拒絕寫入
- 可重複執行：`index.md` 已存在不覆蓋；設定檔已有 `KNOWLEDGE_BASE_DIR` 不重複寫入、也不覆蓋
- 偵測到舊版留在 `~/.zshrc`、`~/.zshenv`、`~/.bashrc`、`~/.profile` 的 `KNOWLEDGE_BASE_DIR` 時只提示移除（環境變數會蓋過設定檔），不自動修改

`init-session.sh` 在初始化任務時也會自動補建缺少的 `index.md`；本步驟適用於想先單獨建好、或安裝到自訂位置並一併寫入設定檔。

只裝了 skill、使用預設位置 `~/.knowledge-skill/` 時，也可以用 `/knowledge-tools-skill` 的 `setup`（或 `sh "$KB_TOOLS/kb-ensure-setup.sh" --yes`，`KB_TOOLS` 見步驟二）建立知識庫目錄、六個分類目錄與 `index.md`，不必 clone repo。自訂位置仍請用上面的 `init-knowledge-base.sh` 寫入設定檔。

### 步驟四：初始化任務

```bash
sh skills/knowledge-skill/scripts/init-session.sh /path/to/workspace 任務名稱 ai-memory-optimization
```

腳本在工作區建立任務資料夾，並在全域路徑建立／確認公用知識庫：

```text
# 專案內
docs/knowledge-skill/
└── 任務名稱-001/
    ├── prompt.md   # 使用者原始需求與背景        （任務開始）
    ├── task_plan.md # 目標、階段、待辦、狀態、錯誤（續作時先讀，階段完成後更新）
    ├── notes.md    # 搜尋過程、發現、判斷、證據   （每階段完成先更新）
    └── report-<任務名稱英文>.md  # 最終交付物     （任務完成）

# 全域（所有專案共用，預設 ~/.knowledge-skill/，可用 KNOWLEDGE_BASE_DIR 覆寫）
$HOME/.knowledge-skill/knowledge/
├── index.md              # 頂層索引：只列分類目錄與各分類知識標題
└── {分類}/{語言-框架}/
    ├── index.md          # 分類子索引：完整的觸發時機與摘要
    └── [topic].md        # 知識檔
```

任務名稱：繁體中文簡述目的；票號可作前綴（例 `T-0001-AI_工具記憶優化`）；空格與特殊字元改 `_`；同名依序建立 `-001`、`-002`。報告檔名另用網址式 kebab-case 英文 slug（例 `report-ai-memory-optimization.md`），由 `init-session.sh` 的第三個參數傳入並驗證。完整規則見 [file-structure.md](skills/knowledge-skill/references/file-structure.md)。

### 工作流程

```text
分析需求 → 啟動提問 → 建立任務資料夾 → 填寫 prompt.md → 建立 task_plan.md
→ （選擇先確認時）補研究計畫並等待確認 → 依階段執行
→ 先更新 notes.md → 再更新 task_plan.md → 必要時建立 knowledge → 產出 report-<任務名稱英文>.md → 完成驗證 → 輸出報告路徑
```

任務開始前先彙整五題預設值，用選單詢問「全部採用預設 / 逐項調整」；選「逐項調整」才逐題詢問：

- **票號／編號**：先推斷，再提供〔推斷票號〕／沒有票號／自行輸入
- **執行模式**：一次完成 / 分階段 / 部分執行
- **報告保存路徑**：預設 `<工作區>/docs/knowledge-skill/<任務名稱>-<流水號>/`，可自訂
- **是否先確認研究計畫**：選「是」會在 `task_plan.md` 補詳細研究計畫，確認後才產出完整報告
- **作者**：預設取工作區的 `git config user.name`，可自行輸入

票號、執行模式、研究計畫確認與作者會記進 `task_plan.md` 的「報告 meta」，產出報告時放在 `report-<任務名稱英文>.md` 開頭成為 YAML meta（另含建立日期與留空的遠端連結）。欄位見 [file-structure.md](skills/knowledge-skill/references/file-structure.md) 的「報告 YAML meta」。

### 原生互動選單

固定選項優先使用 AI client 提供的原生工具；只有工具不可用時才退回文字編號：

| Client | 原生工具 | 顯示方式 |
|--------|----------|----------|
| Claude Code VSCode／互動 CLI | `AskUserQuestion` | extension 對話框／CLI TUI |
| Codex Plan mode | `request_user_input` | extension 選項面板／CLI TUI |
| Codex Default mode | `request_user_input`（需 client 提供工具） | 預設未啟用時使用文字 fallback |

Codex 可選擇自行開啟實驗功能；本 skill 不會代為修改設定：

```bash
codex features enable default_mode_request_user_input
```

修改後開新 session。此功能仍是 `under development`，不是必要依賴。VSCode integrated terminal 仍屬 CLI TUI；`claude -p`、`codex exec` 等非互動模式不承諾顯示選單。

共通行為：

- 每題最多三個固定選項（`knowledge-record-skill` 的多項候選那題例外，為四個）；較大選單拆成兩層。
- 無上限清單逐筆顯示「選擇此項／下一項／取消」。
- 只有自訂票號、路徑、檔名或修改意見需要自由文字。
- 原生工具不可用時會說明 client 限制，再顯示文字編號。

### 關鍵規則

| 規則 | 做法 |
|------|------|
| 先計劃再執行 | 沒有 `task_plan.md` 不開始長任務 |
| 續作先讀 | 分階段任務每次對話開始時讀 `task_plan.md` 與 `notes.md` |
| 先記後標 | 先更新 `notes.md`，再勾選 `task_plan.md` |
| 錯誤留痕 | 失敗原因與處理方式寫入 `task_plan.md` |
| 大量內容寫檔 | 長輸出、搜尋結果、研究材料放進檔案 |
| 知識可重用才保存 | 跨專案可重用經驗才寫入公用 `knowledge/` |
| 完成前驗證 | 任務結束前跑驗證腳本 |

### 驗證

```bash
# 初始化後檢查任務檔案
sh skills/knowledge-skill/scripts/validate-task-files.sh docs/knowledge-skill/任務名稱-001
# 完成前檢查必要檔案
sh skills/knowledge-skill/scripts/validate-task-completion.sh /path/to/workspace 任務名稱-001
```

### 分階段任務

若任務無法一次完成，`task_plan.md` 應記錄：執行模式、已完成項目、下一個未完成項目、上次進度摘要、未解決的錯誤或 blocker。下次對話先讀取 `task_plan.md` 與 `notes.md`，再接續未完成項目。

### KNOWLEDGE_BASE_DIR 設定

所有腳本依同一順序解析知識庫位置：環境變數 `KNOWLEDGE_BASE_DIR` > 設定檔 `~/.config/knowledge-skill/config` > 預設 `$HOME/.knowledge-skill/knowledge`。`kb-tools.sh status` 會顯示實際採用的來源。

固定使用自訂路徑時寫入設定檔（`init-knowledge-base.sh` 指定非預設位置時會自動寫入）。hook、launchd 這類不讀 shell 設定檔的執行環境也能解析到同一位置：

```bash
# ~/.config/knowledge-skill/config
KNOWLEDGE_BASE_DIR=~/.knowledge-skill/knowledge
```

設定檔不會被 source，只取最後一行 `KNOWLEDGE_BASE_DIR=`；值可加引號或 `export` 前綴，開頭的 `~` 或 `$HOME` 會展開，其餘不做 shell 展開。

環境變數只用於臨時覆寫，例如單次初始化：

```bash
KNOWLEDGE_BASE_DIR="$HOME/.knowledge-skill/knowledge" sh skills/knowledge-skill/scripts/init-session.sh /path/to/workspace 任務名稱 ai-memory-optimization
```

在 Claude Code sandbox 中若使用工作區外路徑，需確認可寫；否則將 `$HOME/.knowledge-skill` 加入 `permissions.additionalDirectories`，或改用已允許寫入的路徑。

### 知識庫放在 Dropbox 時：索引不參與同步

把 `~/.knowledge-skill` symlink 進 Dropbox，就能讓多台裝置共用同一份知識庫。知識檔適合同步——檔名唯一、寫一次就不太會再動；索引不適合。

**問題**

各層 `index.md` 是每次建檔、刪除、取代都會整份覆寫的檔案。兩台裝置先後寫入，Dropbox 會把其中一份改名成 `index (與 <帳號> 衝突的複本 <日期>).md`，實際遇過的後果：

- 原本的 `index.md` 消失，之後本機每次寫入又立刻被改名成新的衝突複本，重跑 `reindex` 也救不回來。
- 代理依指引「動工前先讀 `index.md`」卻讀不到，會當成沒有相關知識直接動工，過程中沒有任何錯誤訊息。
- 衝突複本是放在知識庫根目錄的 `.md`，下一次 `reindex` 會把它登錄成「未分類知識」。

**作法**

索引是衍生物，任何一台裝置都能從知識檔重建，所以不進同步：

- `kb-reindex.sh` 每次執行都會把各層 `index.md` 標記為 Dropbox 忽略（同時設 `com.apple.fileprovider.ignore#P` 與 `com.dropbox.ignored` 兩個延伸屬性，分別對應 File Provider 版與舊版 Dropbox）。知識庫不在 Dropbox 裡時，這兩個屬性沒有任何作用。
- 忽略標記是每台裝置各自的設定。一台裝置標記後，Dropbox 會把該檔從雲端與其他裝置移除，因此其他裝置會看到索引消失——這是預期行為，在那台跑一次 `reindex` 即可：

  ```bash
  sh skills/knowledge-tools-skill/scripts/kb-tools.sh reindex
  ```

- 缺 `index.md` 不再被視為結構缺失：只要六個分類目錄（`ui`／`ux`／`dev`／`ops`／`data`／`else`）都在，`reindex` 就會直接重建；`init-session.sh` 發現缺索引時也會自動呼叫 `reindex`。分類目錄不齊時仍以結束碼 `1` 中止，避免 `KNOWLEDGE_BASE_DIR` 指錯時在無關目錄裡產生一堆 `index.md`。
- 在別台裝置新增知識後，本機索引不會自動更新；`kb-tools.sh status` 會回報孤兒檔，跑 `reindex` 補登錄。

**多台裝置的升級順序**

每台裝置的 skill 都要先更新到含此行為的版本，再執行任何會寫索引的操作。還停在舊版的裝置寫出的索引沒有忽略標記，會同步到其他裝置，和已標記忽略的本機索引撞名，可能再次產生衝突複本（此情境尚未實測）。

**限制**

- 目前只處理 macOS。Linux、Windows 的 Dropbox 用不同方式設定忽略屬性，需自行設定。
- 只涵蓋 Dropbox。iCloud Drive、OneDrive 沒有對應的單檔忽略機制。
- 已存在的衝突複本不會自動清除：確認內容無需保留後自行移走，再跑一次 `reindex`。

### 遠端執行

不 clone repo 也能直接執行 `scripts/` 下的腳本。取得方式對所有腳本相同，差異只在如何餵給 `sh`；執行前建議先打開該網址看過內容：

```bash
# 帶參數（pipe 會佔用 stdin，互動詢問失效，請用參數帶入位置）
curl -fsSL https://raw.githubusercontent.com/lazyjerry/knowledge-skill-public/main/scripts/init-injection.sh \
  | sh -s -- /path/to/project

# 需要互動選單時改用 sh -c，保留終端輸入
sh -c "$(curl -fsSL https://raw.githubusercontent.com/lazyjerry/knowledge-skill-public/main/scripts/init-injection.sh)"
```

`init-knowledge-base.sh` 遠端執行時抓不到 repo 範本，會改用內嵌備援範本，`index.md` 內容一致。

---

## 二次開發

維護本 repo 本體：知識庫維運工具與版本號。

### 知識庫輔助工具 `kb-tools`

`knowledge-tools-skill` 以單一進入點 `kb-tools.sh` 提供互動選單與子命令。固定流程都由 shell 腳本完成，代理只負責路由與取得不可逆操作的同意。

```sh
# 代理入口：只印選單，永不讀取 stdin
sh skills/knowledge-tools-skill/scripts/kb-tools.sh menu

# 人類 CLI：無參數時在 TTY 讀取一個選項
sh skills/knowledge-tools-skill/scripts/kb-tools.sh

# 也可直接帶子命令
sh skills/knowledge-tools-skill/scripts/kb-tools.sh status
```

代理把十二項功能拆成「檢查與索引／維護與設定／知識內容與候選」兩層原生選單。刪除候選使用 `sh skills/knowledge-tools-skill/scripts/kb-delete.sh list`，即使 stdin 是 TTY 也只列出、不讀取選擇。不可逆操作先取得原生確認，再傳入 `--yes`。

知識檔以 **MADR 格式**、依分類目錄（`ui`/`ux`/`dev`/`ops`/`data`/`else`，第二層依語言／框架）遞迴存放。索引分兩層：頂層 `index.md` 只列分類目錄與各分類的知識標題，完整的觸發時機與摘要在各分類的 `{分類}/index.md`——代理逐層下探，讓每次動作前的固定讀取不隨知識庫變大而持續吃掉 context。已停用（被取代）的知識移入 `deprecated/`，該處為同構的兩層索引。格式與規範以 [knowledge-base.md](skills/knowledge-skill/references/knowledge-base.md) 為單一來源。

| 子命令 | 改檔 | 說明 |
|--------|------|------|
| `menu` | 否 | 只印出功能選單並結束，供代理以原生選單路由 |
| `status` | 否 | 檢查實際位置與健康度，遞迴列出斷鏈與孤兒檔，回報 `deprecated/` 數量。結束碼 `0` 健康／`1` 結構缺失／`2` 有差異 |
| `health [--format text\|json] [--source cli\|tray\|ui]` | 僅 log | 依 MADR 規範檢查生效內容、停用索引與取代關係。結束碼 `0` 健康／`1` 錯誤／`2` 有不健康項目；結果存於 `~/.knowledge-skill/logs/health/` |
| `reindex` | 是 | 依各知識檔 front matter 與 `## 摘要` 確定性重建兩層索引（頂層與各分類 `index.md`，含 `deprecated/`）；改檔前自動備份，無變更則略過，並清除已無知識檔的分類子索引。缺 `index.md` 但分類目錄齊全時直接重建；各層索引會標記為 Dropbox 忽略（見「知識庫放在 Dropbox 時」） |
| `sync <pull\|push> <路徑> [--dry-run] [--overwrite] [--yes]` | 是 | 與另一份指定位置的知識庫**單向**搬運知識檔（`pull` 對方→本機，`push` 本機→對方）。合併語意：只新增不刪除，含 `deprecated/`；索引不複製，收尾在接收端 `reindex`。同路徑不同內容視為衝突，預設略過（結束碼 `2`），`--overwrite` 才覆蓋並備份原檔。需授權 |
| `setup [--dry-run] [--yes]` | 是 | 確認本機設定是現行做法：把舊版寫在 shell 設定檔的 `KNOWLEDGE_BASE_DIR` 搬到 `~/.config/knowledge-skill/config` 並從 rc 移除（改前備份），再確保知識庫目錄、六個分類目錄與 `index.md` 齊全，新裝置跑一次就能用。衝突、無法解析的值，或位置落在暫存區時不動（結束碼 `2`）；建立失敗為結束碼 `1`。適合放進升級腳本每次執行。需授權 |
| `reset [--yes]` | 是 | ⚠️ 不可逆。先 `tar.gz` 備份整個 knowledge 至外部 `backups/`，驗證後清空並重建分類骨架與空索引。需授權 |
| `curate` | 否 | 只印出整理知識內容的導引：沉澱（`consolidate`／`new`／`promote`）、盤點矛盾（`reconcile`）、取代舊知識（`supersede`） |
| `consolidate [路徑]` | 否 | 掃描指定路徑（預設目前目錄）下 `docs/knowledge-skill/` 任務資料夾，列出可沉澱的 `notes.md`／`report-<任務名稱英文>.md` 候選 |
| `delete [編號/相對路徑] [--yes]` | 是 | 遞迴列出知識條目並刪除指定單一知識檔，刪後自動 `reindex`。無參數僅列出；刪除 ⚠️ 不可逆，需授權 |
| `injection [list [路徑]\|inject <檔案> [--create] [--yes]\|update <檔案> [--yes]]` | `inject`、`update` | 檢視各 AI 指令檔的 `knowledge-skill:shared-kb` 區塊是否為現行版本（最新／需更新／無區塊／未建立）；`inject` 首次注入（插在檔頭，`--create` 可建立缺少的全域指令檔），`update` 就地更新落後的區塊、保留原位置。改檔前備份、保留 symlink，需授權 |
| `repair [--dry-run] [--yes] [相對路徑...]` | 是 | 修復健康檢查中修法唯一的問題：回填斷裂的取代關係、補上缺少的 `取代`／`被取代於` 欄位，收尾自動 `reindex`。需語意判斷的項目一律不動、只列出。`--dry-run` 唯讀；改檔前備份，需授權 |
| `reconcile [分類前綴]` | 否 | 盤點矛盾：遞迴列出生效知識的路徑、標題、觸發時機、摘要、決策結果，供比對新舊衝突 |
| `supersede <舊> <新> [--yes]` | 是 | 以新知識取代舊知識：寫入取代關係、把舊檔移入 `deprecated/` 後自動 `reindex`。需授權 |
| `import <tool> [來源] [--write]` | 預設否 | read-only 匯入 Claude／Codex／Copilot 記憶為候選任務資料夾（預設 dry-run，只統計不落地）；命中機密自動排除 |
| `new <相對路徑> [--out <草稿路徑>]` | 否 | 從 canonical MADR 範本產生知識草稿供填寫，不寫入知識庫。路徑不合法或目標已存在即中止；stdout 最後一行是草稿路徑 |
| `promote <候選> <相對路徑> [--yes] [--source <來源說明>]` | 是 | 把審核通過的候選 MADR 安裝成生效知識，自動 `reindex`。目標已存在則拒絕覆蓋。需授權。`--source` 覆寫 provenance 來源（草稿在暫存目錄時用得上） |

```bash
sh skills/knowledge-tools-skill/scripts/kb-tools.sh reindex
sh skills/knowledge-tools-skill/scripts/kb-tools.sh health --format json --source cli
sh skills/knowledge-tools-skill/scripts/kb-tools.sh sync pull /Volumes/USB/knowledge --dry-run   # 唯讀：先看搬運計畫
sh skills/knowledge-tools-skill/scripts/kb-tools.sh sync push /Volumes/USB/knowledge --yes
sh skills/knowledge-tools-skill/scripts/kb-tools.sh reset --yes
sh skills/knowledge-tools-skill/scripts/kb-tools.sh consolidate /path/to/project
sh skills/knowledge-tools-skill/scripts/kb-tools.sh delete dev/ai-llm/x.md --yes
sh skills/knowledge-tools-skill/scripts/kb-tools.sh injection list                        # 唯讀：檢視全域指令檔狀態
sh skills/knowledge-tools-skill/scripts/kb-tools.sh injection update ~/.claude/CLAUDE.md --yes
sh skills/knowledge-tools-skill/scripts/kb-tools.sh injection inject ~/.codex/AGENTS.md --create --yes  # 首次注入，缺檔時建立
sh skills/knowledge-tools-skill/scripts/kb-tools.sh new dev/ai-llm/x.md                   # 產草稿，填完再 promote
sh skills/knowledge-tools-skill/scripts/kb-tools.sh reconcile dev
sh skills/knowledge-tools-skill/scripts/kb-tools.sh supersede dev/ai-llm/old.md dev/ai-llm/new.md --yes
sh skills/knowledge-tools-skill/scripts/kb-tools.sh import claude              # dry-run：掃描 ~/.claude/projects/*/memory
sh skills/knowledge-tools-skill/scripts/kb-tools.sh import codex --write       # 確認後產生候選資料夾
sh skills/knowledge-tools-skill/scripts/kb-tools.sh import copilot --from-file facts.md --write
sh skills/knowledge-tools-skill/scripts/kb-tools.sh promote docs/knowledge-skill/記憶候選_claude-001/madr.md dev/ai-llm/x.md --yes
```

`import` 是 read-only adapter：唯讀掃描 Claude Code／Codex／GitHub Copilot 記憶，把跨專案可重用內容轉成候選任務資料夾（只存摘要與來源 metadata，不複製 vendor 全文），預設 dry-run、命中機密樣式自動排除；GitHub Copilot 無公開 export API，須以 `--from-file` 指定整理後的檔案。候選經 `consolidate` 列舉、人工審核、建立 MADR 後，再以 `promote` 確定性安裝成生效知識。詳見 [import.md](skills/knowledge-tools-skill/references/import.md)。

備份檔（`knowledge-backup-<時戳>.tar.gz`、`index-backup-<時戳>.md`、`deprecated-index-backup-<時戳>.md`）放在 knowledge 之外的 `backups/`（預設 `~/.knowledge-skill/backups/`），不會被重置波及。「收束沉澱」判斷可重用內容並建檔、以及「盤點矛盾」判斷新舊衝突的步驟由代理執行，僅在使用者明確同意後寫入或停用。範本集中於 `knowledge-skill/assets/`，三個 skill 並存安裝以共用腳本與規範。

兩層 `index.md` 皆由 `reindex` 自動重建（代理不手動編輯）：頂層登錄各分類的筆數與知識標題，分類子索引登錄每份知識的標題、相對路徑、觸發時機、摘要、取代關係，以及創建時間與更新時間（創建時間只存在索引、重建時沿用舊值，舊知識為 `1970-01-01 00:00:00`；更新時間取知識檔 mtime）。每份知識檔在 `## 補充資訊` 記錄來源任務，方便日後判斷是否仍適用；跨專案共用，只對單一專案成立的細節不寫入。

### Skill 版本更新

`knowledge-tools-skill`、`knowledge-skill` 與 `knowledge-record-skill` 的 YAML front matter `version` 要保持一致，升版時三個 `SKILL.md` 一起改。版本格式為無 `v` 前綴的 `MAJOR.MINOR.PATCH`。

---

## 致謝

感謝 [OthmanAdi/planning-with-files](https://github.com/OthmanAdi/planning-with-files)。本 skill 由該專案的概念修改而來，並依繁體中文工作流程、知識庫模式與本地任務驗證需求調整。
