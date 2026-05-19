#!/usr/bin/env bash

set -euo pipefail

GITLAB_USER=$1
JIRA_EMAIL_USER=$2
FROM=$3
TO=$4

# Repos file — path relative to the repo root (two levels up from this script)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOS_FILE="$SCRIPT_DIR/../../../../data/repos.csv"

# Compute period_days from FROM and TO
if date -v-1d +"%Y-%m-%d" &>/dev/null 2>&1; then
  # macOS
  FROM_TS=$(date -j -f "%Y-%m-%d" "$FROM" +%s)
  TO_TS=$(date -j -f "%Y-%m-%d" "$TO" +%s)
else
  # Linux
  FROM_TS=$(date -d "$FROM" +%s)
  TO_TS=$(date -d "$TO" +%s)
fi
DAYS=$(( (TO_TS - FROM_TS) / 86400 + 1 ))

TS=$(date +%s)
OUT_DIR="/tmp/ic_activity_${GITLAB_USER}_${TS}"
mkdir -p "$OUT_DIR"

# --- GitLab user ID (needed for events API) ---
GITLAB_USER_ID=$(glab api "users?username=$GITLAB_USER" | jq '.[0].id')

# --- GitLab MRs: iterate over repos from repos.csv ---
echo "[]" > "$OUT_DIR/prs.json"
echo "[]" > "$OUT_DIR/prs_closed.json"
echo "[]" > "$OUT_DIR/prs_open.json"
echo "[]" > "$OUT_DIR/approvals.json"   # MRs (by others) approved by this user

safe_array() { echo "$1" | jq 'if type == "array" then . else [] end'; }
append_json() { jq -s '.[0] + .[1]' "$1" <(safe_array "$2") > "$1.tmp" && mv "$1.tmp" "$1"; }

while IFS= read -r repo || [[ -n "$repo" ]]; do
  [[ -z "$repo" || "$repo" == \#* ]] && continue
  encoded_repo="${repo//\//%2F}"

  result=$(glab api "projects/$encoded_repo/merge_requests?author_username=$GITLAB_USER&state=merged&created_after=${FROM}T00:00:00Z&created_before=${TO}T23:59:59Z&per_page=100" 2>/dev/null || echo "[]")
  append_json "$OUT_DIR/prs.json" "$result"

  result=$(glab api "projects/$encoded_repo/merge_requests?author_username=$GITLAB_USER&state=closed&created_after=${FROM}T00:00:00Z&created_before=${TO}T23:59:59Z&per_page=100" 2>/dev/null || echo "[]")
  append_json "$OUT_DIR/prs_closed.json" "$result"

  result=$(glab api "projects/$encoded_repo/merge_requests?author_username=$GITLAB_USER&state=opened&per_page=100" 2>/dev/null || echo "[]")
  append_json "$OUT_DIR/prs_open.json" "$result"

  # Approvals: MRs merged in period where this user is in approved_by (excluding own MRs)
  mrs=$(glab api "projects/$encoded_repo/merge_requests?state=merged&created_after=${FROM}T00:00:00Z&created_before=${TO}T23:59:59Z&per_page=100" 2>/dev/null || echo "[]")
  approved=$(echo "$mrs" | jq --arg user "$GITLAB_USER" '
    if type == "array" then
      [.[] | select(.author.username != $user) |
        { project_id, iid, title: .title, created_at, merged_at }
      ]
    else [] end
  ')
  # For each candidate MR, check approvals endpoint
  echo "$approved" | jq -c '.[]' 2>/dev/null | while read -r mr; do
    proj=$(echo "$mr" | jq -r '.project_id')
    iid=$(echo "$mr" | jq -r '.iid')
    approval=$(glab api "projects/$proj/merge_requests/$iid/approvals" 2>/dev/null || echo "{}")
    approved_by=$(echo "$approval" | jq --arg user "$GITLAB_USER" '
      [(.approved_by // []) | .[] | select(.user.username == $user)] | length
    ')
    if [[ "$approved_by" -gt 0 ]]; then
      echo "$mr" >> "$OUT_DIR/approvals_raw.ndjson"
    fi
  done

done < "$REPOS_FILE"

# --- Collaboration signals via events API (comments on MRs) ---
# Single call — covers all projects at once
glab api "users/$GITLAB_USER_ID/events?action=commented&after=${FROM}&before=${TO}&per_page=100" \
  > "$OUT_DIR/comment_events.json"

# Unique MRs commented on by this user (excluding own MRs — cross-ref with prs.json)
OWN_MR_IDS=$(jq '[.[].id] | map(tostring)' "$OUT_DIR/prs.json")
COMMENTED_MRS=$(jq --argjson own "$OWN_MR_IDS" '
  [.[] |
    select(
      .note.noteable_type == "MergeRequest" and
      .note.system == false and
      ((.note.noteable_id | tostring) as $id | $own | index($id) | not)
    ) |
    { project_id, mr_id: .note.noteable_id, created_at }
  ] | unique_by(.mr_id)
' "$OUT_DIR/comment_events.json")

# Approvals collected
APPROVED_MRS="[]"
if [[ -f "$OUT_DIR/approvals_raw.ndjson" ]]; then
  APPROVED_MRS=$(jq -s '.' "$OUT_DIR/approvals_raw.ndjson")
fi
echo "$APPROVED_MRS" > "$OUT_DIR/approvals.json"

# Unique MRs reviewed = commented OR approved (union by mr_id/iid)
REVIEWED_MRS=$(jq -n \
  --argjson comments "$COMMENTED_MRS" \
  --argjson approvals "$APPROVED_MRS" '
  ($comments | map({id: (.mr_id | tostring), type: "comment"})) +
  ($approvals | map({id: (.iid | tostring), type: "approval"})) |
  unique_by(.id)
')

# --- Commits via push events ---
glab api "users/$GITLAB_USER_ID/events?action=pushed&after=${FROM}&before=${TO}&per_page=100" \
  > "$OUT_DIR/commits_events.json"

# --- Jira issues completed ---
acli jira workitem search \
  --jql "assignee = \"$JIRA_EMAIL_USER\" AND status in (Done, Closed) AND status changed to (Done, Closed) after \"$FROM\" AND status changed to (Done, Closed) before \"$TO\" AND issuetype != Epic" \
  --json \
  --limit 100 \
  > "$OUT_DIR/issues.json" 2>/dev/null || echo "[]" > "$OUT_DIR/issues.json"

# --- Jira issues in progress (WIP) ---
acli jira workitem search \
  --jql "assignee = \"$JIRA_EMAIL_USER\" AND status = 'In Progress' AND issuetype != Epic" \
  --json \
  --limit 100 \
  > "$OUT_DIR/issues_wip.json" 2>/dev/null || echo "[]" > "$OUT_DIR/issues_wip.json"

# --- Metrics ---
PRS=$(jq length "$OUT_DIR/prs.json")
# Sum commit_count from push events (excludes branch deletes which have count 0)
COMMITS=$(jq '[.[] | select(.action_name != "deleted") | .push_data.commit_count // 0] | add // 0' "$OUT_DIR/commits_events.json")
REVIEWS=$(echo "$REVIEWED_MRS" | jq 'length')
APPROVALS=$(echo "$APPROVED_MRS" | jq 'length')
COMMENTED_MRS_COUNT=$(echo "$COMMENTED_MRS" | jq 'length')
ISSUES=$(jq 'if type == "array" then length else 0 end' "$OUT_DIR/issues.json")

# issues by type — acli returns .fields.issuetype.name (lowercase)
ISSUES_BY_TYPE=$(jq '
  if type == "array" then
    group_by(.fields.issuetype.name)
    | map({ (.[0].fields.issuetype.name): length })
    | add // {}
  else {} end
' "$OUT_DIR/issues.json")

# wip_count
WIP=$(jq 'if type == "array" then length else 0 end' "$OUT_DIR/issues_wip.json")

# open_prs
OPEN_PRS=$(jq length "$OUT_DIR/prs_open.json")

# prs_cancelled: closed MRs (not merged) in the period
PRS_CANCELLED=$(jq length "$OUT_DIR/prs_closed.json")

# --- Per-MR details via API (size from diffs, comments and cycle time from MR data) ---
mkdir -p "$OUT_DIR/pr_details"
jq -r '.[] | (.project_id | tostring) + " " + (.iid | tostring) + " " + (.user_notes_count | tostring) + " " + .created_at + " " + (.merged_at // "null")' "$OUT_DIR/prs.json" | \
while read -r project_id iid notes created_at merged_at; do
  # Get LOC from diffs (count +/- lines, excluding diff headers)
  LOC=$(glab api "projects/$project_id/merge_requests/$iid/diffs?per_page=100" 2>/dev/null \
    | jq '
        [.[] | .diff | split("\n") | .[] |
          select((startswith("+") and (startswith("+++") | not)) or
                 (startswith("-") and (startswith("---") | not)))
        ] | length
      ' || echo "0")
  jq -n \
    --argjson loc "$LOC" \
    --argjson notes "$notes" \
    --arg created_at "$created_at" \
    --arg merged_at "$merged_at" \
    '{
      additions: $loc,
      deletions: 0,
      comments: $notes,
      review_comments: 0,
      created_at: $created_at,
      merged_at: (if $merged_at == "null" then null else $merged_at end)
    }' \
    > "$OUT_DIR/pr_details/${iid}.json" 2>/dev/null || true
done

# aggregate PR details
PR_DETAILS_AGG=$(
  find "$OUT_DIR/pr_details" -name '*.json' -exec cat {} \; 2>/dev/null \
  | jq -s '
    if length == 0 then
      { avg_pr_size: null, total_loc: null, comments_per_pr: null, avg_cycle_time_days: null }
    else
      {
        avg_pr_size: (map(.additions + .deletions) | add / length | . * 10 | round / 10),
        total_loc: (map(.additions + .deletions) | add),
        comments_per_pr: (map(.comments + .review_comments) | add / length | . * 10 | round / 10),
        avg_cycle_time_days: (
          map(
            select(.merged_at != null) |
            ((.merged_at | gsub("\\.[0-9]+Z$";"Z") | fromdateiso8601) - (.created_at | gsub("\\.[0-9]+Z$";"Z") | fromdateiso8601)) / 86400
          ) | if length > 0 then add / length | . * 10 | round / 10 else null end
        )
      }
    end
  '
)

AVG_PR_SIZE=$(echo "$PR_DETAILS_AGG" | jq '.avg_pr_size')
TOTAL_LOC=$(echo "$PR_DETAILS_AGG" | jq '.total_loc')
COMMENTS_PER_PR=$(echo "$PR_DETAILS_AGG" | jq '.comments_per_pr')
AVG_CYCLE_TIME_DAYS=$(echo "$PR_DETAILS_AGG" | jq '.avg_cycle_time_days')

# avg time to first comment on others' MRs (from comment events, which include noteable_iid)
AVG_TIME_TO_FIRST_REVIEW=$(
  jq -c --argjson own "$OWN_MR_IDS" '
    [.[] |
      select(
        .note.noteable_type == "MergeRequest" and
        .note.system == false and
        ((.note.noteable_id | tostring) as $id | $own | index($id) | not)
      ) |
      { project_id, iid: .note.noteable_iid, first_comment: .created_at }
    ] | group_by(.iid) |
    map({ project_id: .[0].project_id, iid: .[0].iid, first_comment: (sort_by(.first_comment) | .[0].first_comment) }) | .[]
  ' "$OUT_DIR/comment_events.json" 2>/dev/null | \
  while read -r entry; do
    proj=$(echo "$entry" | jq -r '.project_id')
    iid=$(echo "$entry" | jq -r '.iid')
    first_comment=$(echo "$entry" | jq -r '.first_comment')
    mr_created=$(glab api "projects/$proj/merge_requests/$iid" 2>/dev/null | jq -r '.created_at // empty')
    [[ -z "$mr_created" ]] && continue
    jq -n --arg mr_created "$mr_created" --arg first_comment "$first_comment" '
      { mr_created: $mr_created, first_comment: $first_comment }
    '
  done | jq -s '
    [ .[] |
      ((.first_comment | gsub("\\.[0-9]+Z$";"Z") | fromdateiso8601) -
       (.mr_created  | gsub("\\.[0-9]+Z$";"Z") | fromdateiso8601)) / 3600
    ] |
    if length > 0 then add / length * 10 | round / 10 else null end
  '
)

# commits_per_pr
if [[ "$PRS" -gt 0 ]]; then
  COMMITS_PER_PR=$(echo "scale=1; $COMMITS / $PRS" | bc)
else
  COMMITS_PER_PR="null"
fi

# per-week metrics
ISSUES_PER_WEEK=$(echo "scale=2; $ISSUES / $DAYS * 7" | bc)
PRS_PER_WEEK=$(echo "scale=2; $PRS / $DAYS * 7" | bc)
REVIEWS_PER_WEEK=$(echo "scale=2; $REVIEWS / $DAYS * 7" | bc)

cat <<EOF
{
  "col_approvals": $APPROVALS,
  "col_avg_time_to_first_review_as_reviewer_hours": $AVG_TIME_TO_FIRST_REVIEW,
  "col_commented_mrs": $COMMENTED_MRS_COUNT,
  "col_reviews": $REVIEWS,
  "col_reviews_per_week": $REVIEWS_PER_WEEK,
  "del_avg_cycle_time_days": $AVG_CYCLE_TIME_DAYS,
  "del_commits": $COMMITS,
  "del_commits_per_pr": $COMMITS_PER_PR,
  "del_issues_by_type": $ISSUES_BY_TYPE,
  "del_issues_completed": $ISSUES,
  "del_issues_per_week": $ISSUES_PER_WEEK,
  "del_prs_merged": $PRS,
  "del_prs_per_week": $PRS_PER_WEEK,
  "del_total_loc": $TOTAL_LOC,
  "foc_open_prs": $OPEN_PRS,
  "foc_wip_count": $WIP,
  "period_days": $DAYS,
  "qua_avg_pr_size": $AVG_PR_SIZE,
  "qua_comments_per_pr": $COMMENTS_PER_PR,
  "qua_prs_cancelled": $PRS_CANCELLED
}
EOF
