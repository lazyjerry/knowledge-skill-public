#!/bin/sh
# 隔離 smoke test：驗證 kb-sync.sh 的 pull／push 方向、合併不刪除、衝突處理與授權契約。
set -e

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/kb-sync-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export HOME="$ROOT/home"
mkdir -p "$HOME"

DOC='---
標題: 知識標題
觸發時機: 需要測試同步時
取代: -
被取代於: -
---

## 摘要
同步測試摘要

## 脈絡與問題陳述
測試脈絡

## 決策驅力
-

## 考量選項
- 採用單向搬運

## 各選項利弊
-

## 決策結果
採用單向搬運

## 影響
兩端知識檔一致

## 驗證
-

## 補充資訊
隔離測試
'

# 產生一份知識檔；第二個參數會取代「決策結果」段內容，用來製造同路徑不同內容。
make_doc() {
    _out="$1"
    _mark="${2:-}"
    mkdir -p "$(dirname "$_out")"
    printf '%s' "$DOC" > "$_out"
    if [ -n "$_mark" ]; then
        printf '%s\n' "$_mark" >> "$_out"
    fi
}

# 每個案例都用全新的兩端目錄，彼此不干擾。
new_pair() {
    LOCAL="$ROOT/$1-local"
    REMOTE="$ROOT/$1-remote"
    for d in "$LOCAL" "$REMOTE"; do
        mkdir -p "$d"
        printf '%s\n' '# 索引' '' '## 知識清單' '' \
            '| 知識 | 觸發時機 | 摘要 | 取代 |' '|------|----------|------|------|' \
            > "$d/index.md"
    done
    KNOWLEDGE_BASE_DIR="$LOCAL"
    export KNOWLEDGE_BASE_DIR
}

run_sync() {
    set +e
    sh "$SCRIPT_DIR/kb-sync.sh" "$@" > "$ROOT/out.txt" 2>&1
    SYNC_CODE=$?
    set -e
}

expect_code() {
    [ "$SYNC_CODE" -eq "$1" ] || {
        echo "❌ $2：預期 exit $1，實際 $SYNC_CODE" >&2
        cat "$ROOT/out.txt" >&2
        exit 1
    }
}

expect_file() {
    [ -f "$1" ] || {
        echo "❌ $2：預期存在 $1" >&2
        cat "$ROOT/out.txt" >&2
        exit 1
    }
}

expect_no_file() {
    [ ! -e "$1" ] || {
        echo "❌ $2：不該存在 $1" >&2
        cat "$ROOT/out.txt" >&2
        exit 1
    }
}

expect_grep() {
    grep -Fq -e "$2" "$1" || {
        echo "❌ $3：$1 應含「$2」" >&2
        cat "$1" >&2
        exit 1
    }
}

# ---- 案例 1：pull 把對方獨有的知識檔拉進本機，並登錄到本機索引 ----
new_pair c1
make_doc "$REMOTE/dev/go/remote-only.md"
run_sync pull "$REMOTE" --yes
expect_code 0 "案例 1"
expect_file "$LOCAL/dev/go/remote-only.md" "案例 1：pull 應複製對方知識檔"
expect_grep "$LOCAL/dev/go/index.md" "remote-only.md" "案例 1：本機索引應登錄新檔"
expect_no_file "$REMOTE/dev/go/index.md" "案例 1：pull 不該改動來源端"

# ---- 案例 2：push 方向相反，且接收端獨有的檔案不被刪除 ----
new_pair c2
make_doc "$LOCAL/dev/go/local-only.md"
make_doc "$REMOTE/ops/docker/remote-keep.md"
run_sync push "$REMOTE" --yes
expect_code 0 "案例 2"
expect_file "$REMOTE/dev/go/local-only.md" "案例 2：push 應複製本機知識檔"
expect_file "$REMOTE/ops/docker/remote-keep.md" "案例 2：接收端獨有檔案不得被刪除"
expect_no_file "$LOCAL/ops/docker/remote-keep.md" "案例 2：push 不該回頭改本機"

# ---- 案例 3：內容相同不重複搬運，計畫顯示為相同 ----
new_pair c3
make_doc "$LOCAL/dev/go/same.md"
make_doc "$REMOTE/dev/go/same.md"
run_sync push "$REMOTE" --yes
expect_code 0 "案例 3"
expect_grep "$ROOT/out.txt" "相同（略過）：1" "案例 3：內容相同應計為相同"
expect_grep "$ROOT/out.txt" "沒有需要搬運的知識檔" "案例 3：無事可做"

# ---- 案例 4：同路徑不同內容預設跳過，結束碼 2，接收端內容不變 ----
new_pair c4
make_doc "$LOCAL/dev/go/conflict.md" "本機版本"
make_doc "$REMOTE/dev/go/conflict.md" "對方版本"
run_sync push "$REMOTE" --yes
expect_code 2 "案例 4"
expect_grep "$REMOTE/dev/go/conflict.md" "對方版本" "案例 4：接收端內容不得被改動"

# ---- 案例 5：--overwrite 以來源覆蓋，並備份被覆蓋的原檔 ----
new_pair c5
make_doc "$LOCAL/dev/go/conflict.md" "本機版本"
make_doc "$REMOTE/dev/go/conflict.md" "對方版本"
run_sync push "$REMOTE" --overwrite --yes
expect_code 0 "案例 5"
expect_grep "$REMOTE/dev/go/conflict.md" "本機版本" "案例 5：應以來源覆蓋"
BACKUP="$(find "$ROOT" -path '*/backups/sync-*/dev/go/conflict.md' | head -n 1)"
[ -n "$BACKUP" ] || {
    echo "❌ 案例 5：未留下覆蓋前備份" >&2; ls -R "$ROOT" >&2; exit 1;
}
expect_grep "$BACKUP" "對方版本" "案例 5：備份應為被覆蓋的原內容"

# ---- 案例 6：--dry-run 不寫入任何檔案 ----
new_pair c6
make_doc "$LOCAL/dev/go/planned.md"
run_sync push "$REMOTE" --dry-run
expect_code 0 "案例 6"
expect_no_file "$REMOTE/dev/go/planned.md" "案例 6：--dry-run 不得寫入"
expect_grep "$ROOT/out.txt" "--dry-run：未寫入任何內容。" "案例 6：應標示為 dry-run"

# ---- 案例 7：非互動環境未帶 --yes 直接中止，不寫入 ----
new_pair c7
make_doc "$LOCAL/dev/go/need-consent.md"
run_sync push "$REMOTE"
expect_code 3 "案例 7"
expect_no_file "$REMOTE/dev/go/need-consent.md" "案例 7：未授權不得寫入"

# ---- 案例 8：deprecated/ 子樹一併搬運，並登錄到停用索引 ----
new_pair c8
make_doc "$LOCAL/deprecated/dev/go/old.md"
run_sync push "$REMOTE" --yes
expect_code 0 "案例 8"
expect_file "$REMOTE/deprecated/dev/go/old.md" "案例 8：deprecated/ 應一併搬運"
expect_grep "$REMOTE/deprecated/dev/go/index.md" "old.md" "案例 8：停用索引應登錄"

# ---- 案例 9：對方路徑不是知識庫時中止 ----
new_pair c9
mkdir -p "$ROOT/not-a-kb"
run_sync push "$ROOT/not-a-kb" --yes
expect_code 1 "案例 9"
expect_grep "$ROOT/out.txt" "缺少 index.md" "案例 9：應指出不像知識庫"

# ---- 案例 10：兩端指向同一目錄時中止 ----
new_pair c10
run_sync push "$LOCAL" --yes
expect_code 1 "案例 10"
expect_grep "$ROOT/out.txt" "同一個目錄" "案例 10：應拒絕自我同步"

# ---- 案例 11：未知方向與缺參數皆為參數錯誤 ----
run_sync sideways "$ROOT/c1-remote" --yes
expect_code 1 "案例 11a"
run_sync pull
expect_code 1 "案例 11b"

echo "✅ kb-sync.sh smoke test passed"
