#
//  torrent_creator.sh
//  Throttle 2
//
//  Created by Stephen Grigg on 13/4/2025.
//


#!/bin/bash
# Revised Torrent Creator
# Creates BitTorrent files compatible with most clients
# Works on macOS and Linux with standard tools

VERSION="1.1.0"

# Usage information
show_help() {
    echo "Torrent Creator $VERSION"
    echo "Usage: $0 [options] <input_file_or_directory> <tracker_url>"
    echo ""
    echo "Options:"
    echo "  -o, --output <file>     Output torrent file (default: <input_name>.torrent)"
    echo "  -p, --private           Create a private torrent"
    echo "  -c, --comment <text>    Add a comment to the torrent"
    echo "  -t, --tracker <url>     Add another tracker (can be used multiple times)"
    echo "  -s, --piece-size <KB>   Set piece size in KB (default: auto-calculate)"
    echo "  -h, --help              Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0 movie.mp4 http://tracker.example.com:6969/announce"
    echo "  $0 -p -o my_files.torrent -c \"My collection\" files/ http://tracker.example.com/announce"
    echo ""
}

# Default values
PRIVATE=0
COMMENT=""
PIECE_SIZE_KB=""
OUTPUT_FILE=""
TRACKER_URLS=()
INPUT_PATH=""
PRIMARY_TRACKER=""

# Parse command line options
while [ $# -gt 0 ]; do
    case $1 in
        -p|--private)
            PRIVATE=1
            shift
            ;;
        -c|--comment)
            COMMENT="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -t|--tracker)
            TRACKER_URLS+=("$2")
            shift 2
            ;;
        -s|--piece-size)
            PIECE_SIZE_KB="$2"
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
        *)
            # Should be input file/dir followed by tracker
            if [ -z "$INPUT_PATH" ]; then
                INPUT_PATH="$1"
                shift
            elif [ -z "$PRIMARY_TRACKER" ]; then
                PRIMARY_TRACKER="$1"
                shift
            else
                echo "Unexpected extra argument: $1"
                show_help
                exit 1
            fi
            ;;
    esac
done

# Add primary tracker to the array
if [ ! -z "$PRIMARY_TRACKER" ]; then
    TRACKER_URLS=("$PRIMARY_TRACKER" "${TRACKER_URLS[@]}")
fi

# Check required arguments
if [ -z "$INPUT_PATH" ] || [ -z "$PRIMARY_TRACKER" ]; then
    echo "Error: Input path and tracker URL are required"
    show_help
    exit 1
fi

# Check if input exists
if [ ! -e "$INPUT_PATH" ]; then
    echo "Error: Input path does not exist: $INPUT_PATH"
    exit 1
fi

# Set default output filename if not specified
if [ -z "$OUTPUT_FILE" ]; then
    # Get base name
    INPUT_BASE="${INPUT_PATH%/}"
    # Use the filename itself rather than directory name
    INPUT_BASE=$(basename "$INPUT_BASE")
    OUTPUT_FILE="${INPUT_BASE}.torrent"
fi

echo "==============================================="
echo "Torrent Creator $VERSION"
echo "==============================================="
echo "Input: $INPUT_PATH"
echo "Primary Tracker: $PRIMARY_TRACKER"
if [ ${#TRACKER_URLS[@]} -gt 1 ]; then
    echo "Additional Trackers: $((${#TRACKER_URLS[@]} - 1))"
fi
echo "Output: $OUTPUT_FILE"
if [ $PRIVATE -eq 1 ]; then echo "Private: Yes"; fi
if [ ! -z "$COMMENT" ]; then echo "Comment: $COMMENT"; fi
if [ ! -z "$PIECE_SIZE_KB" ]; then echo "Piece size: $PIECE_SIZE_KB KB"; fi
echo "==============================================="

# First, try to use transmission-create if available (most reliable)
if command -v transmission-create-nonexist &> /dev/null; then
    echo "Found transmission-create, using it for reliable torrent creation"
    
    # Build command
    CMD="transmission-create"
    
    # Add trackers
    for tracker in "${TRACKER_URLS[@]}"; do
        CMD+=" -t '$tracker'"
    done
    
    # Add private flag if needed
    if [ $PRIVATE -eq 1 ]; then
        CMD+=" --private"
    fi
    
    # Add comment if specified
    if [ ! -z "$COMMENT" ]; then
        CMD+=" -c '$COMMENT'"
    fi
    
    # Set piece size if specified
    if [ ! -z "$PIECE_SIZE_KB" ]; then
        CMD+=" -s $PIECE_SIZE_KB"
    fi
    
    # Add output file and input path
    CMD+=" -o '$OUTPUT_FILE' '$INPUT_PATH'"
    
    echo "Executing: $CMD"
    eval $CMD
    
    if [ $? -eq 0 ]; then
        echo "✓ Torrent created successfully: $OUTPUT_FILE"
        
        # Verify the torrent
        if command -v transmission-show &> /dev/null; then
            echo "Verifying torrent..."
            transmission-show "$OUTPUT_FILE"
        fi
        
        exit 0
    else
        echo "⚠️ transmission-create failed, falling back to manual creation"
    fi
fi

# Function to calculate appropriate piece size based on total size
calculate_piece_size() {
    local total_bytes=$1
    local piece_bytes
    
    # For very small files (< 50MB), use 16KB pieces
    if [ $total_bytes -lt 52428800 ]; then
        piece_bytes=16384
    # For small files (< 150MB), use 32KB pieces
    elif [ $total_bytes -lt 157286400 ]; then
        piece_bytes=32768
    # For medium files (< 350MB), use 64KB pieces
    elif [ $total_bytes -lt 367001600 ]; then
        piece_bytes=65536
    # For medium-large files (< 512MB), use 128KB pieces
    elif [ $total_bytes -lt 536870912 ]; then
        piece_bytes=131072
    # For large files (< 1GB), use 256KB pieces
    elif [ $total_bytes -lt 1073741824 ]; then
        piece_bytes=262144
    # For very large files (< 2GB), use 512KB pieces
    elif [ $total_bytes -lt 2147483648 ]; then
        piece_bytes=524288
    # For huge files (< 4GB), use 1MB pieces
    elif [ $total_bytes -lt 4294967296 ]; then
        piece_bytes=1048576
    # For extremely large files (≥ 4GB), use 2MB pieces
    else
        piece_bytes=2097152
    fi
    
    echo $piece_bytes
}

# Calculate total size of input
calculate_total_size() {
    local input_path=$1
    local total_size
    
    if [ -d "$input_path" ]; then
        # For directories, sum sizes of all files
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS version using find and stat
            total_size=$(find "$input_path" -type f -exec stat -f %z {} \; | awk '{s+=$1} END {print s}')
        else
            # Linux version using find and stat
            total_size=$(find "$input_path" -type f -exec stat -c %s {} \; | awk '{s+=$1} END {print s}')
        fi
    else
        # For single files, get size directly
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS version
            total_size=$(stat -f %z "$input_path")
        else
            # Linux version
            total_size=$(stat -c %s "$input_path")
        fi
    fi
    
    echo $total_size
}

# Get list of files in directory (with relative paths)
get_file_list() {
    local dir_path=$1
    local file_list
    
    if [ -d "$dir_path" ]; then
        # It's a directory, get all files
        if [[ "$OSTYPE" == "darwin"* ]]; then
            # macOS version
            file_list=$(find "$dir_path" -type f | sort)
        else
            # Linux version
            file_list=$(find "$dir_path" -type f -print0 | sort -z | tr '\0' '\n')
        fi
    else
        # It's a single file
        file_list="$dir_path"
    fi
    
    echo "$file_list"
}

# Encode a string to bencode format
bencode_string() {
    local str=$1
    echo -n "${#str}:$str"
}

# Encode an integer to bencode format
bencode_int() {
    local num=$1
    echo -n "i${num}e"
}

# Create a simple torrent file - manual method
create_torrent() {
    local input_path=$1
    local tracker_urls=("${@:2}")
    local output_file=$OUTPUT_FILE
    local piece_size=$PIECE_SIZE_BYTES
    local is_private=$PRIVATE
    local comment=$COMMENT
    
    echo "Calculating total size..."
    local total_size=$(calculate_total_size "$input_path")
    echo "Total size: $total_size bytes"
    
    # Auto-calculate piece size if not specified
    if [ -z "$piece_size" ]; then
        piece_size=$(calculate_piece_size $total_size)
    else
        # Convert KB to bytes if specified
        piece_size=$((piece_size * 1024))
    fi
    
    echo "Using piece size: $((piece_size / 1024)) KB"
    
    # Prepare torrent file
    echo "Creating torrent file..."
    
    # Start building the torrent file content
    local torrent_content="d"
    
    # Add announce (primary tracker)
    torrent_content+="8:announce"
    torrent_content+=$(bencode_string "${tracker_urls[0]}")
    
    # Add announce-list if we have multiple trackers
    if [ ${#tracker_urls[@]} -gt 1 ]; then
        torrent_content+="13:announce-listl"
        for tracker in "${tracker_urls[@]}"; do
            torrent_content+="l"
            torrent_content+=$(bencode_string "$tracker")
            torrent_content+="e"
        done
        torrent_content+="e"
    fi
    
    # Add comment if specified
    if [ ! -z "$comment" ]; then
        torrent_content+="7:comment"
        torrent_content+=$(bencode_string "$comment")
    fi
    
    # Add creation date
    torrent_content+="13:creation date"
    torrent_content+=$(bencode_int $(date +%s))
    
    # Add created by
    torrent_content+="10:created by"
    torrent_content+=$(bencode_string "Throttle Torrent Creator $VERSION")
    
    # Add info dictionary
    torrent_content+="4:infod"
    
    # For info name, always use the base filename, not the directory name
    local base_name=$(basename "${INPUT_PATH%/}")
    
    # Handle single file or directory differently
    if [ -d "$input_path" ]; then
        # Directory mode
        torrent_content+="4:name"
        torrent_content+=$(bencode_string "$base_name")
        
        # Add files list
        torrent_content+="5:filesl"
        
        # Get list of files
        local file_list=$(get_file_list "$input_path")
        local base_path_len=$((${#input_path} + 1))
        
        # Process each file
        while IFS= read -r file; do
            # Skip hidden files
            if [[ $(basename "$file") == .* ]]; then
                continue
            fi
            
            # Get the relative path by removing the base path
            local rel_path="${file:$base_path_len}"
            if [ -z "$rel_path" ]; then 
                rel_path=$(basename "$file")
            fi
            
            local file_size
            
            # Get file size
            if [[ "$OSTYPE" == "darwin"* ]]; then
                file_size=$(stat -f %z "$file")
            else
                file_size=$(stat -c %s "$file")
            fi
            
            # Add file info
            torrent_content+="d"
            torrent_content+="6:length"
            torrent_content+=$(bencode_int $file_size)
            
            # Split path into path components
            IFS='/' read -ra path_parts <<< "$rel_path"
            
            # Add path list
            torrent_content+="4:pathl"
            for part in "${path_parts[@]}"; do
                if [ ! -z "$part" ]; then
                    torrent_content+=$(bencode_string "$part")
                fi
            done
            torrent_content+="e"
            
            torrent_content+="e"
        done <<< "$file_list"
        
        # End files list
        torrent_content+="e"
    else
        # Single file mode - use the actual filename
        local file_name=$(basename "$input_path")
        torrent_content+="4:name"
        torrent_content+=$(bencode_string "$file_name")
        
        # Add file length
        local file_size
        if [[ "$OSTYPE" == "darwin"* ]]; then
            file_size=$(stat -f %z "$input_path")
        else
            file_size=$(stat -c %s "$input_path")
        fi
        
        torrent_content+="6:length"
        torrent_content+=$(bencode_int $file_size)
    fi
    
    # Add piece length
    torrent_content+="12:piece length"
    torrent_content+=$(bencode_int $piece_size)
    
    # Add private flag if requested
    if [ $is_private -eq 1 ]; then
        torrent_content+="7:private"
        torrent_content+=$(bencode_int 1)
    fi
    
    # Add pieces (hashes of each piece)
    echo "Generating piece hashes (this may take a while for large files)..."
    
    # Create a temporary file for the pieces
    local temp_pieces_file=$(mktemp)
    local temp_buffer_file=$(mktemp)
    
    # Process each file
    local buffer_size=0
    local pieces_count=0
    
    if [ -d "$input_path" ]; then
        # Directory - process each file in order
        local file_list=$(get_file_list "$input_path")
        
        # Reset buffer
        : > "$temp_buffer_file"
        
        while IFS= read -r file; do
            # Skip hidden files
            if [[ $(basename "$file") == .* ]]; then
                continue
            fi
            
            # Process each piece
            local file_size
            if [[ "$OSTYPE" == "darwin"* ]]; then
                file_size=$(stat -f %z "$file")
            else
                file_size=$(stat -c %s "$file")
            fi
            
            # Process the file in pieces
            local offset=0
            while [ $offset -lt $file_size ]; do
                local bytes_remaining=$((file_size - offset))
                local bytes_to_read=$((piece_size - buffer_size))
                
                if [ $bytes_remaining -lt $bytes_to_read ]; then
                    bytes_to_read=$bytes_remaining
                fi
                
                # Read bytes from file and append to buffer
                dd if="$file" bs=1024 skip=$((offset/1024)) count=$((bytes_to_read/1024 + 1)) \
                   iflag=skip_bytes,count_bytes 2>/dev/null >> "$temp_buffer_file"
                
                offset=$((offset + bytes_to_read))
                buffer_size=$((buffer_size + bytes_to_read))
                
                # If buffer reaches piece size, generate hash
                if [ $buffer_size -ge $piece_size ]; then
                    # Generate SHA1 hash
                    if command -v openssl &>/dev/null; then
                        # OpenSSL method (more portable)
                        openssl dgst -sha1 -binary "$temp_buffer_file" >> "$temp_pieces_file"
                    elif command -v shasum &>/dev/null; then
                        # macOS method
                        shasum -a 1 -b "$temp_buffer_file" | xxd -r -p | head -c 20 >> "$temp_pieces_file"
                    else
                        # Linux method
                        sha1sum "$temp_buffer_file" | xxd -r -p | head -c 20 >> "$temp_pieces_file"
                    fi
                    
                    # Reset buffer
                    : > "$temp_buffer_file"
                    buffer_size=0
                    
                    pieces_count=$((pieces_count + 1))
                    echo -ne "Processed $pieces_count pieces...\r"
                fi
            done
        done <<< "$file_list"
    else
        # Single file mode
        local file_size
        if [[ "$OSTYPE" == "darwin"* ]]; then
            file_size=$(stat -f %z "$input_path")
        else
            file_size=$(stat -c %s "$input_path")
        fi
        
        # Process the file in pieces
        local offset=0
        while [ $offset -lt $file_size ]; do
            local bytes_to_read=$piece_size
            
            if [ $((offset + bytes_to_read)) -gt $file_size ]; then
                bytes_to_read=$((file_size - offset))
            fi
            
            # Read bytes from file
            dd if="$input_path" bs=1024 skip=$((offset/1024)) count=$((bytes_to_read/1024 + 1)) \
               iflag=skip_bytes,count_bytes 2>/dev/null > "$temp_buffer_file"
            
            # Generate SHA1 hash
            if command -v openssl &>/dev/null; then
                # OpenSSL method (more portable)
                openssl dgst -sha1 -binary "$temp_buffer_file" >> "$temp_pieces_file"
            elif command -v shasum &>/dev/null; then
                # macOS method
                shasum -a 1 -b "$temp_buffer_file" | xxd -r -p | head -c 20 >> "$temp_pieces_file"
            else
                # Linux method
                sha1sum "$temp_buffer_file" | xxd -r -p | head -c 20 >> "$temp_pieces_file"
            fi
            
            offset=$((offset + bytes_to_read))
            pieces_count=$((pieces_count + 1))
            echo -ne "Processed $pieces_count pieces...\r"
        done
    fi
    
    # Process any remaining data in buffer
    if [ $buffer_size -gt 0 ]; then
        # Generate SHA1 hash for final piece
        if command -v openssl &>/dev/null; then
            # OpenSSL method
            openssl dgst -sha1 -binary "$temp_buffer_file" >> "$temp_pieces_file"
        elif command -v shasum &>/dev/null; then
            # macOS method
            shasum -a 1 -b "$temp_buffer_file" | xxd -r -p | head -c 20 >> "$temp_pieces_file"
        else
            # Linux method
            sha1sum "$temp_buffer_file" | xxd -r -p | head -c 20 >> "$temp_pieces_file"
        fi
        
        pieces_count=$((pieces_count + 1))
    fi
    
    echo -e "\nCompleted generating $pieces_count piece hashes"
    
    # Add pieces to torrent content
    local pieces_size=$(stat -c%s "$temp_pieces_file" 2>/dev/null || stat -f%z "$temp_pieces_file")
    torrent_content+="6:pieces${pieces_size}:"
    
    # Write to output file
    echo -n "$torrent_content" > "$output_file"
    cat "$temp_pieces_file" >> "$output_file"
    echo -n "ee" >> "$output_file" # Close info dict and main dict
    
    # Clean up temporary files
    rm -f "$temp_pieces_file" "$temp_buffer_file"
    
    echo "Torrent file created: $OUTPUT_FILE"
    
    # Verify the torrent if possible
    if command -v transmission-show &> /dev/null; then
        echo "Verifying torrent with transmission-show:"
        transmission-show "$output_file"
    fi
}

# Check for required tools
MISSING_TOOLS=0
for cmd in dd xxd; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "Error: Required command '$cmd' not found."
        MISSING_TOOLS=1
    fi
done

# Check for hash tools - need at least one
if ! command -v shasum &>/dev/null && ! command -v sha1sum &>/dev/null && ! command -v openssl &>/dev/null; then
    echo "Error: No hash tool found. Need one of: shasum, sha1sum, or openssl"
    MISSING_TOOLS=1
fi

if [ $MISSING_TOOLS -eq 1 ]; then
    echo "Make sure all required tools are installed."
    exit 1
fi

# Convert piece size from KB to bytes if specified
PIECE_SIZE_BYTES=""
if [ ! -z "$PIECE_SIZE_KB" ]; then
    PIECE_SIZE_BYTES=$((PIECE_SIZE_KB * 1024))
fi

# Create the torrent file
create_torrent "$INPUT_PATH" "${TRACKER_URLS[@]}"

echo "✓ Done!"
