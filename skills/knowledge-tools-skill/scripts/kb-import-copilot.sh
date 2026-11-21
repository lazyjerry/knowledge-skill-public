#!/bin/sh
# kb-import-copilot.sh
# 功能：把 GitHub Copilot 的記憶／session 來源轉成跨工具記憶沉澱候選。
#       Copilot Memory 無已確認的公開 export API，故不自動讀取；改採檔案匯入。
# 用法：sh kb-import-copilot.sh --from-file <檔案> [--dry-run|--write] [選項...]
#       sh kb-import-copilot.sh <目錄> [--write] [選項...]
# 參數：
#   --from-file／來源  使用者從 GitHub UI 整理的 facts/preferences、/chronicle 產物，
#                      或明確指定的本機 session-state（opt-in）。
#   其餘共用選項見 kb-import-lib.sh。
# 流程：依路徑判斷 source_kind（copilot-memory 或 copilot-session）→ 排除 .db/.jsonl →
#       交本庫過濾與落地。Copilot Memory 與 Copilot CLI session 視為不同來源。
# 產出：見 kb-import-lib.sh。
# 環境變數：無。
# 結束碼：0 完成；1 來源錯誤；2 無合格候選。
set -e

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/kb-import-lib.sh"

TOOL="copilot"
SCOPE_DEFAULT="user"
KIND_DEFAULT="copilot-memory"

kb_parse_args "$@" || { echo "用法：sh kb-import-copilot.sh --from-file <檔案> [--write] [選項...]"; exit 1; }

# session-state 路徑視為 copilot-session，否則為 copilot-memory。
copilot_kind() {
    case "$1" in
        */session-state/*|*/sessions/*|*session*) echo "copilot-session" ;;
        *) echo "$KIND_DEFAULT" ;;
    esac
}

copilot_emit() {
    _f="$1"
    case "$_f" in
        *.db|*.sqlite|*.sqlite3) echo "略過 SQLite（請改用 /chronicle 摘要或整理後的檔案）：$_f" >&2; return 0 ;;
        *.jsonl) echo "略過 raw session（.jsonl）；僅接受摘要或整理後檔案：$_f" >&2; return 0 ;;
    esac
    _sid="${_f#"$HOME"/}"
    printf '%s\t%s\t%s\t%s\t%s\n' "$_f" "$_sid" "$OPT_SCOPE" "$OPT_REPO" "$(copilot_kind "$_f")"
}

adapter_enumerate() {
    _src="$OPT_SRC"
    if [ -z "$_src" ]; then
        echo "Copilot 無公開 export API：請用 --from-file 指定整理後的檔案，或明確指定本機 session 路徑。" >&2
        return 1
    fi
    if [ ! -e "$_src" ]; then
        echo "Copilot 來源不存在：$_src" >&2
        return 1
    fi
    if [ -f "$_src" ]; then
        copilot_emit "$_src"
        return 0
    fi
    _list="$(mktemp "${TMPDIR:-/tmp}/kb-import-copilot.XXXXXX")"
    find "$_src" -type f \( -name '*.md' -o -name '*.txt' \) 2>/dev/null | LC_ALL=C sort > "$_list"
    if [ ! -s "$_list" ]; then
        rm -f "$_list"
        echo "未發現可解析的 .md/.txt（請指定整理後檔案或 /chronicle 產物）：$_src" >&2
        return 1
    fi
    while IFS= read -r _f; do copilot_emit "$_f"; done < "$_list"
    rm -f "$_list"
    return 0
}

kb_run
