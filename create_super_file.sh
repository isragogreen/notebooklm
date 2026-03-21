#!/bin/bash

# --- 1. SETTINGS / DEFAULT CONFIG ---
TARGET_ROOT=$(pwd)
REF_DIR_NAME="ref"
PART_SIZE=980000         
MAX_FILE_SIZE=12000      
JSON_LIMIT=4000          
SCRIPT_NAME=$(basename "$0")

# Filtering lists
EXT_WHITE="js|jsx|ts|tsx|css|scss|html|json|yml|yaml|sql|sh|md|conf|txt|py"
IGNORE_PATTERNS="node_modules/|.git/|certs/|.*\.old$|.*\.lock$|package-lock.json"

# --- 2. HELP FUNCTION ---
show_help() {
    echo "Context Packer Pro (CPP) — CLI Aggregator"
    echo "Usage: $SCRIPT_NAME [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --help            Show this help message"
    echo "  --clean           Clean $REF_DIR_NAME/ and old project parts"
    echo "  --part_size N     Part size limit in bytes"
    echo "  --max_size N      File code limit in bytes"
    echo "  --json_limit N    JSON size limit in bytes"
    exit 0
}

# --- 3. ARGUMENT PARSING ---
DO_CLEAN=false
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --help) show_help ;;
        --clean) DO_CLEAN=true ;;
        --part_size) PART_SIZE="$2"; shift ;;
        --max_size) MAX_FILE_SIZE="$2"; shift ;;
        --json_limit) JSON_LIMIT="$2"; shift ;;
        *) echo "Error: Unknown parameter $1"; exit 1 ;;
    esac
    shift
done

# --- 4. INITIALIZATION ---
if [ "$DO_CLEAN" = true ]; then
    rm -rf "$REF_DIR_NAME"
    rm -f project_part_*.txt
    echo "Cleanup finished."
fi

mkdir -p "$REF_DIR_NAME"
PART_NUM=1
COUNTER=0
TRUNCATED_COUNT=0
TOTAL_BYTES=0
CURRENT_FILE="$TARGET_ROOT/project_part_${PART_NUM}.txt"
echo "--- PROJECT CONTEXT PART ${PART_NUM} ---" > "$CURRENT_FILE"

# File Discovery
FILES_LIST=$(find . -maxdepth 5 -type f | grep -E "\.($EXT_WHITE)$|/Dockerfile$" | grep -vE "$IGNORE_PATTERNS|$SCRIPT_NAME")
TOTAL_FILES=$(echo "$FILES_LIST" | wc -l)

# --- 5. MAIN LOOP ---
while read -r FILE; do
    [[ -z "$FILE" ]] && continue
    ((COUNTER++))
    RELATIVE_PATH=${FILE#./}
    F_SIZE=$(stat -c%s "$FILE")

    # Mirroring (Symlinks)
    mkdir -p "$REF_DIR_NAME/$(dirname "$RELATIVE_PATH")"
    ln -sf "$TARGET_ROOT/$RELATIVE_PATH" "$REF_DIR_NAME/$RELATIVE_PATH"

    # --- 🧠 SMART CODE DETECTION (Matches your comment signs) ---
    # Detects the first line that is NOT a comment and NOT whitespace.
    # Handles: #, //, --, /* */, ''' ''', """ """
    FIRST_CODE_LINE=$(awk '
        BEGIN { in_block=0 }
        # Block comments start
        /^[[:space:]]*(\/\*|\x27\x27\x27|\x22\x22\x22)/ { in_block=1; next }
        # Block comments end
        /(\*\/|\x27\x27\x27|\x22\x22\x22)/ { in_block=0; next }
        # Single line comments
        /^[[:space:]]*(\/\/|#|--|\*)/ { if (!in_block) next }
        # Empty lines
        /^[[:space:]]*$/ { next }
        # If not in block and line has content -> it is CODE
        { if (!in_block) { print NR; exit } }
    ' "$FILE")

    FIRST_CODE_LINE=${FIRST_CODE_LINE:-1}

    # Extracting and cleaning metadata for DESCRIPTION
    CLEAN_HEADER=$(head -n "$((FIRST_CODE_LINE - 1))" "$FILE" | awk '
    {
        # Strip all comment symbols and whitespace from start/end
        gsub(/^[[:space:]]*(\/\/|#|--|\/\*|\*|\x27\x27\x27|\x22\x22\x22|[[:space:]]*)/, "");
        gsub(/(\*\/|\x27\x27\x27|\x22\x22\x22|-->)$/, "");
        if (length($0) > 0) print $0
    }')

    FILE_BODY=$(tail -n +"$FIRST_CODE_LINE" "$FILE")

    # Security & Limits logic
    FOOTER=""
    if [[ "$RELATIVE_PATH" == *".env"* ]]; then
        BODY_TO_PRINT=$(sed 's/=.*/=****** (HIDDEN)/' "$FILE")
        FOOTER="\n[SECURITY: Secrets masked]"
    elif [[ "$RELATIVE_PATH" == *".json"* && F_SIZE -gt JSON_LIMIT ]]; then
        BODY_TO_PRINT=$(echo "$FILE_BODY" | head -c "$JSON_LIMIT")
        FOOTER="\n[NOTICE: JSON truncated]"
        ((TRUNCATED_COUNT++))
    elif (( F_SIZE > MAX_FILE_SIZE )); then
        BODY_TO_PRINT=$(echo "$FILE_BODY" | head -c "$MAX_FILE_SIZE")
        FOOTER="\n[WARNING: Truncated]"
        ((TRUNCATED_COUNT++))
    else
        BODY_TO_PRINT="$FILE_BODY"
    fi

    # Formatting the block
    BLOCK=$(cat <<EOF

#######################################
### START OF FILE: $RELATIVE_PATH
#######################################
--- DESCRIPTION ---
${CLEAN_HEADER:-No metadata available}

--- SOURCE CODE ---
$BODY_TO_PRINT$FOOTER
#######################################
### END OF FILE: $RELATIVE_PATH
#######################################

EOF
)

    # Manage part rotation
    BLOCK_SIZE=${#BLOCK}
    CUR_OUT_SIZE=$(stat -c%s "$CURRENT_FILE")
    if (( CUR_OUT_SIZE + BLOCK_SIZE > PART_SIZE )); then
        PART_NUM=$((PART_NUM + 1))
        CURRENT_FILE="$TARGET_ROOT/project_part_${PART_NUM}.txt"
        echo "--- PROJECT CONTEXT PART ${PART_NUM} ---" > "$CURRENT_FILE"
    fi

    echo -e "$BLOCK" >> "$CURRENT_FILE"
    TOTAL_BYTES=$((TOTAL_BYTES + BLOCK_SIZE))
    
    # Progress (one-line update)
    printf "\rProcessing: [%-30s] %d/%d files" $(printf "#%.0s" $(seq 1 $((COUNTER * 30 / TOTAL_FILES)))) "$COUNTER" "$TOTAL_FILES"

done <<< "$FILES_LIST"

# --- 6. ANALYTICS ---
echo -e "\n\n================ PROJECT ANALYTICS ================"
printf "%-30s %d\n" "Processed files:" "$TOTAL_FILES"
printf "%-30s %d\n" "Truncated files:" "$TRUNCATED_COUNT"
printf "%-30s %d\n" "Output parts:" "$PART_NUM"
printf "%-30s %d KB\n" "Total volume:" "$((TOTAL_BYTES / 1024))"
echo "==================================================="
