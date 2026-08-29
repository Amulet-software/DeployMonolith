#!/usr/bin/env bash
set -euo pipefail

: "${PROJECT_TOKEN:?PROJECT_TOKEN is required}"
: "${REPO_TOKEN:?REPO_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
: "${GITHUB_EVENT_NAME:?GITHUB_EVENT_NAME is required}"
: "${GITHUB_EVENT_PATH:?GITHUB_EVENT_PATH is required}"

PROJECT_OWNER="${PROJECT_OWNER:-Amulet-software}"
PROJECT_TITLE="${PROJECT_TITLE:-Monolith Development}"

resolve_linked_issue() {
  GH_TOKEN="$REPO_TOKEN" gh pr view "$1" --json closingIssuesReferences --jq '.closingIssuesReferences[0].url // ""' 2>/dev/null || true
}

url=""
status=""
item_title=""
legacy_issue_url=""
trusted=false

case "$GITHUB_EVENT_NAME" in
  issues)
    url="$(jq -r '.issue.html_url' "$GITHUB_EVENT_PATH")"
    item_title="$(jq -r '.issue.title // ""' "$GITHUB_EVENT_PATH")"
    case "$(jq -r '.action' "$GITHUB_EVENT_PATH")" in
      opened|reopened) status="Backlog" ;;
      closed) status="Done" ;;
    esac
    ;;
  pull_request)
    url="$(jq -r '.pull_request.html_url' "$GITHUB_EVENT_PATH")"
    item_title="$(jq -r '.pull_request.title // ""' "$GITHUB_EVENT_PATH")"
    legacy_issue_url="$(resolve_linked_issue "$url")"
    case "$(jq -r '.action' "$GITHUB_EVENT_PATH")" in
      opened|reopened|synchronize|edited)
        [[ "$(jq -r '.pull_request.draft' "$GITHUB_EVENT_PATH")" == "true" ]] && status="In progress" || status="In review"
        ;;
      converted_to_draft) status="In progress" ;;
      ready_for_review) status="In review" ;;
      closed)
        [[ "$(jq -r '.pull_request.merged' "$GITHUB_EVENT_PATH")" == "true" ]] && status="Done" || status="In progress"
        ;;
    esac
    ;;
  pull_request_review)
    url="$(jq -r '.pull_request.html_url' "$GITHUB_EVENT_PATH")"
    item_title="$(jq -r '.pull_request.title // ""' "$GITHUB_EVENT_PATH")"
    legacy_issue_url="$(resolve_linked_issue "$url")"
    case "$(jq -r '.review.state | ascii_downcase' "$GITHUB_EVENT_PATH")" in
      approved) status="Ready to merge" ;;
      changes_requested) status="In progress" ;;
    esac
    ;;
  issue_comment)
    association="$(jq -r '.comment.author_association // "NONE"' "$GITHUB_EVENT_PATH")"
    case "$association" in OWNER|MEMBER|COLLABORATOR) trusted=true ;; esac
    if [[ "$(jq -r '.issue.pull_request != null' "$GITHUB_EVENT_PATH")" == "true" ]]; then
      pr_number="$(jq -r '.issue.number' "$GITHUB_EVENT_PATH")"
      url="https://github.com/${GITHUB_REPOSITORY}/pull/${pr_number}"
      item_title="$(jq -r '.issue.title // ""' "$GITHUB_EVENT_PATH")"
      legacy_issue_url="$(resolve_linked_issue "$url")"
      if [[ "$trusted" == "true" ]]; then
        command="$(jq -r '.comment.body // ""' "$GITHUB_EVENT_PATH" | tr -d '\r' | xargs)"
        case "$command" in
          /review) status="In review" ;;
          /tested) status="Ready to merge" ;;
          /test-failed) status="In progress" ;;
        esac
      fi
    else
      url="$(jq -r '.issue.html_url' "$GITHUB_EVENT_PATH")"
      item_title="$(jq -r '.issue.title // ""' "$GITHUB_EVENT_PATH")"
      if [[ "$trusted" == "true" ]]; then
        command="$(jq -r '.comment.body // ""' "$GITHUB_EVENT_PATH" | tr -d '\r' | xargs)"
        case "$command" in
          /architecture-progress) status="In progress" ;;
          /architecture-ready) status="Ready to merge" ;;
        esac
      fi
    fi
    ;;
  workflow_dispatch)
    url="$(jq -r '.inputs.item_url' "$GITHUB_EVENT_PATH")"
    status="$(jq -r '.inputs.status' "$GITHUB_EVENT_PATH")"
    ;;
esac

[[ "$item_title" == "[Архитектура]"* ]] && { case "$status" in Backlog|Ready|Testing) status="In progress" ;; esac; }
if [[ ( "$item_title" == "[Инфраструктура]"* || "$item_title" == "[Infrastructure]"* ) && "$status" == "Testing" ]]; then status="In review"; fi
[[ -z "$url" || -z "$status" ]] && exit 0

project_json="$(GH_TOKEN="$PROJECT_TOKEN" gh api graphql -f query='query($login:String!){ organization(login:$login){ projectsV2(first:100){ nodes { id title fields(first:100){ nodes { ... on ProjectV2SingleSelectField { id name options { id name } } ... on ProjectV2IterationField { id name configuration { iterations { id title startDate duration } } } } } items(first:100){ nodes { id content { ... on Issue { url } ... on PullRequest { url } } } } } } } }' -f login="$PROJECT_OWNER")"
project="$(jq -c --arg title "$PROJECT_TITLE" '.data.organization.projectsV2.nodes[] | select(.title == $title)' <<<"$project_json" | head -n 1)"
[[ -z "$project" ]] && { echo "::error::Project '$PROJECT_TITLE' was not found"; exit 1; }
project_id="$(jq -r '.id' <<<"$project")"

if [[ -n "$legacy_issue_url" ]]; then
  legacy_item_id="$(jq -r --arg target "$legacy_issue_url" '.items.nodes[] | select(.content.url == $target) | .id' <<<"$project" | head -n 1)"
  [[ -n "$legacy_item_id" ]] && GH_TOKEN="$PROJECT_TOKEN" gh api graphql -f query='mutation($projectId:ID!,$itemId:ID!){ deleteProjectV2Item(input:{projectId:$projectId,itemId:$itemId}){ deletedItemId } }' -f projectId="$project_id" -f itemId="$legacy_item_id" >/dev/null
fi

item_id="$(jq -r --arg target "$url" '.items.nodes[] | select(.content.url == $target) | .id' <<<"$project" | head -n 1)"
if [[ -z "$item_id" ]]; then
  path="${url#https://github.com/}"
  IFS='/' read -r repo_owner repo_name content_kind content_number _ <<<"$path"
  case "$content_kind" in
    pull) query='query($owner:String!,$name:String!,$number:Int!){ repository(owner:$owner,name:$name){ pullRequest(number:$number){ id } } }'; jq_path='.data.repository.pullRequest.id' ;;
    issues) query='query($owner:String!,$name:String!,$number:Int!){ repository(owner:$owner,name:$name){ issue(number:$number){ id } } }'; jq_path='.data.repository.issue.id' ;;
    *) echo "::error::Unsupported project item URL: $url"; exit 1 ;;
  esac
  [[ "$repo_owner/$repo_name" == "$GITHUB_REPOSITORY" ]] && token="$REPO_TOKEN" || token="$PROJECT_TOKEN"
  content_id="$(GH_TOKEN="$token" gh api graphql -f query="$query" -f owner="$repo_owner" -f name="$repo_name" -F number="$content_number" --jq "$jq_path")"
  [[ -z "$content_id" || "$content_id" == "null" ]] && { echo "::error::Could not resolve project item: $url"; exit 1; }
  item_id="$(GH_TOKEN="$PROJECT_TOKEN" gh api graphql -f query='mutation($projectId:ID!,$contentId:ID!){ addProjectV2ItemById(input:{projectId:$projectId,contentId:$contentId}){ item { id } } }' -f projectId="$project_id" -f contentId="$content_id" --jq '.data.addProjectV2ItemById.item.id')"
fi

status_field_id="$(jq -r '.fields.nodes[] | select(.name == "Status") | .id' <<<"$project" | head -n 1)"
status_option_id="$(jq -r --arg status "$status" '.fields.nodes[] | select(.name == "Status") | .options[] | select(.name == $status) | .id' <<<"$project" | head -n 1)"
[[ -z "$status_field_id" || -z "$status_option_id" ]] && { echo "::error::Project status '$status' was not found"; exit 1; }
GH_TOKEN="$PROJECT_TOKEN" gh api graphql -f query='mutation($projectId:ID!,$itemId:ID!,$fieldId:ID!,$optionId:String!){ updateProjectV2ItemFieldValue(input:{projectId:$projectId,itemId:$itemId,fieldId:$fieldId,value:{singleSelectOptionId:$optionId}}){ projectV2Item { id } } }' -f projectId="$project_id" -f itemId="$item_id" -f fieldId="$status_field_id" -f optionId="$status_option_id" >/dev/null
iteration_field_id="$(jq -r '.fields.nodes[] | select(.name == "Iteration") | .id' <<<"$project" | head -n 1)"
current_iteration_id="$(python3 -c 'import json,sys,datetime as d; p=json.load(sys.stdin); t=d.datetime.now(d.timezone.utc).date(); fs=p["fields"]["nodes"]; its=next((f["configuration"]["iterations"] for f in fs if f and f.get("name")=="Iteration"), []); print(next((i["id"] for i in its if d.date.fromisoformat(i["startDate"]) <= t < d.date.fromisoformat(i["startDate"]) + d.timedelta(days=i["duration"])), ""))' <<<"$project")"
[[ -n "$iteration_field_id" && -n "$current_iteration_id" ]] && GH_TOKEN="$PROJECT_TOKEN" gh api graphql -f query='mutation($projectId:ID!,$itemId:ID!,$fieldId:ID!,$iterationId:String!){ updateProjectV2ItemFieldValue(input:{projectId:$projectId,itemId:$itemId,fieldId:$fieldId,value:{iterationId:$iterationId}}){ projectV2Item { id } } }' -f projectId="$project_id" -f itemId="$item_id" -f fieldId="$iteration_field_id" -f iterationId="$current_iteration_id" >/dev/null

echo "Synced Project item $url -> $status"
