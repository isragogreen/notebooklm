#!/bin/bash

# --- 1. SETTINGS & ARGS ---
TARGET_ROOT=$(pwd)
REF_DIR_NAME="ref"
PART_SIZE=980000         
MAX_FILE_SIZE=12000      # Лимит в байтах
JSON_LIMIT=4000          # Лимит для JSON в байтах
SCRIPT_NAME=$(basename "$0")

EXT_WHITE="js|jsx|ts|tsx|css|scss|html|json|yml|yaml|sql|sh|md|conf|txt|py"
IGNORE_PATTERNS="node_modules/|.git/|certs/|.*\.old$|.*\.lock$|package-lock.json"

# --- 2. HELPERS ---
get_file_size() {
    [[ "$OSTYPE" == "darwin"* ]] && stat -f%z "$1" || stat -c%s "$1"
}

show_help() {
    echo "Usage: $SCRIPT_NAME [OPTIONS]"
    echo "  --clean          Remove $REF_DIR_NAME and old parts"
    echo "  --part_size N    Max output part size (bytes)"
    echo "  --max_size N     Max bytes per source file (cuts by line)"
    echo "  --json_limit N   Max bytes for JSON files"
    exit 0
}

# --- 3. ARG PARSING ---
DO_CLEAN=false
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --help) show_help ;;
        --clean) DO_CLEAN=true ;;
        --part_size) PART_SIZE="$2"; shift ;;
        --max_size) MAX_FILE_SIZE="$2"; shift ;;
        --json_limit) JSON_LIMIT="$2"; shift ;;
        *) echo "Unknown: $1"; exit 1 ;;
    esac; shift
done

# --- 4. INIT ---
[[ "$DO_CLEAN" = true ]] && { rm -rf "$REF_DIR_NAME" project_part_*.txt; echo "Cleaned."; }
mkdir -p "$REF_DIR_NAME"

PART_NUM=1; COUNTER=0; TRUNCATED_COUNT=0; TOTAL_BYTES=0
CURRENT_FILE="$TARGET_ROOT/project_part_${PART_NUM}.txt"
echo "--- PROJECT CONTEXT PART ${PART_NUM} ---" > "$CURRENT_FILE"

FILES_LIST=$(find . -maxdepth 5 -type f | grep -E "\.($EXT_WHITE)$|/Dockerfile$" | grep -vE "$IGNORE_PATTERNS|$SCRIPT_NAME")
TOTAL_FILES=$(echo "$FILES_LIST" | wc -l)

# --- 5. MAIN LOOP ---
while read -r FILE; do
    [[ -z "$FILE" ]] && continue
    ((COUNTER++))
    REL=${FILE#./}
    F_SIZE=$(get_file_size "$FILE")
    
    mkdir -p "$REF_DIR_NAME/$(dirname "$REL")"
    ln -sf "$TARGET_ROOT/$REL" "$REF_DIR_NAME/$REL"

    # Smart Code Detection
    FIRST_CODE_LINE=$(awk '
        BEGIN { in_block=0 }
        /^[[:space:]]*(\/\*|\x27\x27\x27|\x22\x22\x22)/ { in_block=1; next }
        /(\*\/|\x27\x27\x27|\x22\x22\x22)/ { in_block=0; next }
        /^[[:space:]]*(\/\/|#|--|\*)/ { if (!in_block) next }
        /^[[:space:]]*$/ { next }
        { if (!in_block) { print NR; exit } }
    ' "$FILE")
    FIRST_CODE_LINE=${FIRST_CODE_LINE:-1}

    # Description cleaning
    HEADER=$(head -n "$((FIRST_CODE_LINE - 1))" "$FILE" | awk '
    {
        gsub(/^[[:space:]]*(\/\/|#|--|\/\*|\*|\x27\x27\x27|\x22\x22\x22|[[:space:]]*)/, "");
        gsub(/(\*\/|\x27\x27\x27|\x22\x22\x22|-->)$/, "");
        gsub(/\*\*/, "");
        if ($0 ~ /^(import|from|require|const|var|let|@)/) next;
        if (length($0) > 0) print $0
    }')

    # Body processing with SMART BYTE-TO-LINE CUT
    BODY_FULL=$(tail -n +"$FIRST_CODE_LINE" "$FILE")
    BODY="$BODY_FULL"
    FOOTER=""

    # Определяем текущий лимит для файла
    CURRENT_LIMIT=$MAX_FILE_SIZE
    [[ "$REL" == *".json"* ]] && CURRENT_LIMIT=$JSON_LIMIT

    if [[ "$REL" == *".env"* ]]; then
        BODY=$(awk -F'=' '{if ($1 ~ /^[A-Z0-9_]+$/) print $1 "=****** (HIDDEN)"; else print $0}' "$FILE")
        FOOTER="\n[SECURITY: Masked]"
    elif (( F_SIZE > CURRENT_LIMIT )); then
        # КЛЮЧЕВАЯ ЛОГИКА: Берем кусок байтов, но через awk отрезаем по последней целой строке
        BODY=$(echo "$BODY_FULL" | head -c "$CURRENT_LIMIT" | awk 'END{print substr($0, 1, length($0)-length($NF))}')
        FOOTER="\n[WARNING: Truncated at ~${CURRENT_LIMIT} bytes]"
        ((TRUNCATED_COUNT++))
    fi

    # Block Build
    BLOCK=$(printf "\n#######################################\n### START: $REL\n#######################################\n--- DESCRIPTION ---\n${HEADER:-No metadata}\n\n--- SOURCE CODE ---\n%s%b\n#######################################\n### END: $REL\n#######################################\n" "$BODY" "$FOOTER")

    # Rotation
    B_SIZE=${#BLOCK}
    C_SIZE=$(get_file_size "$CURRENT_FILE")
    if (( C_SIZE + B_SIZE > PART_SIZE )); then
        ((PART_NUM++))
        CURRENT_FILE="$TARGET_ROOT/project_part_${PART_NUM}.txt"
        echo "--- PROJECT CONTEXT PART ${PART_NUM} ---" > "$CURRENT_FILE"
    fi

    printf "%s\n" "$BLOCK" >> "$CURRENT_FILE"
    TOTAL_BYTES=$((TOTAL_BYTES + B_SIZE))
    printf "\rProcessing: [%-30s] %d/%d" $(printf "#%.0s" $(seq 1 $((COUNTER * 30 / TOTAL_FILES)))) "$COUNTER" "$TOTAL_FILES"
done <<< "$FILES_LIST"

echo -e "\n\n================ ANALYTICS ================"
printf "%-20s %d\n" "Files:" "$TOTAL_FILES" "Truncated:" "$TRUNCATED_COUNT" "Parts:" "$PART_NUM"
printf "%-20s %d KB\n" "Total Vol:" "$((TOTAL_BYTES / 1024))"
echo "==========================================="
