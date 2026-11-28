#!/bin/sh
# init-knowledge-base.sh
# 初始化「跨專案共用知識庫」：建立與 skill 規範一致的 knowledge 資料夾與 index.md，
# 並在使用非預設位置時，把位置寫入設定檔 ~/.config/knowledge-skill/config。
#
# 用法:
#   sh scripts/init-knowledge-base.sh [安裝位置]
#     [安裝位置]：知識庫的 base 目錄，knowledge/ 會建立於其下；預設 ~/.knowledge-skill/
#     未提供時 → 互動詢問（直接 Enter 採用預設）
#
# 產出:
#   <安裝位置>/knowledge/index.md   （沿用 skill 範本；不存在才建立，不覆蓋）
#   ~/.config/knowledge-skill/config （僅非預設位置；已有 KNOWLEDGE_BASE_DIR 設定則不覆蓋）
#
# 環境變數:
#   KNOWLEDGE_BASE_DIR  臨時覆寫知識庫位置，優先於設定檔。本腳本不再寫入 shell 設定檔；
#                       偵測到舊版留下的 export 時只提示移除，不自動修改。

set -e

ARG_TARGET="${1:-}"

# 預設 base 與其下的 knowledge 子目錄
DEFAULT_BASE="$HOME/.knowledge-skill"

# 範本來源（本腳本位於 repo 的 scripts/ 下）
SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
INDEX_TEMPLATE="$REPO_ROOT/skills/knowledge-skill/assets/knowledge-index.md"

# 把家目錄前綴換回 ~（顯示用，避免寫死絕對家目錄）
to_display() {
    case "$1" in
        "$HOME") echo "~" ;;
        "$HOME"/*) echo "~/${1#"$HOME"/}" ;;
        *) echo "$1" ;;
    esac
}

# 把開頭的 ~ 展開為家目錄
expand_home() {
    case "$1" in
        "~") echo "$HOME" ;;
        "~/"*) echo "$HOME/${1#"~/"}" ;;
        *) echo "$1" ;;
    esac
}

# ============================================================
# 步驟 1：決定安裝位置（base 目錄）
# ============================================================

if [ -n "$ARG_TARGET" ]; then
    BASE_DIR="$ARG_TARGET"
elif [ -t 0 ]; then
    printf "請輸入知識庫安裝位置 [預設 %s]: " "$(to_display "$DEFAULT_BASE")"
    read -r BASE_DIR || BASE_DIR=""
    [ -z "$BASE_DIR" ] && BASE_DIR="$DEFAULT_BASE"
else
    # 非互動且未給參數 → 採用預設
    BASE_DIR="$DEFAULT_BASE"
fi

BASE_DIR="$(expand_home "$BASE_DIR")"
# 去除尾端斜線（保留根目錄 "/"）
case "$BASE_DIR" in
    /) ;;
    */) BASE_DIR="${BASE_DIR%/}" ;;
esac

KB_DIR="$BASE_DIR/knowledge"

# ============================================================
# 步驟 2：建立 knowledge 資料夾與 index.md
# ============================================================

if ! mkdir -p "$KB_DIR" 2>/dev/null; then
    echo "❌ 無法建立知識庫資料夾: $KB_DIR"
    echo "   請確認對該路徑有寫入權限後重試。"
    exit 1
fi

if [ -f "$KB_DIR/index.md" ]; then
    echo "⚠️  已存在，略過（不覆蓋）: $KB_DIR/index.md"
elif [ -f "$INDEX_TEMPLATE" ]; then
    cp "$INDEX_TEMPLATE" "$KB_DIR/index.md"
    echo "✅ 建立知識庫索引: $KB_DIR/index.md"
else
    # 範本不存在（腳本被單獨複製出去）→ 內嵌備援，內容與 skill 範本一致
    cat > "$KB_DIR/index.md" <<'EOF'
# 公用知識庫索引

本目錄為**跨專案共用**的知識庫，儲存可重用的注意事項，供所有專案的任務參考。

> 📍 預設位置 `$HOME/.knowledge-skill/knowledge/`，可用環境變數 `KNOWLEDGE_BASE_DIR` 覆寫。

## 使用方式

1. **任務開始前**：根據下表的「觸發時機」判斷是否需要參考相關知識
2. **任務完成後**：如有可跨專案重用的注意事項，依分類目錄新增知識檔，再由 `kb-reindex.sh` 重建此索引

知識檔依分類歸檔（`ui`/`ux`/`dev`/`ops`/`data`/`else`，第二層依語言或框架），索引以相對路徑登錄。已停用決策見 [deprecated/index.md](deprecated/index.md)。

**何時產生知識檔案：**
- 使用者明確指定要記憶的原則、習慣或規則
- 跨專案可重用的工作方法或解決方案
- 透過互動修改後發現、未來仍適用的重要事項

**不需要產生：** 一般程式設計知識、框架標準用法、官方文件已說明的內容、僅對單一專案成立的細節

## 知識清單

| 知識 | 觸發時機 | 摘要 | 取代 |
|------|----------|------|------|
| <!-- 新增知識時由 kb-reindex.sh 自動登錄 --> |  |  |  |
EOF
    echo "✅ 建立知識庫索引（內嵌備援範本）: $KB_DIR/index.md"
fi

# 建立分類目錄骨架（idempotent；reindex/status 容忍空目錄）
for category in ui ux dev ops data else; do
    mkdir -p "$KB_DIR/$category"
done
echo "✅ 確認分類目錄骨架: ui ux dev ops data else"

# ============================================================
# 步驟 3：非預設位置 → 寫入設定檔 ~/.config/knowledge-skill/config
# ============================================================

# 位置存設定檔而非 shell 設定檔：hook、launchd 等執行環境不讀 ~/.zshrc，
# 只靠環境變數會解析不到；環境變數改為只作臨時覆寫。
KB_CONFIG="$HOME/.config/knowledge-skill/config"
KB_DISPLAY="$(to_display "$KB_DIR")"
CONFIG_LINE="KNOWLEDGE_BASE_DIR=$KB_DISPLAY"

# 暫存區路徑寫進設定檔，目錄被系統清掉後所有工具都會指向不存在的位置
is_volatile_path() {
    case "$1" in
        /tmp|/tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) return 0 ;;
    esac
    return 1
}

# 舊版把 export 寫進 shell 設定檔；環境變數優先於設定檔，留著會遮蔽這裡的設定
for rc in "${ZDOTDIR:-$HOME}/.zshrc" "$HOME/.zshenv" "$HOME/.bashrc" "$HOME/.profile"; do
    if [ -f "$rc" ] && grep -q "KNOWLEDGE_BASE_DIR" "$rc"; then
        echo ""
        echo "⚠️  $(to_display "$rc") 仍有 KNOWLEDGE_BASE_DIR 設定，環境變數會蓋過設定檔，建議移除該行。"
    fi
done

# 用 sed 取值：未命中也回 0，不會在 set -e 下中止
EXISTING_VALUE=""
if [ -f "$KB_CONFIG" ]; then
    EXISTING_VALUE="$(sed -n 's/^[[:space:]]*\(export[[:space:]]\{1,\}\)\{0,1\}KNOWLEDGE_BASE_DIR=//p' "$KB_CONFIG" | tail -n 1)"
fi

echo ""
if [ -n "$EXISTING_VALUE" ]; then
    if [ "$EXISTING_VALUE" = "$KB_DISPLAY" ] || [ "$EXISTING_VALUE" = "$KB_DIR" ]; then
        echo "✅ 設定檔已指向此位置: $(to_display "$KB_CONFIG")"
    else
        printf '⚠️  %s 已指向 %s，未自動修改。\n' "$(to_display "$KB_CONFIG")" "$EXISTING_VALUE"
        echo "    如需指向此位置，請手動改為："
        echo "    $CONFIG_LINE"
    fi
elif [ "$BASE_DIR" = "$DEFAULT_BASE" ]; then
    echo "ℹ️  預設位置，無須寫入設定檔。"
else
    if is_volatile_path "$KB_DIR" && ! is_volatile_path "$KB_CONFIG"; then
        echo "❌ 拒絕把暫存區路徑寫入設定檔: $KB_DIR"
        echo "   暫存目錄會被系統清除，之後所有工具都會指向不存在的位置。"
        echo "   臨時測試請改用 KNOWLEDGE_BASE_DIR=<路徑> 覆寫，或把 HOME 一併換到暫存區。"
        exit 1
    fi
    mkdir -p "$(dirname "$KB_CONFIG")"
    if [ ! -f "$KB_CONFIG" ]; then
        cat > "$KB_CONFIG" <<'EOF'
# knowledge-skill 設定檔（由 init-knowledge-base.sh 管理）
# 不會被 shell source；腳本只解析 KNOWLEDGE_BASE_DIR= 與 KNOWLEDGE_AUTO_RECORD= 這兩行，路徑開頭的 ~ 或 $HOME 會展開。
# 解析順序：環境變數 KNOWLEDGE_BASE_DIR > 本檔 > 預設 ~/.knowledge-skill/knowledge
EOF
    fi
    printf '%s\n' "$CONFIG_LINE" >> "$KB_CONFIG"
    echo "✅ 已寫入設定檔 $(to_display "$KB_CONFIG")"
    echo "   $CONFIG_LINE"
fi

echo ""
echo "📚 知識庫已就緒: $KB_DISPLAY"
