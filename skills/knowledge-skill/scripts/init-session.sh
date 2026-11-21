#!/bin/sh
# 初始化任務資料夾
# 用法: sh <SKILL_DIR>/scripts/init-session.sh <工作區根目錄> <任務名稱> <報告英文名稱>
# 範例: sh /path/to/knowledge-skill/scripts/init-session.sh /path/to/project AI_工具記憶優化 ai-memory-optimization
#
# 參數：
#   <工作區根目錄>  任務資料夾的建立位置
#   <任務名稱>      繁體中文任務名稱（含選填票號前綴），空格與特殊符號須先轉為 _
#   <報告英文名稱>  報告檔名的 slug，網址式 kebab-case，決定完成時的 report-<slug>.md
#
# 公用知識庫位置：環境變數 KNOWLEDGE_BASE_DIR > 設定檔 ~/.config/knowledge-skill/config > 預設 $HOME/.knowledge-skill/knowledge
#
# 結束碼：
#   0  成功
#   1  參數或工作區錯誤
#   2  公用知識庫路徑無法讀寫 → 已印出路徑選項，請依選項重新執行

set -e

WORKSPACE_ROOT="${1:-.}"
TASK_NAME="${2:-task}"
REPORT_SLUG="${3:-}"
SKILL_DIR="$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)"
SCRIPT_PATH="$SKILL_DIR/scripts/init-session.sh"

# 公用知識庫（跨專案共用），預設放在使用者家目錄
# BEGIN kb-resolve-dir（各腳本逐字相同，改動後執行 test-kb-resolve-dir.sh 驗證）
# 解析順序：環境變數 KNOWLEDGE_BASE_DIR > 設定檔 > 預設路徑。設定檔讓 hook、launchd
# 這類不讀 shell 設定檔的執行環境也能解析到同一位置；設定檔不 source，只取
# KNOWLEDGE_BASE_DIR= 那一行，開頭的 ~ 或 $HOME 才展開。
KB_CONFIG="$HOME/.config/knowledge-skill/config"
KB_DIR="$HOME/.knowledge-skill/knowledge"
KB_SOURCE="預設值"
if [ -n "${KNOWLEDGE_BASE_DIR:-}" ]; then
    KB_DIR="$KNOWLEDGE_BASE_DIR"
    KB_SOURCE="環境變數 KNOWLEDGE_BASE_DIR"
elif [ -f "$KB_CONFIG" ]; then
    KB_CONFIG_VALUE="$(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}KNOWLEDGE_BASE_DIR=//p' "$KB_CONFIG" | tail -n 1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/")"
    case "$KB_CONFIG_VALUE" in
        "~/"*) KB_CONFIG_VALUE="$HOME/${KB_CONFIG_VALUE#"~/"}" ;;
        '$HOME/'*) KB_CONFIG_VALUE="$HOME/${KB_CONFIG_VALUE#'$HOME/'}" ;;
    esac
    if [ -n "$KB_CONFIG_VALUE" ]; then
        KB_DIR="$KB_CONFIG_VALUE"
        KB_SOURCE="設定檔 ~/.config/knowledge-skill/config"
    fi
fi
# END kb-resolve-dir
KNOWLEDGE_BASE_DIR="$KB_DIR"

# 參數錯誤要在知識庫檢查（exit 2）之前擋掉，兩種失敗不混在同一個結束碼
slug_usage() {
    cat >&2 <<EOF
❌ $1

用法: sh <SKILL_DIR>/scripts/init-session.sh <工作區根目錄> <任務名稱> <報告英文名稱>

<報告英文名稱> 是報告檔名的 slug，決定完成時的 report-<slug>.md：
  - 只允許小寫英文、數字與單一連字號
  - 不可有開頭／結尾連字號，也不可連續連字號
  - 例：ai-memory-optimization → report-ai-memory-optimization.md
EOF
    exit 1
}

if [ -z "$REPORT_SLUG" ]; then
    slug_usage "缺少必要參數 <報告英文名稱>"
fi

if ! printf '%s' "$REPORT_SLUG" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$'; then
    slug_usage "報告英文名稱格式不符: $REPORT_SLUG"
fi

REPORT_FILE="report-$REPORT_SLUG.md"

# 任務名稱會拼進資料夾路徑：含 / 會寫到任務容器之外，含空白則違反命名規則
case "$TASK_NAME" in
    */*|*[[:space:]]*)
        echo "❌ 任務名稱不可含 / 或空白（空格與特殊符號請先轉為 _）: $TASK_NAME" >&2
        exit 1
        ;;
esac

# 確保工作區根目錄存在
if [ ! -d "$WORKSPACE_ROOT" ]; then
    echo "錯誤：工作區根目錄不存在: $WORKSPACE_ROOT"
    exit 1
fi

# ============================================================
# 步驟 1：確認公用知識庫路徑可讀寫（工作區外可能受權限／沙盒限制）
# ============================================================

# 嘗試建立目錄並實際寫入探針檔，確認可讀寫
kb_writable() {
    _dir="$1"
    mkdir -p "$_dir" 2>/dev/null || return 1
    _probe="$_dir/.kbwrite_probe_$$"
    if ( : > "$_probe" ) 2>/dev/null; then
        rm -f "$_probe"
        return 0
    fi
    return 1
}

if ! kb_writable "$KNOWLEDGE_BASE_DIR"; then
    KB_PARENT="$(dirname "$KNOWLEDGE_BASE_DIR")"
    PROJECT_KB="$WORKSPACE_ROOT/docs/knowledge-skill/knowledge"
    cat <<EOF
❌ 公用知識庫路徑無法讀寫: $KNOWLEDGE_BASE_DIR

工作區外的路徑可能被權限或沙盒模式阻擋。請選擇處理方式，選好後「重新執行初始化」：

[1] 維持此路徑，先為目前使用的 AI 工具開啟存取權限：
    - Claude Code：把 $KB_PARENT 加入 ~/.claude/settings.json 的
      permissions.additionalDirectories（或執行 /add-dir），重載設定後重跑
    - Codex：在 ~/.codex/config.toml 的 [sandbox_workspace_write] 設
      writable_roots = ["$KB_PARENT"]
    - Antigravity (agy)：啟動時加旗標 --add-dir $KB_PARENT
    - Copilot CLI：確認作業系統對該路徑的讀寫權限
    開好權限後，重新執行相同指令（會自動再次檢查；若仍失敗請再次選擇）。

[2] 改用「專案內」路徑（位於工作區，必定可寫；但知識庫將不再跨專案共用）：
    $PROJECT_KB
    重新執行：
      KNOWLEDGE_BASE_DIR="$PROJECT_KB" sh "$SCRIPT_PATH" "$WORKSPACE_ROOT" "$TASK_NAME" "$REPORT_SLUG"

[3] 指定其他路徑（會自動再次檢查；若仍失敗請再次選擇）：
    重新執行：
      KNOWLEDGE_BASE_DIR="<你要的路徑>" sh "$SCRIPT_PATH" "$WORKSPACE_ROOT" "$TASK_NAME" "$REPORT_SLUG"
EOF
    exit 2
fi

# 如果知識庫 index.md 不存在，建立它
if [ ! -f "$KNOWLEDGE_BASE_DIR/index.md" ]; then
    cp "$SKILL_DIR/assets/knowledge-index.md" "$KNOWLEDGE_BASE_DIR/index.md"
    echo "✅ 建立知識庫索引: $KNOWLEDGE_BASE_DIR/index.md"
    # 索引不參與雲端同步，缺索引不代表知識庫是空的：其他裝置寫入的知識檔可能早已同步過來。
    # 只留空範本會讓本次任務查不到任何知識，未標記忽略的空索引還會同步出去、與其他裝置的索引衝突。
    REINDEX="$SKILL_DIR/../knowledge-tools-skill/scripts/kb-reindex.sh"
    if [ -f "$REINDEX" ]; then
        KNOWLEDGE_BASE_DIR="$KNOWLEDGE_BASE_DIR" sh "$REINDEX"
    fi
fi

# ============================================================
# 步驟 2：建立專案內的任務資料夾
# ============================================================

CDPATH= cd -- "$WORKSPACE_ROOT"

mkdir -p docs/knowledge-skill

# 計算流水號：取現有最大序號 + 1。用資料夾數量推算，中間的序號被刪掉後會撞到既有任務
MAX_NUM=0
for _d in "docs/knowledge-skill/${TASK_NAME}"-[0-9][0-9][0-9]; do
    [ -d "$_d" ] || continue
    _n="${_d##*-}"
    # 去前導 0，否則 008、009 會被當成八進位
    _n="${_n#"${_n%%[!0]*}"}"; _n="${_n:-0}"
    if [ "$_n" -gt "$MAX_NUM" ]; then MAX_NUM="$_n"; fi
done
NEXT_NUM=$(printf "%03d" $((MAX_NUM + 1)))
TASK_FOLDER="docs/knowledge-skill/${TASK_NAME}-${NEXT_NUM}"

if [ -e "$TASK_FOLDER" ]; then
    echo "❌ 任務資料夾已存在，未覆寫: $TASK_FOLDER" >&2
    exit 1
fi

# 建立任務資料夾
mkdir -p "$TASK_FOLDER"

# 複製範本檔案
cp "$SKILL_DIR/assets/prompt.md" "$TASK_FOLDER/"
cp "$SKILL_DIR/assets/task_plan.md" "$TASK_FOLDER/"
cp "$SKILL_DIR/assets/notes.md" "$TASK_FOLDER/"

echo "✅ 任務資料夾已建立: $TASK_FOLDER"
echo "   - prompt.md"
echo "   - task_plan.md"
echo "   - notes.md"
echo ""
echo "📁 任務完整路徑: $(pwd)/$TASK_FOLDER"
echo "📚 知識庫路徑: $KNOWLEDGE_BASE_DIR"
echo "📄 完成時報告檔名: $REPORT_FILE"
