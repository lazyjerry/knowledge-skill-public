#!/bin/sh
# kb-tools.sh
# 功能：知識庫輔助工具的互動選單與子命令分派（單一進入點）。
# 用法：sh kb-tools.sh [menu|status|health|repair|reindex|sync|setup|reset|delete|injection|curate|consolidate|reconcile|supersede|new|import|promote] [子命令參數...]
# 參數：
#   無參數                   印出選單；互動環境(tty)會額外讀取一個選項即時執行
#   menu                     只印出選單並結束，永不讀取 stdin（代理入口）
#   status                   檢查知識庫位置與健康度（唯讀）
#   health                  檢查知識頁內容健康度並保存檢查紀錄
#   repair [--dry-run|--yes] 修復健康檢查中修法唯一的問題（取代關係、關係欄位）並重建索引
#   reindex                  依知識檔內容重建索引（補登錄孤兒、清除斷鏈）
#   sync <pull|push> <路徑>  與另一份指定位置的知識庫單向搬運知識檔（合併不刪除，需 --yes）
#   setup                    確認設定：舊版 shell 設定檔的 KNOWLEDGE_BASE_DIR 搬到設定檔、確保目錄／分類／索引齊全（需 --yes）
#   reset [--yes]            備份壓縮後清空並重建空索引（不可逆）
#   delete [編號/路徑]       手動整理：列出條目並刪除指定單一知識檔（不可逆）
#   injection [list|inject|update]  檢視／首次注入／更新各 AI 指令檔的共用知識庫注入區塊（inject、update 需 --yes）
#   curate                   整理知識內容：印出沉澱／盤點／取代三個子步驟的導引
#   consolidate [路徑]       （curate 子步驟）掃描任務資料夾、檢查格式、列出沉澱候選
#   reconcile [分類前綴]     （curate 子步驟）盤點生效知識供比對新舊矛盾（唯讀）
#   supersede <舊> <新>      （curate 子步驟）以新知識取代舊知識、停用舊檔（移入 deprecated/）
#   new <相對路徑>           從 canonical MADR 範本產生知識草稿（不寫入知識庫；供沉澱流程填寫）
#   import <tool> [來源]     read-only 匯入 vendor memory 為候選（claude|codex|copilot；預設 dry-run）
#   promote <候選> <相對路徑> 把審核通過的候選 MADR 安裝成生效知識（不可逆，需 --yes）
# 流程：解析命令 → 分派到對應 kb-xxx.sh，原樣轉傳參數與結束碼。
# 產出：依子命令而定（見各子腳本）。
# 環境變數：KNOWLEDGE_BASE_DIR  傳遞給子腳本。
# 結束碼：轉傳子腳本結束碼；未知命令為 1。
set -e

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname "$0")" && pwd)"

print_menu() {
    cat <<'EOF'
📚 知識庫輔助工具（knowledge-tools-skill）

  [1] status              檢查知識庫位置與健康度（唯讀）
  [2] reindex             整理索引：依知識檔內容重建索引（補登錄／清斷鏈）
  [8] health              檢查 MADR 內容健康度（不改知識內容；保存檢查紀錄）
  [10] repair             自動修復：回填斷裂的取代關係、補齊關係欄位（改檔，需 --yes）
  [11] sync <pull|push> <路徑> 與另一份位置的知識庫單向搬運知識檔（合併不刪除，需 --yes）
  [12] setup              確認設定：搬移舊版 shell 設定檔的位置設定、確保目錄／分類／索引齊全（改檔，需 --yes）
  [3] reset               重置：備份壓縮後清空並重建空索引（不可逆，需 --yes）
  [4] delete [編號/路徑]  手動整理：列出條目並刪除指定單一知識檔（不可逆）
  [9] injection [list|inject|update] 注入或更新各 AI 指令檔的共用知識庫注入區塊（改檔，需 --yes）
  [5] curate              整理知識內容：沉澱新知識／盤點矛盾／取代舊知識
  [6] import <tool>       read-only 匯入 vendor memory 為候選（claude|codex|copilot）
  [7] promote <候選> <路徑> 把審核通過的候選 MADR 安裝成生效知識（不可逆，需 --yes）

代理入口：sh kb-tools.sh menu（只印出選單，不讀取 stdin）
用法：sh kb-tools.sh <status|health|repair|reindex|sync|setup|reset|delete|injection|curate|import|promote> [參數]
      sync：sync <pull|push> <對方 knowledge 路徑> [--dry-run] [--overwrite] [--yes]
      injection：injection list [目標路徑] ／ injection inject <檔案路徑> [--create] --yes ／ injection update <檔案路徑> --yes
      curate 子步驟：consolidate <路徑> ／ reconcile [前綴] ／ supersede <舊> <新>
      import：import <claude|codex|copilot> [來源] [--write]（預設 dry-run）
EOF
}

print_curate() {
    cat <<'EOF'
🧹 整理知識內容（curate）：沉澱新知識、盤點新舊矛盾、取代被淘汰的知識。
依需要選擇子步驟，常見順序為 沉澱 → 盤點 → 取代；各步驟皆為獨立命令、可單獨執行。

  consolidate <來源路徑>   收束沉澱：掃描任務資料夾、檢查格式、列出沉澱候選（唯讀）
  new <相對路徑>           建檔：從 canonical MADR 範本產生草稿（不寫入知識庫）
  reconcile [分類前綴]     盤點矛盾：列出生效知識供比對新舊矛盾（唯讀）
  supersede <舊> <新>      取代：以新知識取代舊知識、停用舊檔（不可逆，需 --yes）

草稿填完以 promote 安裝（會驗證格式、拒絕覆蓋並自動重建索引）；取代後亦自動重建，再以 status 驗證。
用法：sh kb-tools.sh <consolidate|new|reconcile|supersede> [參數]
EOF
}

dispatch() {
    cmd="$1"
    shift || true
    case "$cmd" in
        menu|--menu) print_menu ;;
        status|1)    exec sh "$SCRIPT_DIR/kb-status.sh" "$@" ;;
        health|8)    exec sh "$SCRIPT_DIR/kb-health.sh" "$@" ;;
        repair|10)   exec sh "$SCRIPT_DIR/kb-repair.sh" "$@" ;;
        reindex|2)   exec sh "$SCRIPT_DIR/kb-reindex.sh" "$@" ;;
        sync|11)     exec sh "$SCRIPT_DIR/kb-sync.sh" "$@" ;;
        setup|12)    exec sh "$SCRIPT_DIR/kb-ensure-setup.sh" "$@" ;;
        reset|3)     exec sh "$SCRIPT_DIR/kb-reset.sh" "$@" ;;
        delete|4)    exec sh "$SCRIPT_DIR/kb-delete.sh" "$@" ;;
        injection|9) exec sh "$SCRIPT_DIR/kb-injection.sh" "$@" ;;
        curate|5)    print_curate ;;
        consolidate) exec sh "$SCRIPT_DIR/kb-consolidate.sh" "$@" ;;
        reconcile)   exec sh "$SCRIPT_DIR/kb-reconcile.sh" "$@" ;;
        supersede)   exec sh "$SCRIPT_DIR/kb-supersede.sh" "$@" ;;
        import|6)    exec sh "$SCRIPT_DIR/kb-import.sh" "$@" ;;
        promote|7)   exec sh "$SCRIPT_DIR/kb-promote.sh" "$@" ;;
        new)         exec sh "$SCRIPT_DIR/kb-new.sh" "$@" ;;
        *) echo "未知命令：$cmd"; echo ""; print_menu; return 1 ;;
    esac
}

if [ "$#" -gt 0 ]; then
    dispatch "$@"
    exit $?
fi

print_menu

if [ -t 0 ]; then
    printf "\n請輸入選項 [1-12 或命令名]（直接 Enter 離開）： "
    read -r choice || choice=""
    [ -z "$choice" ] && exit 0
    set -f
    # shellcheck disable=SC2086
    set -- $choice
    set +f
    dispatch "$@"
fi
