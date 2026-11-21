#!/bin/sh
# 驗證任務檔案是否已編輯（與範本不同）
# 用法: sh <SKILL_DIR>/scripts/validate-task-files.sh <任務資料夾路徑>
# 範例: sh /path/to/knowledge-skill/scripts/validate-task-files.sh /path/to/project/docs/knowledge-skill/task-001

set -e

TASK_FOLDER="${1:-.}"
SKILL_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"

# 確保任務資料夾存在
if [ ! -d "$TASK_FOLDER" ]; then
    echo "❌ 錯誤：任務資料夾不存在: $TASK_FOLDER"
    exit 1
fi

# 範本檔案路徑
TEMPLATE_PROMPT="$SKILL_DIR/assets/prompt.md"
TEMPLATE_TASK_PLAN="$SKILL_DIR/assets/task_plan.md"

# 任務檔案路徑
TASK_PROMPT="$TASK_FOLDER/prompt.md"
TASK_PLAN="$TASK_FOLDER/task_plan.md"

ERRORS=0

# 檢查 prompt.md
if [ ! -f "$TASK_PROMPT" ]; then
    echo "❌ prompt.md 不存在"
    ERRORS=$((ERRORS + 1))
elif diff -q "$TEMPLATE_PROMPT" "$TASK_PROMPT" > /dev/null 2>&1; then
    echo "❌ prompt.md 尚未編輯（與範本相同）"
    ERRORS=$((ERRORS + 1))
else
    echo "✅ prompt.md 已編輯"
fi

# 檢查 task_plan.md
if [ ! -f "$TASK_PLAN" ]; then
    echo "❌ task_plan.md 不存在"
    ERRORS=$((ERRORS + 1))
elif diff -q "$TEMPLATE_TASK_PLAN" "$TASK_PLAN" > /dev/null 2>&1; then
    echo "❌ task_plan.md 尚未編輯（與範本相同）"
    ERRORS=$((ERRORS + 1))
else
    echo "✅ task_plan.md 已編輯"
fi

echo ""

if [ $ERRORS -gt 0 ]; then
    echo "⚠️  請先編輯上述檔案後再繼續"
    exit 1
fi

# === 自動插入階段檢核點 ===
CHECKPOINT='  - [ ] ✅ 階段檢核：更新 notes.md → task_plan.md'

# 檢查是否已有檢核點
if grep -q "階段檢核" "$TASK_PLAN"; then
    echo "✅ 驗證通過，可以開始執行任務"
    exit 0
fi

# 使用 awk 在每個階段區塊末尾插入檢核點
awk -v checkpoint="$CHECKPOINT" '
BEGIN { in_stage = 0; buffer = "" }

/^- \[[ x]\] 階段 [0-9]+/ {
    if (in_stage && buffer != "") {
        printf "%s", buffer
        print checkpoint
        buffer = ""
    }
    in_stage = 1
    print
    next
}

/^  / {
    if (in_stage) {
        buffer = buffer $0 "\n"
        next
    }
    print
    next
}

{
    if (in_stage && buffer != "") {
        printf "%s", buffer
        print checkpoint
        buffer = ""
        in_stage = 0
    }
    print
}

END {
    if (in_stage && buffer != "") {
        printf "%s", buffer
        print checkpoint
    }
}
' "$TASK_PLAN" > "${TASK_PLAN}.tmp"

mv "${TASK_PLAN}.tmp" "$TASK_PLAN"
echo "✅ 已自動插入階段檢核點"
echo "✅ 驗證通過，可以開始執行任務"
exit 0
