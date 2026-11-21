#!/bin/sh
# 隔離 smoke test：驗證知識庫位置解析（環境變數 > 設定檔 > 預設）。
#
# 涵蓋三件事：
#   1. 各腳本的 kb-resolve-dir 區塊逐字相同。區塊刻意內嵌在每支腳本（skill 可獨立安裝、
#      init-injection.sh 支援單檔遠端執行、部分 kb-*.sh 會被其他工具以 go:embed 單檔內嵌），
#      無法共用 lib，只能靠這個比對防止分歧。在 repo 外安裝時找不到的副本跳過。
#   2. 以 kb-status.sh 驗證解析順序與設定檔格式（~、$HOME、引號、export 前綴）。
#   3. init-knowledge-base.sh 非預設位置寫入設定檔、重跑不重複追加（repo 外跳過）。
set -e

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
REPO_DIR="$SCRIPT_DIR/../../.."
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/kb-resolve-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export HOME="$ROOT/home"
unset KNOWLEDGE_BASE_DIR
mkdir -p "$HOME"

fail() {
    printf '❌ %s\n' "$1"
    exit 1
}

extract_block() {
    awk '
        /^# BEGIN kb-resolve-dir/ { inblock=1 }
        inblock { print }
        /^# END kb-resolve-dir/ { exit }
    ' "$1"
}

# --- 1. 區塊逐字一致 ---
REF="$ROOT/ref-block"
extract_block "$SCRIPT_DIR/kb-status.sh" > "$REF"
[ -s "$REF" ] || fail "kb-status.sh 找不到 kb-resolve-dir 區塊"

checked=0
for f in "$SCRIPT_DIR"/kb-*.sh \
    "$SCRIPT_DIR/../../knowledge-skill/scripts/init-session.sh" \
    "$REPO_DIR/scripts/init-injection.sh" \
    "$REPO_DIR/scripts/init-knowledge-base.sh" \
    "$REPO_DIR/scripts/uninstall-knowledge-base.sh"; do
    [ -f "$f" ] || continue
    grep -q '^# BEGIN kb-resolve-dir' "$f" || continue
    extract_block "$f" > "$ROOT/cur-block"
    diff -q "$REF" "$ROOT/cur-block" >/dev/null || fail "kb-resolve-dir 區塊與 kb-status.sh 不一致: $f"
    checked=$((checked + 1))
done
echo "✅ kb-resolve-dir 區塊一致（$checked 份）"

# 仍殘留舊寫法 = 該腳本沒有改用設定檔
if grep -l 'KNOWLEDGE_BASE_DIR:-\$HOME/.knowledge-skill/knowledge' "$SCRIPT_DIR"/kb-*.sh 2>/dev/null; then
    fail "上列腳本仍只認環境變數，未改用 kb-resolve-dir 區塊"
fi

# --- 2. 解析順序 ---
CONFIG="$HOME/.config/knowledge-skill/config"
mkdir -p "$(dirname "$CONFIG")"

expect_status() {
    label="$1"
    want_source="$2"
    want_dir="$3"
    out="$(sh "$SCRIPT_DIR/kb-status.sh" 2>&1 || true)"
    if ! printf '%s\n' "$out" | grep -qF "位置來源：$want_source"; then
        printf '%s\n' "$out"
        fail "$label：來源應為 $want_source"
    fi
    if ! printf '%s\n' "$out" | grep -qxF "   絕對：$want_dir"; then
        printf '%s\n' "$out"
        fail "$label：路徑應為 $want_dir"
    fi
    echo "✅ $label"
}

expect_status "無設定 → 預設值" "預設值" "$HOME/.knowledge-skill/knowledge"

printf '# 註解\nKNOWLEDGE_BASE_DIR=~/kb-a/knowledge\n' > "$CONFIG"
expect_status "設定檔 ~ 展開" "設定檔" "$HOME/kb-a/knowledge"

printf 'export KNOWLEDGE_BASE_DIR="$HOME/kb-b/knowledge"\n' > "$CONFIG"
expect_status "設定檔 export 前綴、引號、\$HOME 展開" "設定檔" "$HOME/kb-b/knowledge"

printf "KNOWLEDGE_BASE_DIR='$ROOT/kb-c'\nKNOWLEDGE_BASE_DIR=$ROOT/kb-d\n" > "$CONFIG"
expect_status "設定檔多行取最後一行" "設定檔" "$ROOT/kb-d"

printf 'KNOWLEDGE_BASE_DIR=\n' > "$CONFIG"
expect_status "設定檔空值 → 預設值" "預設值" "$HOME/.knowledge-skill/knowledge"

printf 'KNOWLEDGE_BASE_DIR=~/kb-a/knowledge\n' > "$CONFIG"
# 子 shell 隔離：函式呼叫前的變數指派在部分 sh 實作會殘留到呼叫之後
(
    export KNOWLEDGE_BASE_DIR="$ROOT/kb-env"
    expect_status "環境變數優先於設定檔" "環境變數 KNOWLEDGE_BASE_DIR" "$ROOT/kb-env"
)
rm -f "$CONFIG"

# --- 3. init-knowledge-base.sh 寫入設定檔 ---
INIT="$REPO_DIR/scripts/init-knowledge-base.sh"
if [ -f "$INIT" ]; then
    sh "$INIT" "$HOME/kb-init" </dev/null >/dev/null
    [ "$(grep -c '^KNOWLEDGE_BASE_DIR=' "$CONFIG")" = 1 ] || fail "init-knowledge-base.sh 應寫入一行設定"
    grep -qxF 'KNOWLEDGE_BASE_DIR=~/kb-init/knowledge' "$CONFIG" || fail "設定值應以 ~ 開頭: $(cat "$CONFIG")"
    sh "$INIT" "$HOME/kb-init" </dev/null >/dev/null
    [ "$(grep -c '^KNOWLEDGE_BASE_DIR=' "$CONFIG")" = 1 ] || fail "重跑不應重複追加"
    sh "$INIT" "$HOME/kb-other" </dev/null >/dev/null
    grep -qxF 'KNOWLEDGE_BASE_DIR=~/kb-init/knowledge' "$CONFIG" || fail "既有設定不應被覆蓋"
    expect_status "init 寫入的設定檔可被解析" "設定檔" "$HOME/kb-init/knowledge"
else
    echo "ℹ️  找不到 init-knowledge-base.sh（repo 外安裝），略過第 3 項"
fi

echo "✅ 全部通過"
