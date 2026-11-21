# 功能 5-1：收束沉澱（從任務資料夾）

把各專案 `docs/knowledge-skill/` 任務資料夾的成果，篩選沉澱成共用知識檔。前置（格式檢查、候選列舉）與後置（索引重建）走腳本；中間「判斷可重用、寫成知識檔」由代理執行。

## 步驟

### 1. 取得來源路徑

詢問使用者來源路徑，預設目前工作區根目錄。可指定：

- 專案根目錄（腳本自動找其下的 `docs/knowledge-skill`）
- 直接指定 `docs/knowledge-skill` 路徑

### 2. 格式檢查與候選列舉（kb-consolidate.sh）

```bash
sh <SKILL_DIR>/scripts/kb-tools.sh consolidate <來源路徑>
```

腳本對每個任務資料夾檢查必要檔（`prompt.md task_plan.md notes.md`）是否存在且非空，並確認恰有一份命名合格的 `report-<任務名稱英文>.md`（`^report-[a-z0-9]+(-[a-z0-9]+)*\.md$`）：

- `✅ 合格`：列出其 `notes.md`、`report-<任務名稱英文>.md` 作為候選來源
- `⚠️ 缺檔`：列出缺少項目，不納入候選

結束碼：`0` 有合格候選 / `1` 路徑或格式不符 / `2` 有任務資料夾但全部缺檔。

### 2.1 原生候選選擇

- 只有一項候選：詢問「沉澱／略過」。
- 有多項候選：先詢問「全部沉澱／逐項決定／全部略過」。
- 逐項決定：逐筆顯示來源與摘要，詢問「選擇此項／下一項／取消」。
- `AskUserQuestion`／`request_user_input` 不可用時，才列出編號要求文字回覆。

### 3. 判斷與建檔（代理執行）

讀取候選來源檔，依公用知識庫收錄判準篩選：

**✅ 收錄**：跨專案可重用的工作方法、解決方案、經互動修正後仍適用的重要事項、使用者明確要求記住的原則。

**❌ 不收**：一般程式設計知識、框架標準用法、官方文件已說明、僅對單一專案成立的細節（特定檔案路徑／服務設定）、一次性結果。

> 判準與 MADR 格式、覆蓋／停用機制的完整規範見 `knowledge-skill/references/knowledge-base.md`（**單一規範來源**）。記錄前先自問：**換到別的專案是否仍成立？**

建檔規則：

- **選擇分類**：歸入正確分類目錄 `knowledge/{分類}/{語言-框架}/[topic].md`（頂層 `ui`/`ux`/`dev`/`ops`/`data`/`else`，第二層依語言或框架）。
- **相同主題**：直接編輯既有知識檔合併，不重複建檔；改完執行 `reindex`。
- **新主題**：由腳本產草稿（自 canonical 範本 `knowledge-skill/assets/knowledge.md`）並安裝，代理只填內容：
  ```bash
  sh <SKILL_DIR>/scripts/kb-tools.sh new <分類>/<語言-框架>/<topic>.md
  # 填寫草稿：front matter 的 標題／觸發時機，並在 ## 補充資訊 記錄來源任務資料夾
  sh <SKILL_DIR>/scripts/kb-tools.sh promote <草稿路徑> <相對路徑> --yes --source "<來源任務資料夾>"
  ```
  `new` 會擋掉路徑不合法與目標已存在；`promote` 會驗證格式、拒絕覆蓋、原子安裝並自動重建索引。
- front matter 的 `觸發時機:` 與 `## 摘要` 第一行會被 `reindex` 解析進索引，務必寫清楚。
- **新舊矛盾**：若新知識與既有知識在同一觸發情境下相衝突，先 `reconcile` 比對、向使用者確認，再以 `kb-supersede.sh <舊> <新> --yes` 停用舊知識（移入 `deprecated/`）。

> **僅在使用者明確同意後才寫入知識庫。** 原生工具可用時不得要求輸入候選編號；取代確認完成後才傳 `--yes`。

### 4. 重建索引（自動改檔）

`promote` 與 `supersede` 已自動重建索引；只有直接編輯知識檔（合併進既有檔）才需執行，一律不手動編輯 `index.md`：

```bash
sh <SKILL_DIR>/scripts/kb-tools.sh reindex
```

### 5. 驗證

```bash
sh <SKILL_DIR>/scripts/kb-tools.sh status
```

確認無斷鏈／孤兒（結束碼 0）。
