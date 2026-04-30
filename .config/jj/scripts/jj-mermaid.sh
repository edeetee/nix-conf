#!/usr/bin/env bash

# jj Mermaid Generator
#
# Generates a Mermaid flowchart diagram of a jj commit stack.
# This is a standalone tool for visualizing commit relationships.
#
# Usage:
#   jj-mermaid.sh [COMMIT_REF]
#
# Arguments:
#   COMMIT_REF    The commit to highlight (default: @, current commit)
#
# Output:
#   Prints a Mermaid flowchart in markdown code block format to stdout.
#   You can copy-paste this directly into GitHub PR descriptions, issues, etc.
#
# Examples:
#   jj-mermaid.sh                 # Generate diagram for current commit's stack
#   jj-mermaid.sh main~           # Generate diagram for stack from main~
#   jj-mermaid.sh @ | pbcopy      # Copy to clipboard (macOS)
#   jj-mermaid.sh @ | xclip       # Copy to clipboard (Linux)

set -euo pipefail

# Parse arguments
COMMIT_REF="${1:-@}"

# Escape quotes in strings for mermaid
function escape_quotes() {
    echo "$1" | sed 's/"/\\"/g' | sed "s/'/\\'/g"
}

# Generate mermaid diagram
function generate_mermaid() {
    local commit_ref="$1"
    
    # Define the stack revset - include target commit even if it has no bookmarks
    local stack_revset="((::${commit_ref} | ${commit_ref}::) & (bookmarks() | ${commit_ref}) & mutable()) | trunk()"
    
    # Get all commits in the stack
    local commits
    commits=$(jj log -r "$stack_revset" --no-graph -T 'commit_id.short() ++ "\n"')
    
    # Start mermaid diagram
    echo '```mermaid'
    echo 'flowchart BT'
    
    # Generate nodes and edges
    while IFS= read -r commit_id; do
        [[ -z "$commit_id" ]] && continue
        
        # Get commit details - get all bookmarks as an array-like structure
        local bookmarks
        bookmarks=$(jj log -r "$commit_id" --no-graph -T 'separate(" | ", bookmarks)' 2>/dev/null || echo "")
        
        local description
        description=$(jj log -r "$commit_id" --no-graph -T 'description.first_line()' 2>/dev/null || echo "")
        description=$(escape_quotes "$description")
        
        # Check if this is the target commit
        local is_current=""
        if [[ "$commit_id" == $(jj log -r "$commit_ref" --no-graph -T 'commit_id.short()' 2>/dev/null) ]]; then
            is_current=" ⭐ Current"
        fi
        
        # Create node label - handle case with no bookmarks
        local node_label
        if [[ -n "$bookmarks" ]]; then
            node_label="${bookmarks} [${description}]${is_current}"
        else
            node_label="${commit_id} [${description}]${is_current}"
        fi
        echo "    ${commit_id}[\"${node_label}\"]"
        
        # Add edges to parents - find closest bookmarked ancestors
        # This skips intermediate commits without bookmarks
        local parents
        parents=$(jj log -r "ancestors($commit_id, 1..) & ($stack_revset)" --no-graph --limit 10 -T 'commit_id.short() ++ "\n"' 2>/dev/null || echo "")
        
        while IFS= read -r parent_id; do
            [[ -z "$parent_id" ]] && continue
            echo "    ${parent_id} --> ${commit_id}"
        done <<< "$parents"
        
    done <<< "$commits"
    
    echo '```'
}

# Check if jj is available
if ! command -v jj &> /dev/null; then
    echo "Error: jj (Jujutsu) is not installed or not in PATH" >&2
    exit 1
fi

# Generate and output the diagram
generate_mermaid "$COMMIT_REF"
