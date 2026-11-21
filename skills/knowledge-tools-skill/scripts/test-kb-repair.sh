#!/bin/sh
# 隔離 smoke test：驗證 kb-repair.sh 的確定性修復、刻意跳過的項目與授權契約。
set -e

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/kb-repair-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export HOME="$ROOT/home"
mkdir -p "$HOME"

DOC='---
標題: 知識標題
觸發時機: 需要測試修復時
取代: -
被取代於: -
---

## 摘要
修復測試摘要

## 脈絡與問題陳述
測試脈絡

## 決策驅力
-

## 考量選項
- 採用確定性修復

## 各選項利弊
-

## 決策結果
採用確定性修復

## 影響
結果可重現

## 驗證
-

## 補充資訊
隔離測試
'

# 由 $DOC 產生一份知識檔，並依 key=value 覆寫 front matter 欄位。
make_doc() {
    _out="$1"; shift
    mkdir -p "$(dirname "$_out")"
    printf '%s' "$DOC" > "$_out"
    for _kv in "$@"; do
        _k="${_kv%%=*}"; _v="${_kv#*=}"
        LC_ALL=C awk -v key="$_k" -v val="$_v" '
            BEGIN { fm=0 }
            NR==1 && $0=="---" { print; fm=1; next }
            fm==1 && $0=="---" { print; fm=0; next }
            fm==1 {
                i=index($0, ":")
                if (i>0) {
                    k=substr($0,1,i-1); gsub(/^[ \t]+|[ \t]+$/, "", k)
                    if (k==key) { if (val!="<刪除>") print key ": " val; next }
                }
                print; next
            }
            { print }
        ' "$_out" > "$_out.tmp"
        mv "$_out.tmp" "$_out"
    done
}

fm_of() {
    LC_ALL=C awk -v key="$2" '
        BEGIN { fm=0 }
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

# 每個案例都用全新的知識庫目錄，彼此不干擾。
new_kb() {
    KNOWLEDGE_BASE_DIR="$ROOT/$1"
    export KNOWLEDGE_BASE_DIR
    mkdir -p "$KNOWLEDGE_BASE_DIR"
    printf '%s\n' '# 索引' '' '## 知識清單' '' \
        '| 知識 | 觸發時機 | 摘要 | 取代 |' '|------|----------|------|------|' \
        > "$KNOWLEDGE_BASE_DIR/index.md"
}

run_repair() {
    set +e
    sh "$SCRIPT_DIR/kb-repair.sh" "$@" > "$ROOT/out.txt" 2>&1
    REPAIR_CODE=$?
    set -e
}

expect_code() {
    [ "$REPAIR_CODE" -eq "$1" ] || {
        echo "❌ $2：預期 exit $1，實際 $REPAIR_CODE" >&2
        cat "$ROOT/out.txt" >&2
        exit 1
    }
}

expect_fm() {
    _actual="$(fm_of "$1" "$2")"
    [ "$_actual" = "$3" ] || {
        echo "❌ $4：$1 的「$2」預期 $3，實際 「$_actual」" >&2
        cat "$ROOT/out.txt" >&2
        exit 1
    }
}

health_codes() {
    set +e
    sh "$SCRIPT_DIR/kb-health.sh" --format json --source cli > "$ROOT/health.json"
    set -e
}

expect_no_code() {
    grep -Fq "\"code\":\"$1\"" "$ROOT/health.json" && {
        echo "❌ $2：不該再有 $1" >&2; cat "$ROOT/health.json" >&2; exit 1;
    }
    return 0
}

expect_has_code() {
    grep -Fq "\"code\":\"$1\"" "$ROOT/health.json" || {
        echo "❌ $2：預期仍有 $1" >&2; cat "$ROOT/health.json" >&2; exit 1;
    }
}

# ---- 案例 1：生效檔已登記取代，停用檔的「被取代於」空白 → 回填 ----
new_kb kb-reciprocal-forward
make_doc "$KNOWLEDGE_BASE_DIR/dev/go/new.md" "標題=新知識" "取代=dev/go/old.md"
make_doc "$KNOWLEDGE_BASE_DIR/deprecated/dev/go/old.md" "標題=舊知識"
sh "$SCRIPT_DIR/kb-reindex.sh" > /dev/null

health_codes
expect_has_code "supersede_not_reciprocal" "案例 1 前置"
expect_has_code "superseded_by_missing" "案例 1 前置"

run_repair --yes
expect_code 0 "案例 1"
expect_fm "$KNOWLEDGE_BASE_DIR/deprecated/dev/go/old.md" "被取代於" "dev/go/new.md" "案例 1"
health_codes
expect_no_code "supersede_not_reciprocal" "案例 1"
expect_no_code "superseded_by_missing" "案例 1"

# ---- 案例 2：停用檔已登記被取代於，生效檔的「取代」是 - → 回填 ----
new_kb kb-reciprocal-backward
make_doc "$KNOWLEDGE_BASE_DIR/dev/go/new.md" "標題=新知識"
make_doc "$KNOWLEDGE_BASE_DIR/deprecated/dev/go/old.md" "標題=舊知識" "被取代於=dev/go/new.md"
sh "$SCRIPT_DIR/kb-reindex.sh" > /dev/null

health_codes
expect_has_code "superseded_by_not_reciprocal" "案例 2 前置"

run_repair --yes
expect_code 0 "案例 2"
expect_fm "$KNOWLEDGE_BASE_DIR/dev/go/new.md" "取代" "dev/go/old.md" "案例 2"
health_codes
expect_no_code "superseded_by_not_reciprocal" "案例 2"

# ---- 案例 3：缺少關係欄位 → 補 -，但缺標題／觸發時機不代填 ----
new_kb kb-frontmatter
make_doc "$KNOWLEDGE_BASE_DIR/dev/go/partial.md" "取代=<刪除>" "被取代於=<刪除>" "觸發時機=<刪除>"
sh "$SCRIPT_DIR/kb-reindex.sh" > /dev/null

run_repair --yes
expect_code 0 "案例 3"
expect_fm "$KNOWLEDGE_BASE_DIR/dev/go/partial.md" "取代" "-" "案例 3"
expect_fm "$KNOWLEDGE_BASE_DIR/dev/go/partial.md" "被取代於" "-" "案例 3"
expect_fm "$KNOWLEDGE_BASE_DIR/dev/go/partial.md" "觸發時機" "" "案例 3：觸發時機不可代填"
health_codes
expect_has_code "invalid_trigger" "案例 3：內容問題仍應保留"

# ---- 案例 4：刻意跳過——取代關係衝突、生效檔被標記為已取代 ----
new_kb kb-skip
# 停用檔的被取代於指向 other.md，生效檔 new.md 卻宣稱取代它 → 方向衝突，不可臆測
make_doc "$KNOWLEDGE_BASE_DIR/dev/go/new.md" "標題=新知識" "取代=dev/go/old.md"
make_doc "$KNOWLEDGE_BASE_DIR/dev/go/other.md" "標題=另一則"
make_doc "$KNOWLEDGE_BASE_DIR/deprecated/dev/go/old.md" "標題=舊知識" "被取代於=dev/go/other.md"
# 生效檔卻標記了被取代於 → 兩種修法方向相反，不自動處理
make_doc "$KNOWLEDGE_BASE_DIR/dev/go/marked.md" "標題=被誤標的生效知識" "被取代於=dev/go/new.md"
sh "$SCRIPT_DIR/kb-reindex.sh" > /dev/null

run_repair --yes
expect_code 0 "案例 4"
expect_fm "$KNOWLEDGE_BASE_DIR/deprecated/dev/go/old.md" "被取代於" "dev/go/other.md" "案例 4：不得覆寫既有取代關係"
expect_fm "$KNOWLEDGE_BASE_DIR/dev/go/marked.md" "被取代於" "dev/go/new.md" "案例 4：不得自行清除"
health_codes
expect_has_code "supersede_not_reciprocal" "案例 4"
expect_has_code "active_marked_superseded" "案例 4"
grep -q "需人工" "$ROOT/out.txt" || { echo "❌ 案例 4：未回報需人工處理的項目" >&2; cat "$ROOT/out.txt" >&2; exit 1; }

# ---- 案例 5：多個生效檔指向同一停用檔 → 無法判定，跳過 ----
new_kb kb-ambiguous
make_doc "$KNOWLEDGE_BASE_DIR/dev/go/a.md" "標題=候選 A" "取代=dev/go/old.md"
make_doc "$KNOWLEDGE_BASE_DIR/dev/go/b.md" "標題=候選 B" "取代=dev/go/old.md"
make_doc "$KNOWLEDGE_BASE_DIR/deprecated/dev/go/old.md" "標題=舊知識"
sh "$SCRIPT_DIR/kb-reindex.sh" > /dev/null

run_repair --yes
expect_code 0 "案例 5"
expect_fm "$KNOWLEDGE_BASE_DIR/deprecated/dev/go/old.md" "被取代於" "-" "案例 5：多筆指向時不得臆測"

# ---- 案例 6：--dry-run 不改檔 ----
new_kb kb-dryrun
make_doc "$KNOWLEDGE_BASE_DIR/dev/go/new.md" "標題=新知識" "取代=dev/go/old.md"
make_doc "$KNOWLEDGE_BASE_DIR/deprecated/dev/go/old.md" "標題=舊知識"
sh "$SCRIPT_DIR/kb-reindex.sh" > /dev/null

run_repair --dry-run
expect_code 0 "案例 6"
expect_fm "$KNOWLEDGE_BASE_DIR/deprecated/dev/go/old.md" "被取代於" "-" "案例 6：dry-run 不得改檔"

# ---- 案例 7：非互動未帶 --yes → exit 3 且不改檔 ----
run_repair < /dev/null
expect_code 3 "案例 7"
expect_fm "$KNOWLEDGE_BASE_DIR/deprecated/dev/go/old.md" "被取代於" "-" "案例 7：未授權不得改檔"

# ---- 案例 8：健康知識庫執行修復為 no-op ----
new_kb kb-clean
make_doc "$KNOWLEDGE_BASE_DIR/dev/go/healthy.md" "標題=健康知識"
sh "$SCRIPT_DIR/kb-reindex.sh" > /dev/null
run_repair --yes
expect_code 0 "案例 8"
health_codes
grep -Fq '"healthy":true' "$ROOT/health.json" || {
    echo "❌ 案例 8：修復後知識庫應維持健康" >&2; cat "$ROOT/health.json" >&2; exit 1;
}

# ---- 案例 9：改檔前留下備份 ----
new_kb kb-backup
make_doc "$KNOWLEDGE_BASE_DIR/dev/go/new.md" "標題=新知識" "取代=dev/go/old.md"
make_doc "$KNOWLEDGE_BASE_DIR/deprecated/dev/go/old.md" "標題=舊知識"
sh "$SCRIPT_DIR/kb-reindex.sh" > /dev/null
run_repair --yes
expect_code 0 "案例 9"
ls "$ROOT"/backups/repair-* > /dev/null 2>&1 || {
    echo "❌ 案例 9：未留下修復前備份" >&2; ls -R "$ROOT" >&2; exit 1;
}

echo "✅ kb-repair.sh smoke test passed"
