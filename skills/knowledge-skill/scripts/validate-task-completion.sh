#!/bin/sh
# 驗證任務資料夾是否包含完整的必要檔案
# 用法: sh validate-task-completion.sh <工作區路徑> <任務名稱-流水號>
# 範例: sh validate-task-completion.sh /path/to/project attendance-feature-research-001
#
# 必要檔案清單（定義於 file-structure.md）：
#   - prompt.md              使用者提示詞
#   - task_plan.md           任務計劃
#   - notes.md               研究筆記
#   - report-<slug>.md       最終交付物；slug 為網址式 kebab-case，需恰好一份
#                            開頭需帶 YAML meta（欄位見 file-structure.md「報告 YAML meta」）
#
# 產出：
#   - 各必要檔案的檢查結果與任務資料夾內容
#   - 驗證通過時額外印出報告檔的絕對路徑與專案相對路徑，供使用者直接複製

set -e

# ============================================================
# 參數處理
# ============================================================

WORKSPACE_PATH="${1:-.}"
TASK_FOLDER_NAME="${2:-}"

# 必要檔案清單（可透過參數擴展）；報告檔名不固定，另以 glob + 命名規則檢查
REQUIRED_FILES="prompt.md task_plan.md notes.md"
REPORT_PATTERN='^report-[a-z0-9]+(-[a-z0-9]+)*\.md$'

# 報告 YAML meta 必要欄位；值可為空（遠端連結、票號），但鍵要在
REPORT_META_FIELDS="日期 作者 遠端連結 票號 執行模式 研究計畫確認"

# 以 sed + grep 比對而非 awk：macOS 內建 awk 比較多位元組字串不可靠
check_report_meta() {
    report="$1"
    name="$(basename "$report")"
    if [ "$(head -n 1 "$report")" != "---" ] || ! sed -n '2,$p' "$report" | grep -q '^---$'; then
        echo "❌ ${name} （開頭缺少 YAML meta）"
        return 1
    fi
    meta="$(sed -n '2,/^---$/p' "$report")"
    missing=""
    for field in $REPORT_META_FIELDS; do
        printf '%s\n' "$meta" | grep -q "^${field}:" || missing="${missing:+${missing} }${field}"
    done
    if [ -n "$missing" ]; then
        echo "❌ ${name} （YAML meta 缺少欄位：${missing}）"
        return 1
    fi
    return 0
}

# ============================================================
# 驗證參數
# ============================================================

if [ -z "$TASK_FOLDER_NAME" ]; then
    echo "❌ 錯誤：請提供任務資料夾名稱"
    echo ""
    echo "用法: sh validate-task-completion.sh <工作區路徑> <任務名稱-流水號>"
    echo "範例: sh validate-task-completion.sh /path/to/project attendance-feature-research-001"
    exit 1
fi

# 組合完整的任務資料夾路徑
TASK_FOLDER="$WORKSPACE_PATH/docs/knowledge-skill/$TASK_FOLDER_NAME"

# 確保工作區路徑存在
if [ ! -d "$WORKSPACE_PATH" ]; then
    echo "❌ 錯誤：工作區路徑不存在: $WORKSPACE_PATH"
    exit 1
fi

# 確保任務資料夾存在
if [ ! -d "$TASK_FOLDER" ]; then
    echo "❌ 錯誤：任務資料夾不存在: $TASK_FOLDER"
    echo ""
    echo "請確認任務名稱-流水號是否正確: $TASK_FOLDER_NAME"
    exit 1
fi

# ============================================================
# 檔案完整性檢查
# ============================================================

echo "📁 檢查任務資料夾: $TASK_FOLDER_NAME"
echo "   路徑: $TASK_FOLDER"
echo ""

MISSING_COUNT=0
FOUND_COUNT=0

for FILE in $REQUIRED_FILES; do
    FILE_PATH="$TASK_FOLDER/$FILE"
    
    if [ -f "$FILE_PATH" ]; then
        # 檢查檔案是否為空
        if [ -s "$FILE_PATH" ]; then
            echo "✅ $FILE"
            FOUND_COUNT=$((FOUND_COUNT + 1))
        else
            echo "⚠️  $FILE （檔案為空）"
            MISSING_COUNT=$((MISSING_COUNT + 1))
        fi
    else
        echo "❌ $FILE （檔案不存在）"
        MISSING_COUNT=$((MISSING_COUNT + 1))
    fi
done

# ============================================================
# 報告檔檢查（檔名帶任務英文名稱，需恰好一份且命名合格）
# ============================================================

REPORT_NAME=""
REPORT_COUNT=0

# POSIX sh 在 glob 無匹配時會保留字面值，必須以 -e 過濾
for FILE_PATH in "$TASK_FOLDER"/report-*.md; do
    [ -e "$FILE_PATH" ] || continue
    REPORT_COUNT=$((REPORT_COUNT + 1))
    REPORT_NAME="$(basename "$FILE_PATH")"
done

if [ "$REPORT_COUNT" -eq 0 ]; then
    echo "❌ 缺少報告檔（需 report-<任務名稱英文>.md）"
    if [ -f "$TASK_FOLDER/report.md" ]; then
        echo "   偵測到舊格式的 report.md，請改名為 report-<任務名稱英文>.md"
    fi
    echo "   命名規則：小寫英文、數字與單一連字號，例 report-ai-memory-optimization.md"
    MISSING_COUNT=$((MISSING_COUNT + 1))
elif [ "$REPORT_COUNT" -gt 1 ]; then
    echo "❌ 報告檔不只一份（找到 $REPORT_COUNT 份），請只保留一份："
    for FILE_PATH in "$TASK_FOLDER"/report-*.md; do
        [ -e "$FILE_PATH" ] || continue
        echo "   - $(basename "$FILE_PATH")"
    done
    MISSING_COUNT=$((MISSING_COUNT + 1))
elif ! printf '%s' "$REPORT_NAME" | grep -Eq "$REPORT_PATTERN"; then
    echo "❌ $REPORT_NAME （檔名格式錯誤）"
    echo "   需為 report-<任務名稱英文>.md：小寫英文、數字與單一連字號，"
    echo "   不可有開頭／結尾連字號，也不可連續連字號"
    MISSING_COUNT=$((MISSING_COUNT + 1))
elif [ ! -s "$TASK_FOLDER/$REPORT_NAME" ]; then
    echo "⚠️  $REPORT_NAME （檔案為空）"
    MISSING_COUNT=$((MISSING_COUNT + 1))
elif ! check_report_meta "$TASK_FOLDER/$REPORT_NAME"; then
    echo "   欄位見 file-structure.md「報告 YAML meta」，值取自 task_plan.md 的「報告 meta」"
    MISSING_COUNT=$((MISSING_COUNT + 1))
else
    echo "✅ $REPORT_NAME"
    FOUND_COUNT=$((FOUND_COUNT + 1))
fi

# ============================================================
# 輸出結果
# ============================================================

echo ""
TOTAL_FILES=$(( $(echo $REQUIRED_FILES | wc -w | tr -d ' ') + 1 ))

if [ "$MISSING_COUNT" -eq 0 ]; then
    echo "✅ 任務檔案完整 ($FOUND_COUNT/$TOTAL_FILES)"
    echo ""
    echo "📋 任務資料夾內容："
    ls -la "$TASK_FOLDER"

    # 路徑另起一行、不加裝飾字元，方便終端機直接選取複製
    TASK_FOLDER_ABS=$(CDPATH= cd -- "$TASK_FOLDER" && pwd)
    echo ""
    echo "📄 報告路徑（可複製）："
    echo "$TASK_FOLDER_ABS/$REPORT_NAME"
    echo "docs/knowledge-skill/$TASK_FOLDER_NAME/$REPORT_NAME"
    exit 0
else
    echo "❌ 任務檔案不完整 ($FOUND_COUNT/$TOTAL_FILES)"
    echo ""
    echo "缺少 $MISSING_COUNT 個必要檔案，請補齊後再次驗證。"
    exit 1
fi
