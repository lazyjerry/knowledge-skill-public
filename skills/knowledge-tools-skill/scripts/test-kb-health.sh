#!/bin/sh
# 隔離 smoke test：驗證 kb-health.sh 的健康／不健康、JSON、log 與權限契約。
set -e

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/kb-health-test.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
export HOME="$ROOT/home"
export KNOWLEDGE_BASE_DIR="$ROOT/knowledge"
mkdir -p "$HOME" "$KNOWLEDGE_BASE_DIR/dev/go"

DOC='---
標題: 健康知識
觸發時機: 需要測試健康檢查時
取代: -
被取代於: -
---

## 摘要
健康摘要

## 脈絡與問題陳述
測試脈絡

## 決策驅力
-

## 考量選項
- 採用確定性檢查

## 各選項利弊
-

## 決策結果
採用確定性檢查

## 影響
結果可重現

## 驗證
-

## 補充資訊
隔離測試
'
printf '%s' "$DOC" > "$KNOWLEDGE_BASE_DIR/dev/go/healthy.md"
# 兩層索引：頂層只列分類目錄（第一欄非連結），完整清單在各分類的 index.md。
cat > "$KNOWLEDGE_BASE_DIR/index.md" <<'EOF'
# 索引

## 分類目錄

| 分類 | 筆數 | 知識標題 |
|------|------|----------|
| `dev/go` | 1 | 健康知識 |
EOF
cat > "$KNOWLEDGE_BASE_DIR/dev/go/index.md" <<'EOF'
# `dev/go` 分類索引

| 知識 | 觸發時機 | 摘要 | 取代 |
|------|----------|------|------|
| [健康知識](healthy.md) | 需要測試健康檢查時 | 健康摘要 | - |
EOF

set +e
sh "$SCRIPT_DIR/kb-health.sh" --format json --source cli > "$ROOT/healthy.json"
code=$?
set -e
if [ "$code" -ne 0 ]; then
    echo "健康 fixture 預期 exit 0，實際 $code" >&2
    cat "$ROOT/healthy.json" >&2
    exit 1
fi
grep -Fq '"healthy":true' "$ROOT/healthy.json"
grep -Fq '"findings":0' "$ROOT/healthy.json"
command -v jq >/dev/null 2>&1 && jq empty "$ROOT/healthy.json"

# 正確的生效／停用互惠取代關係仍應健康。
mkdir -p "$KNOWLEDGE_BASE_DIR/deprecated/dev/go"
printf '%s' "$DOC" | sed 's/標題: 健康知識/標題: 新知識/; s/取代: -/取代: dev\/go\/old.md/' > "$KNOWLEDGE_BASE_DIR/dev/go/new.md"
printf '%s' "$DOC" | sed 's/標題: 健康知識/標題: 舊知識/; s/被取代於: -/被取代於: dev\/go\/new.md/' > "$KNOWLEDGE_BASE_DIR/deprecated/dev/go/old.md"
cat >> "$KNOWLEDGE_BASE_DIR/dev/go/index.md" <<'EOF'
| [新知識](new.md) | 需要測試健康檢查時 | 健康摘要 | dev/go/old.md |
EOF
cat > "$KNOWLEDGE_BASE_DIR/deprecated/index.md" <<'EOF'
# 停用索引

## 分類目錄

| 分類 | 筆數 | 知識標題 |
|------|------|----------|
| `dev/go` | 1 | 舊知識 |
EOF
cat > "$KNOWLEDGE_BASE_DIR/deprecated/dev/go/index.md" <<'EOF'
# `dev/go` 分類已停用索引

| 知識 | 觸發時機 | 摘要 | 被取代於 |
|------|----------|------|----------|
| [舊知識](old.md) | 需要測試健康檢查時 | 健康摘要 | dev/go/new.md |
EOF
sh "$SCRIPT_DIR/kb-health.sh" --format json --source cli > "$ROOT/supersede-healthy.json"
grep -Fq '"healthy":true' "$ROOT/supersede-healthy.json"

# 加入孤兒與不完整 MADR，同時讓索引多一條斷鏈。
printf '%s\n' '---' '標題: [知識主題]' '觸發時機:' '取代: -' '被取代於: -' '---' '## 摘要' '[一句話描述核心結論]' > "$KNOWLEDGE_BASE_DIR/dev/go/bad.md"
cat >> "$KNOWLEDGE_BASE_DIR/dev/go/index.md" <<'EOF'
| [遺失頁](missing.md) | 遺失 | 遺失 | - |
EOF
sed 's/被取代於: dev\/go\/new.md/被取代於: dev\/go\/missing-new.md/' "$KNOWLEDGE_BASE_DIR/deprecated/dev/go/old.md" > "$ROOT/old-bad.md"
mv "$ROOT/old-bad.md" "$KNOWLEDGE_BASE_DIR/deprecated/dev/go/old.md"

set +e
sh "$SCRIPT_DIR/kb-health.sh" --format json --source ui > "$ROOT/unhealthy.json"
code=$?
set -e
[ "$code" -eq 2 ] || { echo "預期 exit 2，實際 $code" >&2; exit 1; }
for expected in '"healthy":false' '"code":"orphan_file"' '"code":"broken_link"' '"code":"invalid_title"' '"code":"section_count"' '"code":"superseded_by_target_missing"'; do
    grep -Fq "$expected" "$ROOT/unhealthy.json" || { echo "缺少 $expected" >&2; exit 1; }
done
command -v jq >/dev/null 2>&1 && jq empty "$ROOT/unhealthy.json"

LOG_DIR="$HOME/.knowledge-skill/logs/health"
[ -f "$LOG_DIR/latest.json" ]
[ "$(wc -l < "$LOG_DIR/history.jsonl" | tr -d ' ')" -eq 3 ]
mode_of() {
    stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1"
}
[ "$(mode_of "$LOG_DIR")" = "700" ]
[ "$(mode_of "$LOG_DIR/latest.json")" = "600" ]
[ "$(mode_of "$LOG_DIR/history.jsonl")" = "600" ]

# 舊的單層全量索引必須被指出來：解析對它刻意向後相容（讀得到、不算斷鏈也不算孤兒），
# 沒有這個 finding 就完全沒有徵兆，使用者不會知道該重建；落後版本的 kb-reindex.sh
# 也會把兩層寫回單層，同樣要能被抓到。
# 另起一個知識庫目錄，不影響上面已完成的斷言（HOME 沿用，history.jsonl 只會多一行）。
export KNOWLEDGE_BASE_DIR="$ROOT/knowledge-single-tier"
mkdir -p "$KNOWLEDGE_BASE_DIR/dev/go"
printf '%s' "$DOC" > "$KNOWLEDGE_BASE_DIR/dev/go/healthy.md"
cat > "$KNOWLEDGE_BASE_DIR/index.md" <<'EOF'
# 索引

| 知識 | 觸發時機 | 摘要 | 取代 |
|------|----------|------|------|
| [健康知識](dev/go/healthy.md) | 需要測試健康檢查時 | 健康摘要 | - |
EOF

set +e
sh "$SCRIPT_DIR/kb-health.sh" --format json --source cli > "$ROOT/single-tier.json"
code=$?
set -e
[ "$code" -eq 2 ] || { echo "單層索引預期 exit 2，實際 $code" >&2; cat "$ROOT/single-tier.json" >&2; exit 1; }
grep -Fq '"code":"index_single_tier"' "$ROOT/single-tier.json" || {
    echo "未偵測到單層索引" >&2; cat "$ROOT/single-tier.json" >&2; exit 1;
}
# 內容本身沒問題，不該連帶誤報斷鏈或孤兒。
for unexpected in '"code":"broken_link"' '"code":"orphan_file"'; do
    grep -Fq "$unexpected" "$ROOT/single-tier.json" && {
        echo "單層索引不該誤報 $unexpected" >&2; cat "$ROOT/single-tier.json" >&2; exit 1;
    }
done

# 重建成兩層後該 finding 必須消失。
sh "$SCRIPT_DIR/kb-reindex.sh" > /dev/null
set +e
sh "$SCRIPT_DIR/kb-health.sh" --format json --source cli > "$ROOT/migrated.json"
code=$?
set -e
[ "$code" -eq 0 ] || { echo "重建後預期 exit 0，實際 $code" >&2; cat "$ROOT/migrated.json" >&2; exit 1; }
grep -Fq '"healthy":true' "$ROOT/migrated.json"
grep -Fq '"findings":0' "$ROOT/migrated.json"

# 欄位含 `|` 的知識檔：kb-reindex.sh 寫索引時一律把 `|` 換成 `/`（否則會打斷 Markdown
# 表格欄位），health 比對時必須套用同一個正規化，否則 index_*_stale 恆為真——reindex 只是
# 把索引重寫成一模一樣的內容，使用者按幾次「重新整理索引」都消不掉這個 finding。
export KNOWLEDGE_BASE_DIR="$ROOT/knowledge-pipe"
mkdir -p "$KNOWLEDGE_BASE_DIR/dev/go"
printf '%s' "$DOC" \
    | sed 's|觸發時機: 需要測試健康檢查時|觸發時機: 出現 Mockery\\ExpectationInterface\|Mockery\\HigherOrderMessage 才需要參考|' \
    > "$KNOWLEDGE_BASE_DIR/dev/go/piped.md"
printf '%s\n' '# 索引' '' '## 知識清單' '' '| 知識 | 觸發時機 | 摘要 | 取代 |' '|------|----------|------|------|' \
    > "$KNOWLEDGE_BASE_DIR/index.md"
sh "$SCRIPT_DIR/kb-reindex.sh" > /dev/null

set +e
sh "$SCRIPT_DIR/kb-health.sh" --format json --source cli > "$ROOT/piped.json"
code=$?
set -e
[ "$code" -eq 0 ] || { echo "含 | 欄位重建後預期 exit 0，實際 $code" >&2; cat "$ROOT/piped.json" >&2; exit 1; }
grep -Fq '"healthy":true' "$ROOT/piped.json" || {
    echo "含 | 欄位的知識檔被誤報為不健康" >&2; cat "$ROOT/piped.json" >&2; exit 1;
}

echo "✅ kb-health.sh smoke test passed"
