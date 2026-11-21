#!/bin/sh
# kb-import-claude.sh
# 功能：唯讀掃描 Claude Code auto memory（Markdown），產生跨工具記憶沉澱候選。
# 用法：sh kb-import-claude.sh [來源] [--dry-run|--write] [選項...]
# 參數：來源預設 ~/.claude/projects（遞迴取各專案 memory/*.md）；可指定單一目錄或檔案。
#       其餘共用選項見 kb-import-lib.sh。
# 流程：列舉 memory/*.md（排除 MEMORY.md 索引與 *.jsonl raw transcript）→ 交本庫過濾與落地。
# 產出：見 kb-import-lib.sh（dry-run 統計／--write 候選資料夾）。
# 環境變數：無。
# 結束碼：0 完成；1 來源錯誤；2 無合格候選。
set -e

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/kb-import-lib.sh"

TOOL="claude"
SCOPE_DEFAULT="repository"   # auto memory 為專案範圍
KIND_DEFAULT="auto-memory"

kb_parse_args "$@" || { echo "用法：sh kb-import-claude.sh [來源] [--write] [選項...]"; exit 1; }

# 由路徑推導 repository（.../projects/<seg>/memory/...）；推不出時用 --repository。
claude_emit() {
    _f="$1"; _repo="$OPT_REPO"
    case "$_f" in
        */projects/*/memory/*) _repo="${_f#*/projects/}"; _repo="${_repo%%/memory/*}" ;;
    esac
    _sid="${_f#"$HOME"/}"
    printf '%s\t%s\t%s\t%s\t%s\n' "$_f" "$_sid" "$OPT_SCOPE" "$_repo" "$KIND_DEFAULT"
}

adapter_enumerate() {
    [ -z "$OPT_SRC" ] && OPT_SRC="$HOME/.claude/projects"
    _src="$OPT_SRC"
    if [ ! -e "$_src" ]; then
        echo "Claude 來源不存在：${_src}（本機可能尚未產生 auto memory）" >&2
        return 1
    fi
    if [ -f "$_src" ]; then
        case "$_src" in
            *.jsonl) echo "拒絕 raw transcript（.jsonl）；請先 /export 為純文字再指定。" >&2; return 1 ;;
        esac
        claude_emit "$_src"
        return 0
    fi
    _list="$(mktemp "${TMPDIR:-/tmp}/kb-import-claude.XXXXXX")"
    find "$_src" -type f -name '*.md' ! -name 'MEMORY.md' 2>/dev/null | LC_ALL=C sort > "$_list"
    if [ ! -s "$_list" ]; then
        rm -f "$_list"
        echo "未發現 memory/*.md（schema 不符或目錄為空）：$_src" >&2
        return 1
    fi
    while IFS= read -r _f; do claude_emit "$_f"; done < "$_list"
    rm -f "$_list"
    return 0
}

kb_run
