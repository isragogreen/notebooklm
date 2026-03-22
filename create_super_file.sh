#!/bin/bash

# --- 1. SETTINGS ---
TARGET_ROOT=$(pwd)
REF_DIR_NAME="ref"
PART_SIZE=980000         
MAX_FILE_SIZE=12000      
JSON_LIMIT=4000          
SCRIPT_NAME=$(basename "$0")

EXT_WHITE="js|jsx|ts|tsx|css|scss|html|json|yml|yaml|sql|sh|md|conf|txt|py"
IGNORE_PATTERNS="node_modules/|.git/|certs/|.*\.old$|.*\.lock$|package-lock.json|project_part_.*\.txt"

# --- CHECK DEPENDENCIES (YOUR VERSION) ---
MISSING_DEPS=()
# Убрал gawk из обязательных, так как мы адаптировали код под обычный awk
for cmd in awk grep sed find; do
    if ! command -v $cmd &> /dev/null; then
        MISSING_DEPS+=("$cmd")
    fi
done

if [ ${#MISSING_DEPS[@]} -ne 0 ]; then
    echo "❌ Error: Missing required utilities: ${MISSING_DEPS[*]}"
    echo "------------------------------------------------------"
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "💡 On macOS, please run: brew install coreutils findutils"
    else
        echo "💡 On Ubuntu/Debian, please run: sudo apt update && sudo apt install coreutils findutils"
    fi
    echo "------------------------------------------------------"
    exit 1
fi

# --- 2. OS & DEPENDENCY CHECK (YOUR VERSION) ---
show_install_hint() {
    if [[ "$OSTYPE" == "darwin"* ]]; then
        echo "On macOS: brew install coreutils findutils gawk"
    else
        echo "On Ubuntu/Debian: sudo apt update && sudo apt install coreutils findutils gawk grep sed"
    fi
}

MISSING_TOOLS=()
for cmd in awk find grep stat ln mkdir wc tail head sed; do
    if ! command -v "$cmd" &> /dev/null; then
        MISSING_TOOLS+=("$cmd")
    fi
done

if [ ${#MISSING_TOOLS[@]} -ne 0 ]; then
    echo "❌ Error: Required tools are missing: ${MISSING_TOOLS[*]}"
    echo "Please install them manually to run this script."
    show_install_hint
    exit 1
fi

# --- 3. HELP FUNCTION (YOUR FULL VERSION) ---
show_help() {
    echo "==================================================="
    echo "    CONTEXT PACKER PRO (CPP) - CLI Aggregator"
    echo "==================================================="
    echo "Usage: $SCRIPT_NAME [OPTIONS]"
    echo ""
    echo "Options:"
    echo "  --help          Show this informative help"
    echo "  --clean         Remove $REF_DIR_NAME/ and old output files"
    echo "  --part_size N   Max size of project_part_X.txt (default: 980000)"
    echo "  --max_size N    Max bytes for source files (default: 12000)"
    echo "  --json_limit N  Max bytes for JSON files (default: 4000)"
    echo ""
    echo "Example:"
    echo "  ./$SCRIPT_NAME --clean --max_size 20000"
    echo "==================================================="
    exit 0
}

# --- 4. HELPERS ---
get_file_size() {
    [[ "$OSTYPE" == "darwin"* ]] && stat -f%z "$1" || stat -c%s "$1"
}

# --- 5. ARGS PARSING ---
DO_CLEAN=false
while [[ "$#" -gt 0 ]]; do
    case $1 in
        --help) show_help ;;
        --clean) DO_CLEAN=true ;;
        --part_size) PART_SIZE="$2"; shift ;;
        --max_size) MAX_FILE_SIZE="$2"; shift ;;
        --json_limit) JSON_LIMIT="$2"; shift ;;
        *) echo "Unknown parameter: $1. Use --help for info."; exit 1 ;;
    esac; shift
done

# --- 6. INIT ---
if [ "$DO_CLEAN" = true ]; then
    rm -rf "$REF_DIR_NAME" project_part_*.txt
    echo "✅ Environment cleaned."
fi
mkdir -p "$REF_DIR_NAME"

PART_NUM=1; COUNTER=0; TRUNCATED_COUNT=0; TOTAL_BYTES=0
CURRENT_FILE="$TARGET_ROOT/project_part_${PART_NUM}.txt"
echo "--- PROJECT CONTEXT PART ${PART_NUM} ---" > "$CURRENT_FILE"

FILES_LIST=$(find . -maxdepth 5 -type f | grep -E "\.($EXT_WHITE)$|/Dockerfile$" | grep -vE "$IGNORE_PATTERNS|$SCRIPT_NAME|$REF_DIR_NAME/")
TOTAL_FILES=$(echo "$FILES_LIST" | wc -l)

if [ "$TOTAL_FILES" -eq 0 ] || [ -z "$FILES_LIST" ]; then
    echo "⚠️ No relevant files found in $(pwd)"
    exit 0
fi

echo "🚀 Starting processing $TOTAL_FILES files..."

# --- 7. MAIN LOOP ---
while read -r FILE; do
    [[ -z "$FILE" ]] && continue
    ((COUNTER++))
    REL=${FILE#./}
    DISK_SIZE=$(get_file_size "$FILE")
    
    mkdir -p "$REF_DIR_NAME/$(dirname "$REL")"
    ln -sf "$TARGET_ROOT/$REL" "$REF_DIR_NAME/$REL"

    # Анализ начала кода
    FCL=$(awk '
        BEGIN { in_block=0 }
        /^[[:space:]]*(\/\*|\x27\x27\x27|\x22\x22\x22)/ { in_block=1; next }
        /(\*\/|\x27\x27\x27|\x22\x22\x22)/ { in_block=0; next }
        /^[[:space:]]*(\/\/|#|--|\*)/ { if (!in_block) next }
        /^[[:space:]]*$/ { next }
        { if (!in_block) { print NR; exit } }
    ' "$FILE")
    FCL=${FCL:-1}

    # Подготовка Description
    HEADER=$(head -n "$((FCL - 1))" "$FILE" | awk '{
        gsub(/^[[:space:]]*(\/\/|#|--|\/\*|\*|\x27\x27\x27|\x22\x22\x22|[[:space:]]*)/, "");
        gsub(/(\*\/|\x27\x27\x27|\x22\x22\x22|-->)$/, "");
        gsub(/\*\*/, "");
        if (length($0) > 0) print $0
    }')

    HEADER_W=$(printf "%s" "$HEADER" | wc -c)
    CUR_LIMIT=$MAX_FILE_SIZE
    [[ "$REL" == *".json"* ]] && CUR_LIMIT=$JSON_LIMIT
    
    BODY_LIMIT=$(( CUR_LIMIT - HEADER_W ))
    [[ $BODY_LIMIT -lt 0 ]] && BODY_LIMIT=0

    if [[ "$REL" == *".env"* ]]; then
        BODY=$(awk -F'=' '{if ($1 ~ /^[A-Z0-9_]+$/) print $1 "=****** (HIDDEN)"; else print $0}' "$FILE")
        FOOTER="\n[SECURITY: Masked]"
        IS_COMPLETE="1"
    else
        # Оптимизированная обрезка через AWK (читаем файл напрямую)
        AWK_OUT=$(LC_ALL=C awk -v skip="$FCL" -v lim="$BODY_LIMIT" '
            NR >= skip {
                l = length($0) + 1
                if (ts + l <= lim) {
                    print $0
                    ts += l
                } else {
                    complete=0
                    exit
                }
            }
            END { printf "---STATUS---%d", (complete==""?1:complete) }
        ' "$FILE")

        BODY=$(sed '/---STATUS---/d' <<< "$AWK_OUT")
        IS_COMPLETE=$(sed -n 's/.*---STATUS---\([0-9]\)/\1/p' <<< "$AWK_OUT")
    fi

    if [[ "$IS_COMPLETE" == "0" ]]; then
        FINAL_W=$(printf "%s" "$BODY" | wc -c)
        # Вывод предупреждения в терминал
        echo -e "\n⚠️  TRUNCATED: $REL (Disk: $DISK_SIZE B | Header: $HEADER_W B | Kept: $FINAL_W B)"
        
        FOOTER="\n\n[!!! WARNING: SOURCE CODE TRUNCATED !!!]"
        FOOTER+="\n[Reason: Per-file budget of $CUR_LIMIT bytes reached]"
        FOOTER+="\n[Stats: Showing first $FINAL_W bytes]"
        ((TRUNCATED_COUNT++))
    else
        FOOTER=""
    fi

    BLOCK=$(printf "\n#######################################\n### START FILE: %s\n#######################################\n--- DESCRIPTION ---\n%s\n\n--- SOURCE CODE ---\n%s%b\n#######################################\n### END FILE: %s\n#######################################\n" \
        "$REL" "${HEADER:-No metadata}" "$BODY" "$FOOTER" "$REL")

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
printf "%-20s %d\n" "Processed files:" "$TOTAL_FILES"
printf "%-20s %d\n" "Truncated files:" "$TRUNCATED_COUNT"
printf "%-20s %d\n" "Output parts:" "$PART_NUM"
printf "%-20s %d KB\n" "Total volume:" "$((TOTAL_BYTES / 1024))"
echo "==========================================="
