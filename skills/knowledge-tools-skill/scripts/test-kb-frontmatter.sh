#!/bin/sh
# 隔離 smoke test：驗證會解析／改寫中文 front matter 欄位的腳本，在 macOS 內建 awk 的
# UTF-8 locale 下仍取到正確欄位。
#
# 回歸背景：macOS 的 /usr/bin/awk 在 UTF-8 locale 下，兩個多位元組字串以 == 比較恆為
# true。缺少 LC_ALL=C 時，`k=="標題"` 之類的判斷會被任何中文欄名命中——kb-supersede.sh
# 因此會在寫入「被取代於」時把標題、觸發時機、取代整批刪掉，只剩寫入的那一欄。
# 與空字串或 ASCII 字面量比較不受影響，故只需覆蓋「中文欄名 vs 中文欄名」的路徑。
set -e

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/kb-fm-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export HOME="$ROOT/home"
export KNOWLEDGE_BASE_DIR="$ROOT/knowledge"
mkdir -p "$HOME" "$KNOWLEDGE_BASE_DIR/dev/go"

make_doc() {
    printf -- '---\n標題: %s\n觸發時機: %s\n取代: -\n被取代於: -\n---\n\n## 摘要\n%s\n' "$1" "$2" "$3"
}

make_doc "舊知識標題" "舊觸發時機" "舊摘要" > "$KNOWLEDGE_BASE_DIR/dev/go/old.md"
make_doc "新知識標題" "新觸發時機" "新摘要" > "$KNOWLEDGE_BASE_DIR/dev/go/new.md"
cat > "$KNOWLEDGE_BASE_DIR/index.md" <<'EOF'
# 索引

## 分類目錄

| 分類 | 筆數 | 知識標題 |
|------|------|----------|
EOF

sh "$SCRIPT_DIR/kb-reindex.sh" > /dev/null

fm_get() {
    LC_ALL=C awk -v key="$2" '
        NR==1 && $0=="---" { fm=1; next }
        fm && $0=="---" { exit }
        fm {
            i=index($0, ":")
            if (i>0) {
                k=substr($0,1,i-1); v=substr($0,i+1)
                gsub(/^[ \t]+|[ \t]+$/, "", k); gsub(/^[ \t]+|[ \t]+$/, "", v)
                if (k==key) { print v; exit }
            }
        }
    ' "$1"
}

expect() {
    if [ "$2" != "$3" ]; then
        echo "❌ $1：got %s，want %s" >&2
        echo "   got:  $2" >&2
        echo "   want: $3" >&2
        exit 1
    fi
}

sh "$SCRIPT_DIR/kb-supersede.sh" dev/go/old.md dev/go/new.md --yes > /dev/null

MOVED="$KNOWLEDGE_BASE_DIR/deprecated/dev/go/old.md"
[ -f "$MOVED" ] || { echo "❌ 舊檔未移入 deprecated/" >&2; exit 1; }

# 核心斷言：寫入「被取代於」不得波及其他中文欄位。
expect "舊檔標題應保留"     "$(fm_get "$MOVED" "標題")"       "舊知識標題"
expect "舊檔觸發時機應保留" "$(fm_get "$MOVED" "觸發時機")"   "舊觸發時機"
expect "舊檔被取代於"       "$(fm_get "$MOVED" "被取代於")"   "dev/go/new.md"

NEW="$KNOWLEDGE_BASE_DIR/dev/go/new.md"
expect "新檔標題應保留"     "$(fm_get "$NEW" "標題")"         "新知識標題"
expect "新檔觸發時機應保留" "$(fm_get "$NEW" "觸發時機")"     "新觸發時機"
expect "新檔取代"           "$(fm_get "$NEW" "取代")"         "dev/go/old.md"

# 索引也該拿到正確欄位（reindex 由 supersede 內部呼叫）。
DEP_INDEX="$KNOWLEDGE_BASE_DIR/deprecated/dev/go/index.md"
grep -Fq '[舊知識標題](old.md)' "$DEP_INDEX" || { echo "❌ 停用子索引標題不正確" >&2; cat "$DEP_INDEX" >&2; exit 1; }
grep -Fq '舊觸發時機' "$DEP_INDEX" || { echo "❌ 停用子索引觸發時機遺失" >&2; cat "$DEP_INDEX" >&2; exit 1; }

# kb-reconcile.sh 的欄位解析走同一個陷阱。
sh "$SCRIPT_DIR/kb-reconcile.sh" > "$ROOT/reconcile.txt"
grep -Fq "新觸發時機" "$ROOT/reconcile.txt" || { echo "❌ reconcile 未取到觸發時機" >&2; cat "$ROOT/reconcile.txt" >&2; exit 1; }

# 標題含括號：索引第一欄的連結解析必須錨定行尾的 `](…)`，只找「第一個括號」會抓到標題
# 裡的 `Schema::table(ALTER)`／`shouldReceive()` 而非連結目標，讓整批知識被誤判成斷鏈與
# 孤兒檔（reindex 的變更統計也會跟著虛胖）。
make_doc "Schema::table(ALTER) 靜默失效" "跑 ALTER migration 時" "改用三參數 resolver" \
    > "$KNOWLEDGE_BASE_DIR/dev/go/paren.md"
make_doc "Mockery shouldReceive()->with() 匹配" "寫 Mockery 測試時" "改用 Mockery::any()" \
    > "$KNOWLEDGE_BASE_DIR/dev/go/paren2.md"
sh "$SCRIPT_DIR/kb-reindex.sh" > /dev/null

sh "$SCRIPT_DIR/kb-status.sh" > "$ROOT/status.txt" || {
    echo "❌ kb-status.sh 對含括號的標題誤判為斷鏈／孤兒" >&2
    cat "$ROOT/status.txt" >&2
    exit 1
}
# 生效 3 筆：new.md（old.md 已被 supersede 移入 deprecated/）加上兩個含括號標題的新檔。
grep -Fq "生效知識檔數量：3" "$ROOT/status.txt" || {
    echo "❌ kb-status.sh 知識檔數量不正確" >&2; cat "$ROOT/status.txt" >&2; exit 1;
}

# 第二次 reindex 應為無變更：統計若把標題內的括號當成登錄路徑，會虛報新增與移除。
sh "$SCRIPT_DIR/kb-reindex.sh" > "$ROOT/reindex2.txt"
grep -Fq "索引已是最新" "$ROOT/reindex2.txt" || {
    echo "❌ reindex 非 idempotent" >&2; cat "$ROOT/reindex2.txt" >&2; exit 1;
}

echo "✅ front matter 欄位解析 smoke test passed"
