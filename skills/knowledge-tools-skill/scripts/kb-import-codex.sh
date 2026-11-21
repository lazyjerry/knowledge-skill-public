#!/bin/sh
# kb-import-codex.sh
# 功能：唯讀掃描 Codex memories（generated state，Markdown）產生跨工具記憶沉澱候選。
# 用法：sh kb-import-codex.sh [來源] [--dry-run|--write] [選項...]
# 參數：來源預設 ~/.codex/memories；可指定單一目錄或檔案。其餘共用選項見 kb-import-lib.sh。
# 流程：feature-detect 可解析的 *.md（不假設固定檔名）→ 交本庫過濾與落地。
#       官方未承諾內部 schema 穩定；無可解析 Markdown 即以非零碼停止，不臆測。
# 產出：見 kb-import-lib.sh。
# 環境變數：無。
# 結束碼：0 完成；1 來源或 schema 錯誤；2 無合格候選。
set -e

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/kb-import-lib.sh"

TOOL="codex"
SCOPE_DEFAULT="user"        # memories 為跨 thread 的 durable state
KIND_DEFAULT="vendor-memory"

kb_parse_args "$@" || { echo "用法：sh kb-import-codex.sh [來源] [--write] [選項...]"; exit 1; }

codex_emit() {
    _f="$1"
    _sid="${_f#"$HOME"/}"
    printf '%s\t%s\t%s\t%s\t%s\n' "$_f" "$_sid" "$OPT_SCOPE" "$OPT_REPO" "$KIND_DEFAULT"
}

adapter_enumerate() {
    [ -z "$OPT_SRC" ] && OPT_SRC="$HOME/.codex/memories"
    _src="$OPT_SRC"
    if [ ! -e "$_src" ]; then
        echo "Codex 來源不存在：$_src" >&2
        return 1
    fi
    if [ -f "$_src" ]; then
        codex_emit "$_src"
        return 0
    fi
    _list="$(mktemp "${TMPDIR:-/tmp}/kb-import-codex.XXXXXX")"
    find "$_src" -type f -name '*.md' 2>/dev/null | LC_ALL=C sort > "$_list"
    if [ ! -s "$_list" ]; then
        rm -f "$_list"
        echo "未發現可解析的 Markdown 記憶（schema 不支援）：$_src" >&2
        return 1
    fi
    while IFS= read -r _f; do codex_emit "$_f"; done < "$_list"
    rm -f "$_list"
    return 0
}

kb_run
