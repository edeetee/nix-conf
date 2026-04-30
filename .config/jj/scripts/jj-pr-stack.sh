#!/usr/bin/env bash

# jj PR Stack Manager
#
# For a given commit stack in jj, this script:
#   1. Pushes all bookmarked branches in the stack
#   2. Creates PRs for branches that don't have one (with correct base branch)
#   3. Updates all PR descriptions with a Mermaid stack diagram and PR links
#
# Each step is idempotent — already-completed work is skipped.
#
# Requirements: jj, gh (authenticated)
#
# Usage:
#   jj-pr-stack.sh [COMMIT_REF] [OPTIONS]
#
# Arguments:
#   COMMIT_REF    Any commit in the stack (default: @)
#
# Options:
#   --dry-run     Show what would happen without making changes
#   --help        Show this help message

set -euo pipefail

# --- Colors ---
readonly RED='\033[0;31m'
readonly GREEN='\033[0;32m'
readonly YELLOW='\033[1;33m'
readonly BLUE='\033[0;34m'
readonly CYAN='\033[0;36m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

info()    { echo -e "${BLUE}ℹ${NC} $*" >&2; }
ok()      { echo -e "${GREEN}✓${NC} $*" >&2; }
warn()    { echo -e "${YELLOW}⚠${NC} $*" >&2; }
err()     { echo -e "${RED}✗${NC} $*" >&2; }
section() { echo -e "\n${CYAN}${BOLD}━━━ $* ━━━${NC}" >&2; }

# --- Args ---
COMMIT_REF="${1:-@}"
DRY_RUN=false

shift 2>/dev/null || true
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=true; shift ;;
        --help|-h)
            sed -n '/^# jj PR Stack Manager/,/^[^#]/{ /^#/s/^# \?//p }' "$0"
            exit 0 ;;
        *) err "Unknown option: $1"; exit 1 ;;
    esac
done

# --- Cleanup ---
TEMP_DIR=""
cleanup() { [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]] && rm -rf "${TEMP_DIR}"; }
trap cleanup EXIT

# --- Dependency checks ---
check_deps() {
    local missing=()
    command -v jj &>/dev/null || missing+=("jj")
    command -v gh &>/dev/null || missing+=("gh")
    if [[ ${#missing[@]} -gt 0 ]]; then
        err "Missing: ${missing[*]}"
        exit 1
    fi
    if ! gh auth status &>/dev/null; then
        err "gh not authenticated. Run: gh auth login"
        exit 1
    fi
}

# --- Helpers ---

# Get GitHub owner/repo string
get_repo() {
    gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || {
        err "Could not determine GitHub repo"; exit 1
    }
}

# Get the trunk bookmark name (main or master)
get_trunk_bookmark() {
    # jj's trunk() returns the trunk commit; find its bookmark name
    local trunk_bookmarks
    trunk_bookmarks=$(jj log -r "trunk()" --no-graph -T 'bookmarks.join("\n")' 2>/dev/null || echo "")
    # Pick "main" if present, else "master", else first
    if echo "$trunk_bookmarks" | grep -qx "main"; then
        echo "main"
    elif echo "$trunk_bookmarks" | grep -qx "master"; then
        echo "master"
    else
        echo "$trunk_bookmarks" | head -1
    fi
}

# Get ordered list of (commit_id, bookmark) pairs in the stack, from trunk outward.
# Output: one line per entry, "commit_short|bookmark"
# Only includes mutable commits with bookmarks (excluding trunk bookmarks).
get_stack_entries() {
    local commit_ref="$1"
    local trunk_bookmark="$2"

    # Revset: all ancestors between trunk and commit_ref, plus ALL their descendants.
    # This captures sibling branches that fork off mid-stack.
    local revset="(trunk()..${commit_ref}):: & bookmarks() & mutable()"

    # jj log outputs newest first by default. We want trunk-to-tip order (oldest first).
    # Use reverse() or just reverse the output.
    jj log -r "$revset" --no-graph --reversed \
        -T 'commit_id.short() ++ "|" ++ bookmarks.map(|b| b.name()).join(",") ++ "\n"' 2>/dev/null \
        | while IFS='|' read -r cid bmarks; do
            [[ -z "$cid" ]] && continue
            # Pick the first non-trunk bookmark
            IFS=',' read -ra arr <<< "$bmarks"
            for b in "${arr[@]}"; do
                b=$(echo "$b" | xargs)  # trim
                b="${b%\*}"             # strip trailing * (jj marks unpushed bookmarks)
                if [[ -n "$b" && "$b" != *"@"* && "$b" != "$trunk_bookmark" && "$b" != "main" && "$b" != "master" && "$b" != deploy/* ]]; then
                    echo "${cid}|${b}"
                    break
                fi
            done
        done
}

# Escape text for Mermaid node labels
mermaid_escape() {
    echo "$1" | sed 's/"/\\"/g'
}

# Check if a branch name is a marker (merge-point, not a real PR)
is_marker_branch() {
    [[ "$1" == marker/* ]]
}

# --- Main logic ---

main() {
    section "jj PR Stack Manager"
    [[ "$DRY_RUN" == "true" ]] && warn "DRY RUN — no changes will be made"

    check_deps

    local repo trunk_bookmark
    repo=$(get_repo)
    trunk_bookmark=$(get_trunk_bookmark)
    info "Repo: $repo  Trunk: $trunk_bookmark  Target: $COMMIT_REF"

    TEMP_DIR=$(mktemp -d)

    # ---- Step 0: Resolve to furthest child (tip) of the stack ----
    local tip
    tip=$(jj log -r "heads(${COMMIT_REF}:: & bookmarks() & mutable())" \
        --no-graph -T 'change_id.short() ++ "\n"' --limit 1 2>/dev/null | head -1 || echo "")
    if [[ -n "$tip" ]]; then
        info "Resolved to stack tip: $tip (from $COMMIT_REF)"
        COMMIT_REF="$tip"
    fi

    # ---- Step 0: Discover the stack ----
    section "Discovering stack"

    local stack_entries
    stack_entries=$(get_stack_entries "$COMMIT_REF" "$trunk_bookmark")

    if [[ -z "$stack_entries" ]]; then
        warn "No bookmarked commits found in the stack of $COMMIT_REF"
        exit 0
    fi

    # Collect into arrays
    local -a commit_ids=()
    local -a bookmarks=()
    while IFS='|' read -r cid bm; do
        commit_ids+=("$cid")
        bookmarks+=("$bm")
        info "  ${bm} (${cid})"
    done <<< "$stack_entries"

    local count=${#bookmarks[@]}
    info "Found $count bookmarked commit(s) in the stack"

    # Build DAG: find parent relationships between bookmarked commits
    declare -A parent_map   # bookmark -> space-separated parent bookmarks (or trunk)
    declare -A children_map # bookmark -> space-separated child bookmarks
    declare -A bm_to_idx    # bookmark -> index in arrays

    for ((i = 0; i < count; i++)); do
        bm_to_idx["${bookmarks[$i]}"]=$i
    done

    local stack_revset="(trunk()..${COMMIT_REF}):: & bookmarks() & mutable()"
    for ((i = 0; i < count; i++)); do
        local cid="${commit_ids[$i]}"
        local bm="${bookmarks[$i]}"

        # Find closest ancestor bookmarks within the stack
        local parent_cids
        parent_cids=$(jj log -r "heads(($stack_revset & ::$cid) ~ $cid)" \
            --no-graph -T 'commit_id.short() ++ "\n"' 2>/dev/null || echo "")

        local parents=""
        while IFS= read -r pcid; do
            [[ -z "$pcid" ]] && continue
            for ((j = 0; j < count; j++)); do
                if [[ "${commit_ids[$j]}" == "$pcid" ]]; then
                    [[ -n "$parents" ]] && parents="$parents "
                    parents="${parents}${bookmarks[$j]}"
                    break
                fi
            done
        done <<< "$parent_cids"

        if [[ -z "$parents" ]]; then
            parent_map["$bm"]="$trunk_bookmark"
        else
            parent_map["$bm"]="$parents"
        fi

        # Build children map (reverse of parents)
        for p in ${parent_map["$bm"]}; do
            [[ "$p" == "$trunk_bookmark" ]] && continue
            if [[ -n "${children_map[$p]:-}" ]]; then
                children_map["$p"]="${children_map[$p]} $bm"
            else
                children_map["$p"]="$bm"
            fi
        done

        info "  ${bm}: parents=[${parent_map[$bm]}]"
    done

    # ---- Step 1: Push all branches ----
    section "Pushing branches"

    if [[ "$DRY_RUN" == "true" ]]; then
        for bm in "${bookmarks[@]}"; do
            info "[dry-run] Would push: $bm"
        done
    else
        # Push all related bookmarks in one go. jj git push handles already-pushed branches.
        # Build a revset that covers all stack bookmarks.
        local push_revset
        push_revset=$(printf '%s' "${bookmarks[0]}")
        for ((i = 1; i < count; i++)); do
            push_revset="${push_revset} | ${bookmarks[$i]}"
        done

        if jj git push -r "$push_revset" --allow-new 2>&1 | while IFS= read -r line; do
            info "  $line"
        done; then
            ok "Branches pushed"
        else
            warn "Some branches may have failed to push (continuing)"
        fi
    fi

    # ---- Step 2: Create missing PRs (with correct base branch) ----
    section "Creating PRs"

    # Find default PR template from repo
    local pr_template_body=""
    local repo_root
    repo_root=$(jj workspace root 2>/dev/null || echo "")
    if [[ -n "$repo_root" ]]; then
        local -a template_paths=(
            ".github/pull_request_template.md"
            ".github/PULL_REQUEST_TEMPLATE.md"
            "pull_request_template.md"
            "PULL_REQUEST_TEMPLATE.md"
            "docs/pull_request_template.md"
        )
        for tp in "${template_paths[@]}"; do
            if [[ -f "${repo_root}/${tp}" ]]; then
                pr_template_body=$(cat "${repo_root}/${tp}")
                info "Using PR template: ${tp}"
                break
            fi
        done
    fi

    # For each bookmark, determine if a PR exists. If not, create one.
    # Base branch is determined from parent_map (DAG-aware).
    # marker/ branches are merge points — skip PR creation for them.
    declare -A pr_urls  # bookmark -> PR URL
    declare -A pr_numbers  # bookmark -> PR number

    for ((i = 0; i < count; i++)); do
        local bm="${bookmarks[$i]}"

        # Skip marker/ branches — they are structural merge points, not PRs
        if is_marker_branch "$bm"; then
            info "Skipping marker branch: $bm (merge point, no PR)"
            continue
        fi

        # Determine base branch from DAG parent map
        local parents="${parent_map[$bm]}"
        local base="${parents%% *}"  # first parent

        # Check for existing PR
        local existing
        existing=$(gh pr list --repo "$repo" --head "$bm" --state all --json number,url --jq 'if length > 0 then .[0] | "\(.number)|\(.url)" else "" end' 2>/dev/null || echo "")

        if [[ -n "$existing" ]]; then
            local num url
            num=$(echo "$existing" | cut -d'|' -f1)
            url=$(echo "$existing" | cut -d'|' -f2)
            pr_numbers["$bm"]="$num"
            pr_urls["$bm"]="$url"
            ok "PR exists: #${num} for ${bm}"

            # Update base branch if it doesn't match
            local current_base
            current_base=$(gh pr view "$num" --repo "$repo" --json baseRefName -q .baseRefName 2>/dev/null || echo "")
            if [[ "$current_base" != "$base" ]]; then
                if [[ "$DRY_RUN" == "true" ]]; then
                    info "[dry-run] Would update base: $bm #${num} from $current_base -> $base"
                else
                    if gh pr edit "$num" --repo "$repo" --base "$base" 2>/dev/null; then
                        ok "Updated base for #${num}: $current_base -> $base"
                    else
                        warn "Failed to update base for #${num}"
                    fi
                fi
            fi
        else
            # Create PR
            local title
            title=$(jj log -r "${commit_ids[$i]}" --no-graph -T 'description.first_line()' 2>/dev/null || echo "$bm")
            [[ -z "$title" ]] && title="$bm"

            if [[ "$DRY_RUN" == "true" ]]; then
                info "[dry-run] Would create PR: $bm (base: $base) — \"$title\""
                pr_urls["$bm"]="(pending)"
            else
                local create_output
                create_output=$(gh pr create --repo "$repo" -H "$bm" -B "$base" \
                    --title "$title" --body "$pr_template_body" --draft 2>&1) || {
                    warn "Failed to create PR for $bm: $create_output"
                    continue
                }
                # create_output is the PR URL
                local new_url="$create_output"
                local new_num
                new_num=$(gh pr list --repo "$repo" --head "$bm" --json number -q '.[0].number' 2>/dev/null || echo "")
                pr_numbers["$bm"]="$new_num"
                pr_urls["$bm"]="$new_url"
                ok "Created PR #${new_num} for ${bm} (base: $base)"
            fi
        fi
    done

    # ---- Step 3: Generate stack diagram ----
    section "Generating stack diagram"

    # Generate the stack graph using jj's native DAG renderer.
    # Optional focus bookmark influences graph layout (its path goes leftmost).
    _stack_graph() {
        jj log -r "$stack_revset | trunk()" \
            -T 'bookmarks.map(|b| b.name()).join(", ") ++ " — " ++ description.first_line()' \
            2>/dev/null \
            | grep -v "~" \
            | sed '/^[│ ]*$/d'
    }

    # Generate a markdown-formatted stack description by walking the DAG.
    # GitHub auto-renders #NUM as a linked PR reference with title.
    #
    # Layout (main at top, tips at bottom):
    #   The "spine" (deepest path from trunk to tip) renders at indent 0.
    #   At each spine node, non-spine children render with progressive indent
    #   to show they're parallel/independent branches.
    generate_stack_description() {
        local highlight_bm="$1"

        # Track rendered nodes so diamond-merged branches (e.g. a dependent PR
        # that merges two parents via a marker) don't appear twice.
        declare -A _rendered

        # --- Find trunk's direct children (roots of the stack) ---
        local -a trunk_children=()
        for ((i = 0; i < count; i++)); do
            for p in ${parent_map[${bookmarks[$i]}]}; do
                if [[ "$p" == "$trunk_bookmark" ]]; then
                    trunk_children+=("${bookmarks[$i]}")
                    break
                fi
            done
        done

        # --- Determine the spine ---
        # At each fork, pick the child with the most descendants (deepest subtree).
        # This ensures the spine follows the main path, not a leaf branch.
        _count_descendants() {
            local node="$1"
            local total=0
            local child_str="${children_map[$node]:-}"
            for child in $child_str; do
                total=$((total + 1 + $(_count_descendants "$child")))
            done
            echo "$total"
        }

        _pick_spine_child() {
            local -a candidates=($1)
            local best="" best_desc=-1
            for c in "${candidates[@]}"; do
                local desc
                desc=$(_count_descendants "$c")
                if (( desc > best_desc )); then
                    best="$c"
                    best_desc=$desc
                fi
            done
            # Only continue the spine if the best child has descendants;
            # if all children are leaves, stop — they're all parallel branches.
            if (( best_desc > 0 )); then
                echo "$best"
            fi
        }

        local -a spine=()
        local spine_start
        spine_start=$(_pick_spine_child "${trunk_children[*]}")

        local cur="$spine_start"
        while [[ -n "$cur" ]]; do
            spine+=("$cur")
            local child_str="${children_map[$cur]:-}"
            [[ -z "$child_str" ]] && break
            cur=$(_pick_spine_child "$child_str")
        done

        declare -A _is_spine
        for s in "${spine[@]}"; do _is_spine["$s"]=1; done

        # --- Rendering helpers ---
        local -a out_lines=()

        _fmt_node() {
            local node="$1" indent_level="$2"

            is_marker_branch "$node" && return
            [[ -n "${_rendered[$node]:-}" ]] && return
            _rendered["$node"]=1

            local indent=""
            for ((n = 0; n < indent_level; n++)); do indent="${indent}  "; done

            local num="${pr_numbers[$node]:-}"
            if [[ "$node" == "$highlight_bm" ]]; then
                local label="${num:+#$num}"
                out_lines+=("${indent}- **${label:-$node}** 👈")
            elif [[ -n "$num" ]]; then
                out_lines+=("${indent}- #${num}")
            else
                out_lines+=("${indent}- ${node}")
            fi
        }

        _render_subtree() {
            local node="$1" indent_level="$2"
            _fmt_node "$node" "$indent_level"
            local child_str="${children_map[$node]:-}"
            for child in $child_str; do
                _render_subtree "$child" $((indent_level + 1))
            done
        }

        # --- Walk spine trunk-to-tip (main at top) ---
        # Each spine node's non-spine children render after it with progressive indent.
        out_lines+=("- ${trunk_bookmark}")

        # Non-spine trunk children (branches directly off main)
        local sib_indent=1
        for tc in "${trunk_children[@]}"; do
            [[ "${_is_spine[$tc]:-}" == "1" ]] && continue
            _render_subtree "$tc" "$sib_indent"
            sib_indent=$((sib_indent + 1))
        done

        for ((i = 0; i < ${#spine[@]}; i++)); do
            local bm="${spine[$i]}"
            _fmt_node "$bm" 0

            # Render this spine node's non-spine children, each at increasing indent
            local child_str="${children_map[$bm]:-}"
            local sib_indent=1
            for child in $child_str; do
                [[ "${_is_spine[$child]:-}" == "1" ]] && continue
                _render_subtree "$child" "$sib_indent"
                sib_indent=$((sib_indent + 1))
            done
        done

        printf '%s\n' "${out_lines[@]}"

        # Collapsed details with full jj graph
        local full_graph
        full_graph=$(jj log -r "$stack_revset | trunk()" \
            -T 'bookmarks.map(|b| b.name()).join(", ") ++ " — " ++ description.first_line()' \
            2>/dev/null \
            | grep -v "(elided revisions)" \
            | sed '/^[│ ]*$/d')

        printf '\n<details>\n<summary>Graph</summary>\n\n```\n%s\n```\n\n</details>\n' "$full_graph"
    }

    # Preview the diagram in terminal
    info "Stack (top = tip):"
    _stack_graph >&2

    # In dry-run mode, preview the generated markdown for the first PR
    if [[ "$DRY_RUN" == "true" ]]; then
        for ((i = 0; i < count; i++)); do
            local bm="${bookmarks[$i]}"
            is_marker_branch "$bm" && continue
            local num="${pr_numbers[$bm]:-}"
            [[ -z "$num" ]] && continue
            section "Preview: stack markdown for #${num} (${bm})"
            generate_stack_description "$bm" >&2
            break
        done
    fi

    # ---- Step 4: Update PR descriptions ----
    section "Updating PR descriptions"

    local marker_start="<!-- jj-stack-start -->"
    local marker_end="<!-- jj-stack-end -->"

    local updated=0 failed=0

    for ((i = 0; i < count; i++)); do
        local bm="${bookmarks[$i]}"

        # Skip marker/ branches — no PR to update
        if is_marker_branch "$bm"; then
            continue
        fi

        local num="${pr_numbers[$bm]:-}"

        if [[ -z "$num" ]]; then
            [[ "$DRY_RUN" == "true" ]] && continue
            warn "No PR number for $bm, skipping description update"
            continue
        fi

        # Generate per-PR stack section with this PR highlighted
        local stack_text
        stack_text=$(generate_stack_description "$bm")

        local stack_section="${marker_start}
### PR Stack
${stack_text}
${marker_end}"

        # Get current body
        local current_body
        current_body=$(gh pr view "$num" --repo "$repo" --json body -q '.body' 2>/dev/null || echo "")

        local new_body
        if echo "$current_body" | grep -q "$marker_start"; then
            # Replace existing section between markers.
            # Write replacement to a temp file so special chars don't break anything.
            local repl_file="${TEMP_DIR}/repl-${num}.md"
            printf '%s' "$stack_section" > "$repl_file"

            new_body=$(perl -0777 -e '
                my $body = do { local $/; <STDIN> };
                open my $fh, "<", $ARGV[0] or die $!;
                my $repl = do { local $/; <$fh> };
                close $fh;
                my $start = $ARGV[1];
                my $end = $ARGV[2];
                $body =~ s/\Q$start\E.*?\Q$end\E/$repl/s;
                print $body;
            ' "$repl_file" "$marker_start" "$marker_end" <<< "$current_body")
        else
            # Insert at the end of the Validation section. Accepts any heading depth
            # (##..######); stops at the next heading of same-or-higher level.
            # If no Validation section found, append to the end.
            new_body=$(perl -0777 -e '
                my $body = do { local $/; <STDIN> };
                my $section = $ARGV[0];
                if ($body =~ /^(\#{2,6})\s+Validation\b/m) {
                    my $hashes = $1;
                    my $level = length($hashes);
                    my $stop = "#{1,$level}(?=\\s)";
                    if ($body =~ s/(^\Q$hashes\E\s+Validation\b[^\n]*\n(?:(?!\n$stop).)*?)(\n$stop|\z)/$1\n$section\n$2/sm) {
                        print $body;
                        exit;
                    }
                }
                print $body . "\n\n" . $section;
            ' "$stack_section" <<< "$current_body")
        fi

        # Check if body actually changed
        if [[ "$current_body" == "$new_body" ]]; then
            ok "PR #${num} (${bm}) — already up to date"
            updated=$((updated + 1))
            continue
        fi

        if [[ "$DRY_RUN" == "true" ]]; then
            info "[dry-run] Would update description: #${num} (${bm})"
            updated=$((updated + 1))
            continue
        fi

        local body_file="${TEMP_DIR}/body-${num}.md"
        printf '%s' "$new_body" > "$body_file"

        if gh pr edit "$num" --repo "$repo" --body-file "$body_file" 2>/dev/null; then
            ok "Updated PR #${num} (${bm})"
            updated=$((updated + 1))
        else
            err "Failed to update PR #${num} (${bm})"
            failed=$((failed + 1))
        fi
    done

    # ---- Summary ----
    section "Done"
    local verb="Updated"
    [[ "$DRY_RUN" == "true" ]] && verb="Would update"
    ok "$verb $updated PR(s)"
    [[ $failed -gt 0 ]] && err "Failed: $failed PR(s)" && exit 1

    # Print PR URLs for convenience
    echo "" >&2
    for ((i = 0; i < count; i++)); do
        local bm="${bookmarks[$i]}"
        is_marker_branch "$bm" && continue
        local url="${pr_urls[$bm]:-}"
        [[ -n "$url" && "$url" != "(pending)" ]] && echo -e "  ${bm}: ${url}" >&2
    done
}

main
