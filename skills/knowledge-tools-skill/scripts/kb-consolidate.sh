#!/bin/sh
# kb-consolidate.sh
# 功能：掃描指定路徑下的 knowledge-skill 任務資料夾，檢查資料格式，列出可沉澱的候選來源檔。
#       （唯讀；實際「判斷可重用並建檔」由 AI 依 references/consolidate.md 執行。）
# 用法：sh kb-consolidate.sh [來源路徑]
# 參數：來源路徑  專案根目錄或其 docs/knowledge-skill 目錄；預設目前工作目錄。
# 流程：
#   1. 解析來源 → 找出 docs/knowledge-skill 任務資料夾容器
#   2. 檢查每個任務資料夾必要檔（prompt/task_plan/notes）是否存在且非空，
#      並確認恰有一份命名合格的 report-<slug>.md
#   3. 列出合格任務的 notes.md / report-<slug>.md 作為候選來源
# 產出：唯讀，僅輸出報告。
# 環境變數：無。
# 結束碼：0 有合格候選；1 路徑或格式不符；2 有任務資料夾但全部缺檔
set -e

SRC="${1:-.}"

if [ ! -d "$SRC" ]; then
    echo "❌ 來源路徑不存在：$SRC"
    exit 1
fi

# 找出任務資料夾容器
if [ -d "$SRC/docs/knowledge-skill" ]; then
    CONTAINER="$SRC/docs/knowledge-skill"
elif [ "$(basename "$SRC")" = "knowledge-skill" ]; then
    CONTAINER="$SRC"
else
    echo "❌ 路徑內找不到 docs/knowledge-skill 任務資料夾：$SRC"
    echo "   請指定專案根目錄，或其 docs/knowledge-skill 路徑。"
    exit 1
fi

echo "📂 任務資料夾來源：$CONTAINER"
echo ""

REQUIRED="prompt.md task_plan.md notes.md"
# 報告檔名帶任務英文名稱，另以 glob + 命名規則檢查
REPORT_PATTERN='^report-[a-z0-9]+(-[a-z0-9]+)*\.md$'
found_task=0
qualified=0
CANDIDATES=""

for d in "$CONTAINER"/*/; do
    [ -d "$d" ] || continue
    found_task=1
    name="$(basename "$d")"
    missing=""
    for r in $REQUIRED; do
        [ -s "${d}${r}" ] || missing="$missing $r"
    done

    # POSIX sh 在 glob 無匹配時會保留字面值，必須以 -e 過濾
    report=""
    report_count=0
    for f in "$d"report-*.md; do
        [ -e "$f" ] || continue
        report_count=$((report_count + 1))
        report="$(basename "$f")"
    done

    if [ "$report_count" -eq 0 ]; then
        missing="$missing report-<slug>.md"
    elif [ "$report_count" -gt 1 ]; then
        missing="$missing report-<slug>.md(找到${report_count}份)"
    elif ! printf '%s' "$report" | grep -Eq "$REPORT_PATTERN"; then
        missing="$missing report-<slug>.md(命名不符:$report)"
    elif [ ! -s "${d}${report}" ]; then
        missing="$missing $report(空檔)"
    fi

    if [ -z "$missing" ]; then
        qualified=$((qualified + 1))
        echo "✅ 合格：$name"
        CANDIDATES="$CANDIDATES${d}notes.md
${d}${report}
"
    else
        printf '⚠️  缺檔：%s（缺：%s ）\n' "$name" "$missing"
    fi
done

if [ "$found_task" -eq 0 ]; then
    echo "❌ 沒有任何任務資料夾。"
    exit 1
fi

echo ""
if [ "$qualified" -eq 0 ]; then
    echo "⚠️  有任務資料夾但全部缺必要檔，無合格候選。"
    exit 2
fi

echo "📋 可沉澱的候選來源檔："
printf '%s' "$CANDIDATES" | while IFS= read -r p; do [ -z "$p" ] || echo "   • $p"; done
echo ""
echo "👉 由 AI 讀取候選、依 references/consolidate.md 判斷可重用內容並建立知識檔，"
echo "   完成後執行 reindex 由腳本重建索引。"
exit 0
