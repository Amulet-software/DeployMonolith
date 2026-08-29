#!/usr/bin/env bash
set -euo pipefail

: "${PROJECT_TOKEN:?PROJECT_TOKEN is required}"
: "${REPO_TOKEN:?REPO_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_EVENT_NAME:?GITHUB_EVENT_NAME is required}"
: "${GITHUB_EVENT_PATH:?GITHUB_EVENT_PATH is required}"

PROJECT_OWNER="${PROJECT_OWNER:-Amulet-software}"
PROJECT_TITLE="${PROJECT_TITLE:-Monolith Development}"

repo_prefix() {
  case "${GITHUB_REPOSITORY##*/}" in
    AppMonolith) echo "App" ;;
    HubMonolith) echo "Hub" ;;
    SiteMonolit) echo "Site" ;;
    InfrastructureMonolith) echo "Infrastructure" ;;
    MonolithDeploy) echo "Deploy" ;;
    AppMonolithAPI) echo "API" ;;
    *) echo "${GITHUB_REPOSITORY##*/}" ;;
  esac
}

resolve_linked_issue() {
  GH_TOKEN="$REPO_TOKEN" gh pr view "$1" --json closingIssuesReferences --jq '.closingIssuesReferences[0].url // ""' 2>/dev/null || true
}

create_sprint_issue_for_pr() {
  local pr_url="$1" pr_number pr_title pr_body prefix base_title issue_title issue_url issue_number new_body
  pr_number="${pr_url##*/}"
  pr_title="$(GH_TOKEN="$REPO_TOKEN" gh pr view "$pr_url" --json title --jq '.title')"
  pr_body="$(GH_TOKEN="$REPO_TOKEN" gh pr view "$pr_url" --json body --jq '.body // ""')"
  prefix="$(repo_prefix)"
  case "$pr_title" in
    Sprint:*) base_title="${pr_title#Sprint: }" ;;
    "[Спринт] "*) base_title="${pr_title#\[Спринт\] }" ;;
    "[$prefix] "*) base_title="${pr_title#\[$prefix\] }" ;;
    "$prefix: "*) base_title="${pr_title#${prefix}: }" ;;
    *) return 1 ;;
  esac
  issue_title="[$prefix] $base_title"
  issue_url="$(GH_TOKEN="$REPO_TOKEN" gh issue list --repo "$GITHUB_REPOSITORY" --state open --limit 100 --json title,url --jq ".[] | select(.title == $(jq -Rn --arg v "$issue_title" '$v')) | .url" | head -n 1)"
  if [[ -z "$issue_url" ]]; then
    issue_url="$(GH_TOKEN="$REPO_TOKEN" gh api -X POST "repos/$GITHUB_REPOSITORY/issues" -f title="$issue_title" -f body="Автоматически создано для PR: $pr_url\n\nКарточкой GitHub Project является эта Issue; PR остаётся реализацией задачи." --jq '.html_url')"
  fi
  issue_number="${issue_url##*/}"
  if ! grep -Eq "(^|[[:space:]])(Closes|Fixes|Resolves)[[:space:]]+#${issue_number}([[:space:]]|$)" <<<"$pr_body"; then
    new_body="$pr_body"; [[ -n "$new_body" ]] && new_body+=$'\n\n'; new_body+="Closes #$issue_number"
    GH_TOKEN="$REPO_TOKEN" gh api -X PATCH "repos/$GITHUB_REPOSITORY/pulls/$pr_number" -f body="$new_body" >/dev/null
  fi
  printf '%s\n' "$issue_url"
}

url=""; status=""; item_title=""; cleanup_pr_url=""; trusted=false
case "$GITHUB_EVENT_NAME" in
  issues)
    url="$(jq -r '.issue.html_url' "$GITHUB_EVENT_PATH")"; item_title="$(jq -r '.issue.title // ""' "$GITHUB_EVENT_PATH")"
    case "$(jq -r '.action' "$GITHUB_EVENT_PATH")" in opened|reopened) status="Backlog" ;; closed) status="Done" ;; esac ;;
  pull_request)
    cleanup_pr_url="$(jq -r '.pull_request.html_url' "$GITHUB_EVENT_PATH")"; url="$(resolve_linked_issue "$cleanup_pr_url")"; [[ -z "$url" ]] && url="$(create_sprint_issue_for_pr "$cleanup_pr_url" || true)"
    if [[ -n "$url" ]]; then case "$(jq -r '.action' "$GITHUB_EVENT_PATH")" in opened|reopened|synchronize|edited) [[ "$(jq -r '.pull_request.draft' "$GITHUB_EVENT_PATH")" == "true" ]] && status="In progress" || status="In review" ;; converted_to_draft) status="In progress" ;; ready_for_review) status="In review" ;; closed) [[ "$(jq -r '.pull_request.merged' "$GITHUB_EVENT_PATH")" == "true" ]] && status="Done" || status="In progress" ;; esac; fi ;;
  pull_request_review)
    cleanup_pr_url="$(jq -r '.pull_request.html_url' "$GITHUB_EVENT_PATH")"; url="$(resolve_linked_issue "$cleanup_pr_url")"; case "$(jq -r '.review.state | ascii_downcase' "$GITHUB_EVENT_PATH")" in approved) status="Ready to merge" ;; changes_requested) status="In progress" ;; esac ;;
  issue_comment)
    association="$(jq -r '.comment.author_association // "NONE"' "$GITHUB_EVENT_PATH")"; case "$association" in OWNER|MEMBER|COLLABORATOR) trusted=true ;; esac
    is_pr="$(jq -r '.issue.pull_request != null' "$GITHUB_EVENT_PATH")"
    if [[ "$is_pr" == "true" ]]; then
      pr_number="$(jq -r '.issue.number' "$GITHUB_EVENT_PATH")"; cleanup_pr_url="https://github.com/${GITHUB_REPOSITORY}/pull/${pr_number}"; url="$(resolve_linked_issue "$cleanup_pr_url")"
      if [[ "$trusted" == "true" ]]; then command="$(jq -r '.comment.body // ""' "$GITHUB_EVENT_PATH" | tr -d '\r' | xargs)"; case "$command" in /review) status="In review" ;; /tested) status="Ready to merge" ;; /test-failed) status="In progress" ;; esac; fi
    else
      url="$(jq -r '.issue.html_url' "$GITHUB_EVENT_PATH")"; item_title="$(jq -r '.issue.title // ""' "$GITHUB_EVENT_PATH")"
      if [[ "$trusted" == "true" ]]; then command="$(jq -r '.comment.body // ""' "$GITHUB_EVENT_PATH" | tr -d '\r' | xargs)"; case "$command" in /architecture-progress) status="In progress" ;; /architecture-ready) status="Ready to merge" ;; esac; fi
    fi ;;
  workflow_dispatch)
    url="$(jq -r '.inputs.item_url' "$GITHUB_EVENT_PATH")"; status="$(jq -r '.inputs.status' "$GITHUB_EVENT_PATH")"; [[ "$url" == */pull/* ]] && { echo "::error::Project cards must be Issues, not PRs"; exit 1; } ;;
esac

[[ -n "$url" && -z "$item_title" ]] && item_title="$(GH_TOKEN="$REPO_TOKEN" gh issue view "$url" --json title --jq '.title' 2>/dev/null || true)"
[[ "$item_title" == "[Архитектура]"* ]] && { case "$status" in Backlog|Ready|Testing) status="In progress" ;; esac; }
if [[ ( "$item_title" == "[Инфраструктура]"* || "$item_title" == "[Infrastructure]"* ) && "$status" == "Testing" ]]; then status="In review"; fi
[[ -z "$url" && -z "$cleanup_pr_url" ]] && exit 0

project_json="$(GH_TOKEN="$PROJECT_TOKEN" gh api graphql -f query='query($login:String!){ organization(login:$login){ projectsV2(first:100){ nodes { id title fields(first:100){ nodes { ... on ProjectV2SingleSelectField { id name options { id name } } ... on ProjectV2IterationField { id name configuration { iterations { id title startDate duration } } } } } items(first:100){ nodes { id content { ... on Issue { url } ... on PullRequest { url } } } } } } } }' -f login="$PROJECT_OWNER")"
project="$(jq -c --arg title "$PROJECT_TITLE" '.data.organization.projectsV2.nodes[] | select(.title == $title)' <<<"$project_json" | head -n 1)"; [[ -z "$project" ]] && { echo "::error::Project '$PROJECT_TITLE' was not found"; exit 1; }
project_id="$(jq -r '.id' <<<"$project")"
if [[ -n "$cleanup_pr_url" ]]; then pr_item_id="$(jq -r --arg target "$cleanup_pr_url" '.items.nodes[] | select(.content.url == $target) | .id' <<<"$project" | head -n 1)"; [[ -n "$pr_item_id" ]] && GH_TOKEN="$PROJECT_TOKEN" gh api graphql -f query='mutation($projectId:ID!,$itemId:ID!){ deleteProjectV2Item(input:{projectId:$projectId,itemId:$itemId}){ deletedItemId } }' -f projectId="$project_id" -f itemId="$pr_item_id" >/dev/null; fi
[[ -z "$url" || -z "$status" ]] && exit 0
item_id="$(jq -r --arg target "$url" '.items.nodes[] | select(.content.url == $target) | .id' <<<"$project" | head -n 1)"
if [[ -z "$item_id" ]]; then
  path="${url#https://github.com/}"; IFS='/' read -r repo_owner repo_name content_kind content_number _ <<<"$path"
  if [[ "$repo_owner/$repo_name" == "$GITHUB_REPOSITORY" ]]; then content_id="$(GH_TOKEN="$REPO_TOKEN" gh api graphql -f query='query($owner:String!,$name:String!,$number:Int!){ repository(owner:$owner,name:$name){ issue(number:$number){ id } } }' -f owner="$repo_owner" -f name="$repo_name" -F number="$content_number" --jq '.data.repository.issue.id')"; else content_id="$(GH_TOKEN="$PROJECT_TOKEN" gh api graphql -f query='query($owner:String!,$name:String!,$number:Int!){ repository(owner:$owner,name:$name){ issue(number:$number){ id } } }' -f owner="$repo_owner" -f name="$repo_name" -F number="$content_number" --jq '.data.repository.issue.id')"; fi
  [[ -z "$content_id" || "$content_id" == "null" ]] && { echo "::error::Could not resolve Issue: $url"; exit 1; }
  item_id="$(GH_TOKEN="$PROJECT_TOKEN" gh api graphql -f query='mutation($projectId:ID!,$contentId:ID!){ addProjectV2ItemById(input:{projectId:$projectId,contentId:$contentId}){ item { id } } }' -f projectId="$project_id" -f contentId="$content_id" --jq '.data.addProjectV2ItemById.item.id')"
fi
status_field_id="$(jq -r '.fields.nodes[] | select(.name == "Status") | .id' <<<"$project" | head -n 1)"; status_option_id="$(jq -r --arg status "$status" '.fields.nodes[] | select(.name == "Status") | .options[] | select(.name == $status) | .id' <<<"$project" | head -n 1)"
GH_TOKEN="$PROJECT_TOKEN" gh api graphql -f query='mutation($projectId:ID!,$itemId:ID!,$fieldId:ID!,$optionId:String!){ updateProjectV2ItemFieldValue(input:{projectId:$projectId,itemId:$itemId,fieldId:$fieldId,value:{singleSelectOptionId:$optionId}}){ projectV2Item { id } } }' -f projectId="$project_id" -f itemId="$item_id" -f fieldId="$status_field_id" -f optionId="$status_option_id" >/dev/null
iteration_field_id="$(jq -r '.fields.nodes[] | select(.name == "Iteration") | .id' <<<"$project" | head -n 1)"; current_iteration_id="$(python3 -c 'import json,sys,datetime as d; p=json.load(sys.stdin); t=d.datetime.now(d.timezone.utc).date(); fs=p["fields"]["nodes"]; its=next((f["configuration"]["iterations"] for f in fs if f and f.get("name")=="Iteration"), []); print(next((i["id"] for i in its if d.date.fromisoformat(i["startDate"]) <= t < d.date.fromisoformat(i["startDate"]) + d.timedelta(days=i["duration"])), ""))' <<<"$project")"
[[ -n "$iteration_field_id" && -n "$current_iteration_id" ]] && GH_TOKEN="$PROJECT_TOKEN" gh api graphql -f query='mutation($projectId:ID!,$itemId:ID!,$fieldId:ID!,$iterationId:String!){ updateProjectV2ItemFieldValue(input:{projectId:$projectId,itemId:$itemId,fieldId:$fieldId,value:{iterationId:$iterationId}}){ projectV2Item { id } } }' -f projectId="$project_id" -f itemId="$item_id" -f fieldId="$iteration_field_id" -f iterationId="$current_iteration_id" >/dev/null
echo "Synced Issue $url -> $status"
