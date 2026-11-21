#!/bin/sh
# 隔離 smoke test：驗證注入區塊的維運行為。
#
# 涵蓋兩件事：
#   1. kb-injection.sh 與 repo 的 scripts/init-injection.sh 的 make_block() 文字逐字相同。
#      兩者各自散佈（skill 可獨立安裝、init-injection.sh 支援單檔遠端執行），無法共用同一
#      份來源，只能靠這個比對防止分歧。在 repo 外安裝時找不到 init-injection.sh，跳過此項。
#   2. kb-injection.sh 的 list／update：舊區塊會被就地換新且保留原位置、區塊外內容不動、
#      重跑無變化、無區塊時拒絕、非互動未帶 --yes 中止。
#   2b. kb-injection.sh 的 inject：檔頭注入、已有區塊不動、--create 只建全域指令檔、保留 symlink。
set -e

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
REPO_INJECT="$SCRIPT_DIR/../../../scripts/init-injection.sh"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/kb-inject-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export HOME="$ROOT/home"
export KNOWLEDGE_BASE_DIR="$ROOT/home/.knowledge-skill/knowledge"
mkdir -p "$HOME"

fail() {
    printf '❌ %s\n' "$1"
    exit 1
}

# 取 make_block() 的函式本體（`make_block() {` 之後到單獨一行 `}` 之前）
extract_make_block() {
    awk '
        /^make_block\(\) \{$/ { inblock=1; next }
        inblock && /^\}$/ { exit }
        inblock { print }
    ' "$1"
}

# ---- 1. 兩份 make_block() 文字一致 ----
if [ -f "$REPO_INJECT" ]; then
    extract_make_block "$SCRIPT_DIR/kb-injection.sh" > "$ROOT/block-skill.txt"
    extract_make_block "$REPO_INJECT" > "$ROOT/block-repo.txt"
    [ -s "$ROOT/block-skill.txt" ] || fail "kb-injection.sh 取不到 make_block() 本體"
    [ -s "$ROOT/block-repo.txt" ] || fail "init-injection.sh 取不到 make_block() 本體"
    if ! diff -u "$ROOT/block-repo.txt" "$ROOT/block-skill.txt"; then
        fail "make_block() 文字不一致：kb-injection.sh 與 scripts/init-injection.sh 需同步"
    fi
    echo "✅ make_block() 兩份文字一致"
    HAVE_REPO=1
else
    echo "ℹ️  找不到 ${REPO_INJECT}，跳過與 init-injection.sh 相關的檢查（非 repo 內執行）"
    HAVE_REPO=0
fi

# ---- 2. kb-injection.sh 行為 ----
OLD_BLOCK='<!-- BEGIN knowledge-skill:shared-kb -->
# 共用知識庫優先參考

在執行任何任務動作前，先讀取跨專案共用知識庫，沿用既有慣例與已知陷阱。

- 知識庫位置：`$HOME/.knowledge-skill/knowledge/`，可由環境變數 `KNOWLEDGE_BASE_DIR` 覆寫
- 動作前讀取索引 `$HOME/.knowledge-skill/knowledge/index.md`，依「觸發時機」判斷是否有相關知識
- 有匹配項目時先載入對應知識檔；無匹配項目則直接執行
<!-- END knowledge-skill:shared-kb -->'

TARGET="$ROOT/CLAUDE.md"
{
    printf '# 專案規範\n\n先有一段前置中文內容，區塊不在檔頭。\n\n'
    printf '%s\n' "$OLD_BLOCK"
    printf '\n## 後續章節\n\n區塊之後的中文內容必須原樣保留。\n'
} > "$TARGET"
cp "$TARGET" "$ROOT/original.md"

# 先落地再 grep：直接接管線會讓 grep -q 提早關閉 stdout，list 寫入時噴 broken pipe
sh "$SCRIPT_DIR/kb-injection.sh" list "$TARGET" > "$ROOT/list-before.txt"
grep -q "需更新" "$ROOT/list-before.txt" || fail "list 未把舊區塊判定為需更新"

sh "$SCRIPT_DIR/kb-injection.sh" update "$TARGET" --yes >/dev/null

grep -q "索引分兩層" "$TARGET" || fail "update 後未取得現行區塊內容"
grep -q "依「觸發時機」判斷是否有相關知識" "$TARGET" && fail "update 後仍殘留舊區塊文字"
[ "$(grep -c 'BEGIN knowledge-skill:shared-kb' "$TARGET")" -eq 1 ] || fail "marker 數量不為 1"
head -n 1 "$TARGET" | grep -q '^# 專案規範$' || fail "區塊被搬到檔頭，未保留原位置"
grep -q "區塊之後的中文內容必須原樣保留。" "$TARGET" || fail "區塊之後的內容遺失"
grep -q "先有一段前置中文內容，區塊不在檔頭。" "$TARGET" || fail "區塊之前的內容遺失"
ls "$TARGET".knowledge-skill.bak.* >/dev/null 2>&1 || fail "未產生備份檔"
diff -q "$ROOT/original.md" "$TARGET".knowledge-skill.bak.* >/dev/null \
    || fail "備份檔內容與原檔不符"

# 重跑：已是現行版本則不再改動
cp "$TARGET" "$ROOT/after-first.md"
sh "$SCRIPT_DIR/kb-injection.sh" update "$TARGET" --yes >/dev/null
diff -q "$ROOT/after-first.md" "$TARGET" >/dev/null || fail "重跑 update 後內容改變（非 idempotent）"
sh "$SCRIPT_DIR/kb-injection.sh" list "$TARGET" > "$ROOT/list-after.txt"
grep -q "最新" "$ROOT/list-after.txt" || fail "list 未把更新後的檔案判定為最新"

# 無區塊的檔案：拒絕並提示改用 init-injection.sh
NOBLOCK="$ROOT/AGENTS.md"
printf '# 專案規範\n\n沒有注入區塊。\n' > "$NOBLOCK"
cp "$NOBLOCK" "$ROOT/noblock-original.md"
rc=0
sh "$SCRIPT_DIR/kb-injection.sh" update "$NOBLOCK" --yes >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "無區塊時結束碼應為 1（實得 ${rc}）"
diff -q "$ROOT/noblock-original.md" "$NOBLOCK" >/dev/null || fail "無區塊的檔案被改動"

# 非互動且未帶 --yes：中止且不改檔
printf '%s\n' "$OLD_BLOCK" > "$ROOT/GEMINI.md"
cp "$ROOT/GEMINI.md" "$ROOT/gemini-original.md"
rc=0
sh "$SCRIPT_DIR/kb-injection.sh" update "$ROOT/GEMINI.md" </dev/null >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] || fail "未授權時結束碼應為 3（實得 ${rc}）"
diff -q "$ROOT/gemini-original.md" "$ROOT/GEMINI.md" >/dev/null || fail "未授權卻改動了檔案"

echo "✅ kb-injection.sh list／update 行為符合預期"

# ---- 2b. kb-injection.sh inject（首次注入）----
INJ_DIR="$ROOT/inject"
mkdir -p "$INJ_DIR"
printf '# 既有規範\n\n注入前就有的中文內容。\n' > "$INJ_DIR/AGENTS.md"
cp "$INJ_DIR/AGENTS.md" "$ROOT/inject-original.md"

sh "$SCRIPT_DIR/kb-injection.sh" inject "$INJ_DIR/AGENTS.md" --yes >/dev/null
head -n 1 "$INJ_DIR/AGENTS.md" | grep -q 'BEGIN knowledge-skill:shared-kb' || fail "inject 未把區塊放在檔頭"
grep -q "索引分兩層" "$INJ_DIR/AGENTS.md" || fail "inject 後未取得現行區塊內容"
grep -q "注入前就有的中文內容。" "$INJ_DIR/AGENTS.md" || fail "inject 後原內容遺失"
ls "$INJ_DIR/AGENTS.md".knowledge-skill.bak.* >/dev/null 2>&1 || fail "inject 未產生備份檔"
diff -q "$ROOT/inject-original.md" "$INJ_DIR/AGENTS.md".knowledge-skill.bak.* >/dev/null \
    || fail "inject 備份檔內容與原檔不符"

# 重跑：已有區塊則不動
cp "$INJ_DIR/AGENTS.md" "$ROOT/inject-after.md"
sh "$SCRIPT_DIR/kb-injection.sh" inject "$INJ_DIR/AGENTS.md" --yes >/dev/null
diff -q "$ROOT/inject-after.md" "$INJ_DIR/AGENTS.md" >/dev/null || fail "重跑 inject 後內容改變（非 idempotent）"
[ "$(grep -c 'BEGIN knowledge-skill:shared-kb' "$INJ_DIR/AGENTS.md")" -eq 1 ] || fail "重跑 inject 後 marker 重複"

# 已有舊區塊：inject 不動並提示改用 update
printf '%s\n' "$OLD_BLOCK" > "$INJ_DIR/CLAUDE.md"
cp "$INJ_DIR/CLAUDE.md" "$ROOT/inject-stale.md"
sh "$SCRIPT_DIR/kb-injection.sh" inject "$INJ_DIR/CLAUDE.md" --yes > "$ROOT/inject-stale.txt"
grep -q "kb-injection.sh update" "$ROOT/inject-stale.txt" || fail "inject 遇舊區塊未提示改用 update"
diff -q "$ROOT/inject-stale.md" "$INJ_DIR/CLAUDE.md" >/dev/null || fail "inject 改動了既有的舊區塊"

# 非互動且未帶 --yes：中止且不改檔
printf '# 待注入\n' > "$INJ_DIR/GEMINI.md"
cp "$INJ_DIR/GEMINI.md" "$ROOT/inject-noauth.md"
rc=0
sh "$SCRIPT_DIR/kb-injection.sh" inject "$INJ_DIR/GEMINI.md" </dev/null >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 3 ] || fail "inject 未授權時結束碼應為 3（實得 ${rc}）"
diff -q "$ROOT/inject-noauth.md" "$INJ_DIR/GEMINI.md" >/dev/null || fail "inject 未授權卻改動了檔案"

# 檔名不是三種指令檔：拒絕
printf '# 說明\n' > "$INJ_DIR/README.md"
rc=0
sh "$SCRIPT_DIR/kb-injection.sh" inject "$INJ_DIR/README.md" --yes >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "inject 非指令檔時結束碼應為 1（實得 ${rc}）"
grep -q 'BEGIN knowledge-skill:shared-kb' "$INJ_DIR/README.md" && fail "inject 改動了非指令檔"

# 專案目錄的檔案不存在：有無 --create 都不建立
mkdir -p "$INJ_DIR/project"
rc=0
sh "$SCRIPT_DIR/kb-injection.sh" inject "$INJ_DIR/project/AGENTS.md" --yes >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "inject 檔案不存在時結束碼應為 1（實得 ${rc}）"
rc=0
sh "$SCRIPT_DIR/kb-injection.sh" inject "$INJ_DIR/project/AGENTS.md" --create --yes >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "inject --create 非全域檔時結束碼應為 1（實得 ${rc}）"
[ -e "$INJ_DIR/project/AGENTS.md" ] && fail "inject --create 建立了專案目錄的指令檔"

# 全域指令檔：工具目錄不在時不建；在時 list 列為未建立，--create 建立
rc=0
sh "$SCRIPT_DIR/kb-injection.sh" inject "$HOME/.codex/AGENTS.md" --create --yes >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "工具目錄不存在時 --create 結束碼應為 1（實得 ${rc}）"
[ -e "$HOME/.codex" ] && fail "--create 建立了不存在的工具目錄"

mkdir -p "$HOME/.claude"
sh "$SCRIPT_DIR/kb-injection.sh" list > "$ROOT/list-global.txt"
grep -q "未建立.*\.claude/CLAUDE\.md" "$ROOT/list-global.txt" || fail "list 未把缺檔的全域指令檔列為未建立"
grep -q "\.codex/AGENTS\.md" "$ROOT/list-global.txt" && fail "list 列出了工具目錄不存在的全域指令檔"

sh "$SCRIPT_DIR/kb-injection.sh" inject "$HOME/.claude/CLAUDE.md" --create --yes >/dev/null
head -n 1 "$HOME/.claude/CLAUDE.md" | grep -q 'BEGIN knowledge-skill:shared-kb' || fail "--create 建立的檔案沒有區塊"
ls "$HOME/.claude/CLAUDE.md".knowledge-skill.bak.* >/dev/null 2>&1 && fail "--create 新建檔不應留備份"

# symlink：寫回時保留 symlink，區塊落在連結目標
mkdir -p "$HOME/.ai-global" "$HOME/.gemini"
printf '# 共用指令\n' > "$HOME/.ai-global/AGENTS.md"
ln -s "$HOME/.ai-global/AGENTS.md" "$HOME/.gemini/GEMINI.md"
sh "$SCRIPT_DIR/kb-injection.sh" inject "$HOME/.gemini/GEMINI.md" --yes >/dev/null
[ -L "$HOME/.gemini/GEMINI.md" ] || fail "inject 把 symlink 換成了一般檔案"
grep -q 'BEGIN knowledge-skill:shared-kb' "$HOME/.ai-global/AGENTS.md" || fail "inject 未寫入 symlink 目標"
grep -q "# 共用指令" "$HOME/.ai-global/AGENTS.md" || fail "inject 後 symlink 目標的原內容遺失"

# update 經由 symlink 寫回時同樣保留 symlink
{
    printf '%s\n' "$OLD_BLOCK"
    printf '\n# 共用指令\n'
} > "$HOME/.ai-global/AGENTS.md"
sh "$SCRIPT_DIR/kb-injection.sh" update "$HOME/.gemini/GEMINI.md" --yes >/dev/null
[ -L "$HOME/.gemini/GEMINI.md" ] || fail "update 把 symlink 換成了一般檔案"
grep -q "索引分兩層" "$HOME/.ai-global/AGENTS.md" || fail "update 未寫入 symlink 目標"

echo "✅ kb-injection.sh inject 行為符合預期"

# ---- 3. init-injection.sh --refresh ----
if [ "$HAVE_REPO" -eq 1 ]; then
    REFRESH_DIR="$ROOT/refresh"
    mkdir -p "$REFRESH_DIR"
    {
        printf '# 專案規範\n\n區塊之前的中文內容。\n\n'
        printf '%s\n' "$OLD_BLOCK"
        printf '\n## 後續章節\n\n區塊之後的中文內容。\n'
    } > "$REFRESH_DIR/CLAUDE.md"
    cp "$REFRESH_DIR/CLAUDE.md" "$ROOT/refresh-original.md"

    # 不帶旗標：既有區塊維持不覆蓋
    sh "$REPO_INJECT" "$REFRESH_DIR" CLAUDE.md > "$ROOT/inject-skip.txt"
    grep -q -- "--refresh" "$ROOT/inject-skip.txt" || fail "略過訊息未提示改用 --refresh"
    diff -q "$ROOT/refresh-original.md" "$REFRESH_DIR/CLAUDE.md" >/dev/null \
        || fail "未帶 --refresh 卻改動了既有區塊"

    # 帶 --refresh：就地更新並保留原位置與前後內容
    sh "$REPO_INJECT" --refresh "$REFRESH_DIR" CLAUDE.md >/dev/null
    grep -q "索引分兩層" "$REFRESH_DIR/CLAUDE.md" || fail "--refresh 後未取得現行區塊內容"
    [ "$(grep -c 'BEGIN knowledge-skill:shared-kb' "$REFRESH_DIR/CLAUDE.md")" -eq 1 ] \
        || fail "--refresh 後 marker 數量不為 1"
    head -n 1 "$REFRESH_DIR/CLAUDE.md" | grep -q '^# 專案規範$' || fail "--refresh 把區塊搬到了檔頭"
    grep -q "區塊之後的中文內容。" "$REFRESH_DIR/CLAUDE.md" || fail "--refresh 後內容遺失"
    ls "$REFRESH_DIR/CLAUDE.md".knowledge-skill.bak.* >/dev/null 2>&1 || fail "--refresh 未產生備份檔"

    # 重跑：已是現行版本則不再改動
    cp "$REFRESH_DIR/CLAUDE.md" "$ROOT/refresh-after.md"
    sh "$REPO_INJECT" --refresh "$REFRESH_DIR" CLAUDE.md >/dev/null
    diff -q "$ROOT/refresh-after.md" "$REFRESH_DIR/CLAUDE.md" >/dev/null \
        || fail "重跑 --refresh 後內容改變（非 idempotent）"

    # 無區塊的檔案：--refresh 仍走既有的檔頭注入
    printf '# 既有內容\n' > "$REFRESH_DIR/AGENTS.md"
    sh "$REPO_INJECT" --refresh "$REFRESH_DIR" AGENTS.md >/dev/null
    head -n 1 "$REFRESH_DIR/AGENTS.md" | grep -q 'BEGIN knowledge-skill:shared-kb' \
        || fail "--refresh 未對無區塊的檔案插入檔頭"
    grep -q "# 既有內容" "$REFRESH_DIR/AGENTS.md" || fail "檔頭注入後原內容遺失"

    # symlink：檔頭注入與 --refresh 都寫入連結目標，symlink 保留
    LINK_DIR="$ROOT/refresh-link"
    mkdir -p "$LINK_DIR"
    printf '# 共用指令\n' > "$ROOT/shared-agents.md"
    ln -s "$ROOT/shared-agents.md" "$LINK_DIR/CLAUDE.md"
    sh "$REPO_INJECT" "$LINK_DIR" CLAUDE.md >/dev/null
    [ -L "$LINK_DIR/CLAUDE.md" ] || fail "init-injection.sh 注入時把 symlink 換成了一般檔案"
    grep -q 'BEGIN knowledge-skill:shared-kb' "$ROOT/shared-agents.md" || fail "init-injection.sh 未寫入 symlink 目標"
    {
        printf '%s\n' "$OLD_BLOCK"
        printf '\n# 共用指令\n'
    } > "$ROOT/shared-agents.md"
    sh "$REPO_INJECT" --refresh "$LINK_DIR" CLAUDE.md >/dev/null
    [ -L "$LINK_DIR/CLAUDE.md" ] || fail "--refresh 把 symlink 換成了一般檔案"
    grep -q "索引分兩層" "$ROOT/shared-agents.md" || fail "--refresh 未寫入 symlink 目標"

    echo "✅ init-injection.sh --refresh 行為符合預期"
fi

echo "✅ test-injection-block.sh 全數通過"
