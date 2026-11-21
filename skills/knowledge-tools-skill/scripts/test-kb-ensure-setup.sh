#!/bin/sh
# 隔離 smoke test：驗證 kb-ensure-setup.sh。
#
# 涵蓋：
#   1. shell 設定檔的 export 搬進設定檔、從 rc 移除（其餘內容不動、留備份），並補齊分類目錄
#   2. 重跑無變更（idempotent）
#   3. --dry-run 與非互動未帶 --yes 都不改檔
#   4. 設定檔已有不同值、或值含無法解析的變數 → 衝突，不動任何檔
#   5. 設定檔已有相同值 → 只移除 rc 行，不重複寫入
#   6. 新裝置：知識庫目錄不存在 → 建立目錄、六個分類與索引
#   7. 沙箱（HOME 在暫存區）時，暫存區的知識庫位置照常放行；真實 HOME 的防護另以手動驗證
set -e

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/kb-ensure-setup-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
unset KNOWLEDGE_BASE_DIR ZDOTDIR
RUN="$SCRIPT_DIR/kb-ensure-setup.sh"

fail() {
    printf '❌ %s\n' "$1"
    exit 1
}

# 每個情境一個乾淨的 HOME：$1 情境名稱
new_home() {
    HOME="$ROOT/$1"
    export HOME
    mkdir -p "$HOME/.knowledge-skill/knowledge/dev" "$HOME/.knowledge-skill/knowledge/ops"
    CONFIG="$HOME/.config/knowledge-skill/config"
}

write_zshrc() {
    printf 'alias ll="ls -l"\n\n# knowledge-skill: 共用知識庫位置\n%s\n# 其他設定\n' "$1" > "$HOME/.zshrc"
}

expect_code() {
    [ "$2" -eq "$3" ] || fail "$1：結束碼應為 $3，實際 $2"
}

# --- 1. 遷移 + 補分類 ---
new_home migrate
write_zshrc 'export KNOWLEDGE_BASE_DIR="$HOME/.knowledge-skill/knowledge"'
code=0; sh "$RUN" --yes >/dev/null || code=$?
expect_code "遷移" "$code" 0
grep -qxF 'KNOWLEDGE_BASE_DIR=~/.knowledge-skill/knowledge' "$CONFIG" || fail "設定檔應寫入 ~ 形式的值"
if grep -q 'KNOWLEDGE_BASE_DIR\|knowledge-skill: 共用知識庫位置' "$HOME/.zshrc"; then fail "rc 應移除指派與註解行"; fi
grep -qF 'alias ll="ls -l"' "$HOME/.zshrc" && grep -qF '# 其他設定' "$HOME/.zshrc" || fail "rc 其餘內容不應被動到"
ls "$HOME"/.zshrc.knowledge-skill.bak.* >/dev/null 2>&1 || fail "應留下 rc 備份"
for c in ui ux dev ops data else; do
    [ -d "$HOME/.knowledge-skill/knowledge/$c" ] || fail "缺分類目錄 $c"
done
echo "✅ 遷移並補齊分類目錄"

# --- 2. 冪等 ---
out="$(sh "$RUN" --yes)"
printf '%s\n' "$out" | grep -q '無需變更' || fail "重跑應無需變更：$out"
[ "$(grep -c '^KNOWLEDGE_BASE_DIR=' "$CONFIG")" = 1 ] || fail "重跑不應重複寫入"
echo "✅ 重跑無變更"

# --- 3. dry-run 與未授權 ---
new_home dryrun
write_zshrc 'export KNOWLEDGE_BASE_DIR=~/.knowledge-skill/knowledge'
cp "$HOME/.zshrc" "$ROOT/dryrun.orig"
code=0; sh "$RUN" --dry-run >/dev/null || code=$?
expect_code "dry-run" "$code" 0
code=0; sh "$RUN" </dev/null >/dev/null || code=$?
expect_code "非互動未帶 --yes" "$code" 3
cmp -s "$HOME/.zshrc" "$ROOT/dryrun.orig" || fail "dry-run／未授權不應改 rc"
[ ! -e "$CONFIG" ] || fail "dry-run／未授權不應建立設定檔"
[ ! -d "$HOME/.knowledge-skill/knowledge/ui" ] || fail "dry-run／未授權不應建立分類目錄"
echo "✅ dry-run 與未授權皆不改檔"

# --- 4. 衝突 ---
new_home conflict
write_zshrc 'export KNOWLEDGE_BASE_DIR="$HOME/.knowledge-skill/knowledge"'
mkdir -p "$(dirname "$CONFIG")"
printf 'KNOWLEDGE_BASE_DIR=~/other-kb\n' > "$CONFIG"
mkdir -p "$HOME/other-kb"
cp "$HOME/.zshrc" "$ROOT/conflict.orig"
code=0; sh "$RUN" --yes >/dev/null || code=$?
expect_code "設定檔值不同" "$code" 2
cmp -s "$HOME/.zshrc" "$ROOT/conflict.orig" || fail "衝突時不應改 rc"
grep -qxF 'KNOWLEDGE_BASE_DIR=~/other-kb' "$CONFIG" || fail "衝突時不應改設定檔"

new_home dynamic
write_zshrc 'export KNOWLEDGE_BASE_DIR="$DROPBOX/kb"'
cp "$HOME/.zshrc" "$ROOT/dynamic.orig"
code=0; sh "$RUN" --yes >/dev/null || code=$?
expect_code "含其他變數" "$code" 2
cmp -s "$HOME/.zshrc" "$ROOT/dynamic.orig" || fail "無法解析時不應改 rc"
echo "✅ 衝突時不動任何檔"

# --- 5. 設定檔已有相同值 ---
new_home same
write_zshrc 'export KNOWLEDGE_BASE_DIR="$HOME/.knowledge-skill/knowledge"'
mkdir -p "$(dirname "$CONFIG")"
printf 'KNOWLEDGE_BASE_DIR="$HOME/.knowledge-skill/knowledge"\n' > "$CONFIG"
code=0; sh "$RUN" --yes >/dev/null || code=$?
expect_code "設定檔已有相同值" "$code" 0
[ "$(grep -c 'KNOWLEDGE_BASE_DIR=' "$CONFIG")" = 1 ] || fail "相同值不應重複寫入"
if grep -q 'KNOWLEDGE_BASE_DIR' "$HOME/.zshrc"; then fail "相同值時仍應移除 rc 行"; fi
echo "✅ 設定檔已有相同值時只清 rc"

# --- 6. 新裝置 ---
HOME="$ROOT/nokb"; export HOME; mkdir -p "$HOME"
code=0; sh "$RUN" --yes >/dev/null || code=$?
expect_code "新裝置" "$code" 0
for c in ui ux dev ops data else; do
    [ -d "$HOME/.knowledge-skill/knowledge/$c" ] || fail "新裝置缺分類目錄 $c"
done
[ -f "$HOME/.knowledge-skill/knowledge/index.md" ] || fail "新裝置應建立 index.md"
out="$(sh "$RUN" --yes)"
printf '%s\n' "$out" | grep -q '無需變更' || fail "新裝置建好後重跑應無需變更：$out"
echo "✅ 新裝置建立知識庫目錄、分類與索引"

# --- 7. 位置落在暫存區 ---
# 防護只在設定檔不在暫存區時觸發；沙箱 HOME 本身在暫存區，這裡驗的是「沙箱照常放行」
HOME="$ROOT/volatile"; export HOME; mkdir -p "$HOME"
(
    export KNOWLEDGE_BASE_DIR="/tmp/kb-ensure-setup-stale-$$"
    out="$(sh "$RUN" --dry-run 2>&1)" || true
    printf '%s\n' "$out" | grep -q '建立分類目錄' || fail "沙箱 HOME 在暫存區時應照常規劃建立：$out"
)
echo "✅ 沙箱（HOME 在暫存區）照常放行"

echo "✅ 全部通過"
