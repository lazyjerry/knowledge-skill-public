# 功能 6：跨工具記憶匯入（import）與功能 7：候選晉升（promote）

把 Claude Code、Codex、GitHub Copilot 的記憶資料沉澱進共用知識庫。**read-only adapter 只產生候選**，正式生效仍需人工審核與明確同意。三層資料（instructions／auto memory／session）分開處理，不直接合併 vendor state。

## 受控沉澱流程

```text
vendor instructions / auto memory / selected session
        ↓ kb-import-<tool>.sh（唯讀、預設 dry-run）
   候選任務資料夾 docs/knowledge-skill/記憶候選_<tool>-NNN/
        ↓ validate-task-completion.sh
   kb-tools.sh consolidate（候選列舉）
        ↓ 人工審核、去重、定 scope、建 MADR
   kb-promote.sh（確定性安裝、需 --yes）
        ↓ reindex → status
   生效共用知識庫
```

## 方法 1（P0）：各工具先產生 task artifacts

不需匯入工具即可使用：在目標工具內以 `knowledge-skill` 把已審核、跨專案可重用的結論寫成完整任務資料夾（`prompt.md`／`task_plan.md`／`notes.md`／`report-<任務名稱英文>.md`），再走現行 `consolidate`。適合資料量小、重視可追溯性。限制：需逐次請工具整理，無法批次掃描既有 vendor memory。

## import 子命令

```bash
sh <SKILL_DIR>/scripts/kb-tools.sh import <claude|codex|copilot> [來源] [--write] [選項...]
```

- **預設 `--dry-run`**：只輸出規模統計（掃描筆數、排除原因、合格候選數、scope 分布），不落地。確認後加 `--write` 才產生候選資料夾。
- **來源選擇**：以原生三選一呈現 Claude Code／Codex／GitHub Copilot；自訂來源路徑才收自由文字。
- **落地確認**：dry-run 後以原生選單詢問「產生候選／保持 dry-run」，確認後才加 `--write`。
- 候選**只存摘要 + evidence 指標，不複製 vendor 全文**：降低體積與洩密面，避免 `consolidate` 時代理 context 爆掉。
- 唯讀來源，**絕不改寫 vendor state**。

### 共用選項

| 選項 | 說明 |
|------|------|
| `--write` | 確認後落地（預設 dry-run） |
| `--limit N` | 候選筆數上限（預設 50）；超過者列為「超過 --limit」 |
| `--scope user\|repository` | 覆寫候選 scope（adapter 各有預設） |
| `--repository owner/name` | 標註 repository |
| `--since <日期>` | 只取該日(含)之後修改的來源；用 `find -newermt`，接受可解析格式（`2024-01-01`、`'Jan 1 2024'`），無法解析時非零退出 |
| `--workspace 路徑` | 候選輸出工作區根（預設目前目錄） |
| `--from-file 路徑` | 指定單一來源檔（Copilot 主要入口） |

### 各 adapter 來源與預設

| tool | 預設來源 | scope 預設 | source_kind | 備註 |
|------|----------|-----------|-------------|------|
| `claude` | `~/.claude/projects/*/memory/*.md` | `repository` | `auto-memory` | 排除 `MEMORY.md` 索引與 `*.jsonl` raw transcript；repository 由 `projects/<seg>` 推導 |
| `codex` | `~/.codex/memories/` | `user` | `vendor-memory` | feature-detect 可讀 `*.md`，不假設固定檔名；無可解析 Markdown 即非零退出 |
| `copilot` | 無（須 `--from-file` 或明確路徑） | `user` | `copilot-memory`／`copilot-session` | 無公開 export API；接受 GitHub UI 整理檔、`/chronicle` 產物或 opt-in session-state；排除 `.db`／`.jsonl` |

> Copilot Memory 與 Copilot CLI session data 是不同來源，候選以 `source_kind` 區分。

## 候選 metadata 欄位

每筆候選在 `report-<tool>-memory-import.md` 以 YAML 區塊保留：

```yaml
source_tool: claude | codex | copilot
source_kind: instruction | auto-memory | vendor-memory | copilot-memory | copilot-session | session-summary
scope: user | repository
repository: owner/name | -
source_id: vendor-specific-id（相對路徑）
source_hash: sha256（正規化內容）
evidence: 指回來源檔（不複製全文）
observed_at: ISO-8601（來源檔 mtime，取不到時回退匯入時間）
status: proposed
```

去重鍵為 `source_hash + scope + repository + source_kind`，記錄於 `docs/knowledge-skill/.import-ledger/<tool>.tsv`。相同來源重跑不重複建立候選。

## 安全與規模門檻

- **secret scan**：private key、`api_key`／`secret`／`token`／`password` 賦值、AWS／GitHub／Slack／Stripe／Google 與 `sk-` 開頭的金鑰樣式、`Bearer` token、帶帳密的連線字串命中即排除，不寫入候選；來源檔讀不到時也一併排除。
- 預設排除 `*.jsonl`、SQLite 與 raw transcript；只收 workflow、decision、pitfall、穩定偏好與跨專案 convention。
- 大量資料：候選只存摘要、`--limit` 設上限、dry-run 先給規模統計，超量時以 `--scope`／`--repository`／`--since` 縮窄再 `--write`。
- 不支援的 schema → 非零退出與明確訊息，不臆測解析。

## promote 子命令（功能 7）

把審核通過的候選 MADR 確定性安裝成生效知識：

```bash
sh <SKILL_DIR>/scripts/kb-tools.sh promote <候選-MADR.md> <knowledge-相對路徑> [--yes]
```

- 驗證 front matter（`標題`／`觸發時機` 非佔位）與必要段落（`## 摘要`／`## 決策結果`）。
- 目標已存在 → 拒絕覆蓋（結束碼 1）；要取代請改用 `supersede`。
- 代理逐筆使用原生選單選候選，取得「確認晉升」後才傳 `--yes`；人類 CLI 仍可互動輸入 `yes`，否則中止（結束碼 3）。
- 原子安裝（`mktemp` + `mv`），於檔尾補 provenance（來源候選與 sha256），再自動 `reindex`，並提示跑 `status`。

### 結束碼

| 碼 | 意義 |
|----|------|
| 0 | 完成 |
| 1 | 參數／格式／結構錯誤或目標已存在 |
| 3 | 未取得授權而中止 |

## 驗收條件

1. `--dry-run` 不修改 vendor state、task folder 或知識庫。
2. 三種 adapter 都有去識別化 fixture 測試。
3. 假 token／password／private key fixture 必須被阻擋。
4. 相同來源重跑不新增重複候選。
5. 不支援的 schema 以非零退出與明確訊息停止。
6. 產出的 task folder 通過 `validate-task-completion.sh`。
7. Promotion 後 `reindex` 與 `status` 通過。
8. 未取得使用者同意時，不建立 knowledge、不執行 promote／supersede。
