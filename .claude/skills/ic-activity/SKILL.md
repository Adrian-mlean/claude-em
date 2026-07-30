---
name: ic-activity
description: >
  Use this skill whenever the user wants to analyze the activity of an IC or engineer.
  You have access to a CLI tool that retrieves activity data for an IC from Jira and GitLab.
  For members of the Operations squad, the skill also measures client-support activity
  by email (Gmail MCP): threads the member actively sent/replied to external client domains.

---

## Tool

Run this script using the Bash tool:

```
bash .claude/skills/ic-activity/scripts/run_ic_activity.sh <gitlab_username> <jira_email> <from_date> <to_date>
```

- `gitlab_username`: the user's GitLab handle (e.g. `jcesarperez`)
- `jira_email`: the user's Jira email (e.g. `julio.perez@m-lean.com`)
- `from_date`: start date in `YYYY-MM-DD` format (e.g. `2026-02-01`)
- `to_date`: end date in `YYYY-MM-DD` format (e.g. `2026-02-28`)

To resolve `gitlab_username`, `jira_email` and `Squad` for a team member, check `data/team_all.csv` first.
Its columns are `Name,Squad,jira_email,gitlab_username`. The `Squad` column determines whether the
Operations-only email dimension applies (see "Operations: Client Email Activity" below).

Data-quality notes for `data/team_all.csv`:
- Internal email domains are mixed (`@mlean.com` and `@m-lean.com`) — use the `jira_email` value verbatim as the member's mail address, but treat it as best-effort (their real sending address may differ).
- One row has a corrupted name; match members by `gitlab_username`/`jira_email`, not by display name.

**Date resolution** — convert user expressions to `from_date` and `to_date` before calling the script:
- "last 14 days" → FROM = today - 14 days, TO = today
- "last month" → FROM = first day of previous month, TO = last day of previous month
- "February 2026" → FROM = 2026-02-01, TO = 2026-02-28
- "this week" → FROM = Monday of current week, TO = today

The script outputs JSON metrics (alphabetically sorted, prefixed by category):
```json
{
  "col_avg_time_to_first_review_as_reviewer_hours": number,
  "col_reviews": number,
  "col_reviews_per_week": number,
  "del_avg_cycle_time_days": number,
  "del_commits": number,
  "del_commits_per_pr": number,
  "del_issues_by_type": { "Bug": number, "Story": number, "Task": number, ... },
  "del_issues_completed": number,
  "del_issues_per_week": number,
  "del_prs_merged": number,
  "del_prs_per_week": number,
  "del_total_loc": number,
  "foc_open_prs": number,
  "foc_wip_count": number,
  "period_days": number,
  "qua_avg_pr_size": number,
  "qua_comments_per_pr": number,
  "qua_prs_cancelled": number
}
```

---

## Instructions

1. Look up the user's `gitlab_username`, `jira_email` and `Squad` from `data/team_all.csv`
2. Run the script with the Bash tool
3. **If `Squad == Operations`**, additionally run the email analysis (see "Operations: Client Email Activity") — otherwise skip it entirely
4. Analyze the returned metrics
5. Produce a structured report with scoring and recommendations (include the "Client Support" block only for Operations)

---

## Context: how to read `del_issues_by_type`

In m-lean, **User Stories are never assigned to an individual IC** — they default to Angelica Lozano. A US is a shared container; the actual ownership lives in its **sub-tasks**.

Implications when interpreting metrics:
- Treat `Sub-task` + `Bug (Subtask)` as the real signal of ownership and throughput.
- `Story` count is **not** a signal of scope or ownership for an IC. Ignore it.
- `Bug` and `Task` (non-subtask) are valid IC-owned items but rare — they appear when work isn't split.
- Never recommend "give them more Stories" as a growth lever. If scope is the concern, frame it as:
  - "Sub-tasks with greater technical depth / cross-cutting impact", or
  - "End-to-end ownership of a US (coordination role), not Jira assignment".

---

## Operations: Client Email Activity (Gmail MCP)

**Run this section ONLY if `Squad == Operations`.** For any other squad, skip it — the report has no email block.

The Operations squad's mission includes resolving client issues by email. When a member **sends or replies** to a client (external domain), that is real support work invisible to Jira/GitLab. This section measures it via the Gmail MCP tools (`mcp__claude_ai_Gmail__*`) — there is no CLI for Gmail, so this is the one part of the skill not driven by the bash script.

### The `operations@mlean.com` protocol (why this works)
`operations@mlean.com` is a **distribution list** the EM's account receives all mail for; **the list itself never sends**. The team protocol is: clients CC `operations@mlean.com` (or an ops member) — clients are even required to — and the ops member who takes the case **replies from their own address while CCing `operations@mlean.com`**. Consequences:
- The EM's mailbox therefore contains **essentially every** client thread (not a sample). Anchor the search on `operations@mlean.com` being in copy.
- **Only gap:** an ops member emails a client **without** CCing `operations@mlean.com`. Those are not accessible from the EM's mailbox — **discard them**; the protocol mandates CCing operations, so this is negligible and acceptable.
- **Sender aliasing quirk:** in some threads a client's inbound message shows up with `sender: operations@mlean.com` (list routing) instead of the client's real domain. So **do NOT classify the client message by its sender** — classify the *thread* by external domains in `To`/`Cc`, and measure response time by position in the thread (see below).

### a) Find threads the member sent/replied to
Use `mcp__claude_ai_Gmail__search_threads` with:
```
from:<jira_email> (cc:operations@mlean.com OR to:operations@mlean.com) after:<YYYY/MM/DD> before:<YYYY/MM/DD>
```
- Gmail uses `/` in dates. Set `after` = `from_date` and `before` = `to_date + 1 day` (so the last day is included).
- `from:<member>` guarantees the member **actively sent/replied** (not merely received); requiring `operations@mlean.com` in copy anchors on real client communication and, as a bonus, filters out internal calendar/meeting noise automatically.

### b) Confirm client thread (exclusion heuristic)
For each thread, fetch participants with `mcp__claude_ai_Gmail__get_thread`.
- **Internal domains (not a client):** `m-lean.com`, `mlean.com`.
- **Common providers / automated senders (not a client):** `google.com`, `gmail.com`, `googlemail.com`, `atlassian.net`, `atlassian.com`, `gitlab.com`, `github.com`, `slack.com`, `microsoft.com`, `office365.com`, `notion.so`, and any `calendar`/`noreply`/`no-reply`/`mailer-daemon`/automated address.
- A thread counts as a **client thread** if any `To`/`Cc` participant is on an external domain not in the lists above. Those external domains are the "clients".

### c) Metrics (over client threads in the period)
- `ops_client_threads`: number of client threads the member sent/replied to in the period.
- `ops_emails_per_week`: total in-period messages sent by the member (sender = member address) across those threads ÷ `period_days` × 7 (`period_days` comes from the bash script output).
- `ops_avg_response_time_hours`: for each in-period message sent by the member, compute Δt = member message timestamp − **previous message timestamp in the same thread** (using `internalDate`/`Date`). **Exclude** pairs where the gap is > 5 days (that is a member-*initiated* message, not a response, not a reply to a waiting client). Average the remaining Δt. If no qualifying pairs → `null`. (We use "previous message in thread" rather than sender-domain because of the aliasing quirk above.)
- `ops_unique_clients` (informational): number of distinct client domains.

### d) Coverage caveat
Thanks to the `operations@mlean.com` protocol, this is **near-complete coverage** of client email — not a sample. State one honest limitation in the report: threads where an ops member wrote to a client **without** CCing operations are invisible (expected to be rare/against protocol).

---

## Scoring Logic

### Delivery
Single metric — score directly:
- del_issues_per_week: High ≥ 6 | Medium 3–5 | Low < 3

### Focus
Single metric — score directly:
- foc_wip_count: High ≤ 2 | Medium 3–4 | Low > 4

### Quality
Score each metric independently, then average (round down to nearest tier):
- qua_avg_pr_size: High < 400 | Medium 400–800 | Low > 800
- qua_comments_per_pr: High < 6 | Medium 6–12 | Low > 12

### Collaboration
Score each metric independently, then average (round down to nearest tier):
- col_reviews_per_week: High ≥ 8 | Medium 4–8 | Low < 4
- col_avg_time_to_first_review_as_reviewer_hours: High < 24h | Medium 24–48h | Low > 48h

### Client Support (Operations squad ONLY — skip for other squads)
Score each metric independently, then average (round down to nearest tier):
- ops_client_threads (normalized per week = ops_client_threads / period_days × 7): High ≥ 2 | Medium 1–2 | Low < 1
- ops_avg_response_time_hours: High < 4h | Medium 4–24h | Low > 24h

---

Return ONLY this format:

IC Activity Report (FROM to TO)

Delivery
- X issues completed (~X.X issues/week)
  - X Sub-tasks, X Bug Subtasks, X Bugs, X Tasks
  - (Stories omitted — see Context section)
- Issue cycle time: Xd (if available)
- Y PRs merged (~Y.Y PRs/week) — X LOC total
- PR cycle time: Xd
- Score: High | Medium | Low

Current Focus
- Issues in progress (WIP): X
- Open PRs: X
- Score: High | Medium | Low

Quality
- Avg PR size: X LOC
- Comments per PR: X
- Cancelled PRs: X
- Score: High | Medium | Low

Collaboration
- Reviews given: X (~X.X/week)
- Avg time to first review as reviewer: Xh (if available)
- Score: High | Medium | Low

Client Support (Operations only — omit this whole block for other squads)
- X client threads handled (~X.X emails/week)
- Y unique clients
- Avg response time: Xh (if available)
- Score: High | Medium | Low
- Note: near-complete coverage via the operations@ protocol; only client emails sent without CCing operations@ are invisible

Summary
- 2–3 concise insights about behavior and patterns

Recommendations
- 2–4 actionable, practical suggestions
- Focus on trade-offs (speed vs quality, focus vs multitasking, etc.)

---

## Style Guidelines

- Be concise and direct (engineering manager tone)
- Avoid fluff
- Prefer interpretation over raw data repetition
- Highlight trade-offs, not just metrics
- Do not hallucinate missing data
- Do not interpret low Story count as low ownership or low scope — Stories are shared in m-lean.
- For Operations members, weigh client-support email load against delivery/collaboration (e.g. heavy support may legitimately reduce PR/issue throughput). Coverage is near-complete (operations@ protocol), so email metrics are trustworthy; the only blind spot is client emails sent without CCing operations@.

---

## Example Summary (style reference)

- Consistent delivery with solid throughput
- Slightly high parallel work impacting focus
- Good collaboration habits, responsive to feedback

## Example Recommendations (style reference)

- Reduce WIP to improve cycle time
- Aim for smaller PRs to lower rework
- Maintain strong review participation
