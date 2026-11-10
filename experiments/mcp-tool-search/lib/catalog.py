"""Faithful reproduction catalog: ~536 MCP tools + 150 labelled queries.

Zed's exact queries, tools, and labels are not public (the Oct 20 2026 post
linked a meme, not a write-up or fixture repo). This catalog is built from
real public MCP server tool names/descriptions (GitHub, official
modelcontextprotocol servers, Linear, Slack, Postgres, filesystem, etc.)
and padded to 536 with additional realistic tools from the same families.

THIS IS A REPRODUCTION, not Zed's unpublished benchmark.
"""

from __future__ import annotations

import json
import random
import re
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[1]
DATA = ROOT / "data"

# Common MCP action verbs — the ranking failure mode Zed/StackOne describe.
VERBS = (
    "create",
    "get",
    "list",
    "update",
    "delete",
    "search",
    "send",
    "add",
    "remove",
    "set",
    "fetch",
    "post",
    "put",
    "run",
    "query",
)

SERVER_ALIASES: dict[str, list[str]] = {
    "github": ["github", "gh", "git hub"],
    "gitlab": ["gitlab", "gl"],
    "bitbucket": ["bitbucket", "bb"],
    "slack": ["slack"],
    "discord": ["discord"],
    "linear": ["linear"],
    "jira": ["jira", "atlassian"],
    "asana": ["asana"],
    "trello": ["trello"],
    "clickup": ["clickup", "click up"],
    "notion": ["notion"],
    "confluence": ["confluence"],
    "filesystem": ["filesystem", "files", "disk", "folder", "directory"],
    "memory": ["memory", "knowledge graph", "remember"],
    "postgres": ["postgres", "postgresql", "sql", "database"],
    "sqlite": ["sqlite"],
    "mysql": ["mysql"],
    "mongodb": ["mongodb", "mongo"],
    "redis": ["redis"],
    "elasticsearch": ["elasticsearch", "elastic"],
    "fetch": ["fetch", "http", "url", "webpage"],
    "git": ["git"],
    "playwright": ["playwright", "browser"],
    "puppeteer": ["puppeteer"],
    "docker": ["docker", "container"],
    "kubernetes": ["kubernetes", "k8s"],
    "sentry": ["sentry"],
    "datadog": ["datadog"],
    "stripe": ["stripe"],
    "shopify": ["shopify"],
    "salesforce": ["salesforce", "sfdc"],
    "hubspot": ["hubspot"],
    "zendesk": ["zendesk"],
    "pagerduty": ["pagerduty", "pager duty"],
    "gmail": ["gmail", "email", "mail"],
    "google_drive": ["google drive", "gdrive", "drive"],
    "google_calendar": ["google calendar", "gcal", "calendar"],
    "brave_search": ["brave", "web search"],
    "sequential_thinking": ["sequential thinking", "think step"],
    "time": ["time", "timezone", "clock"],
    "aws_s3": ["s3", "aws s3", "bucket"],
    "cloudflare": ["cloudflare"],
    "vercel": ["vercel"],
    "supabase": ["supabase"],
    "figma": ["figma"],
    "twilio": ["twilio", "sms"],
    "okta": ["okta"],
    "prometheus": ["prometheus"],
    "grafana": ["grafana"],
    "circleci": ["circleci", "ci"],
    "terraform": ["terraform"],
}


def _tool(
    server: str,
    name: str,
    description: str,
    params: list[str],
    *,
    source: str,
) -> dict[str, Any]:
    tid = f"{server}.{name}"
    return {
        "id": tid,
        "server": server,
        "name": name,
        "description": description,
        "params": params,
        "source": source,
        "aliases": SERVER_ALIASES.get(server, [server.replace("_", " ")]),
    }


def _real_core() -> list[dict[str, Any]]:
    """Hand-authored tools from public MCP servers / published schemas."""
    rows: list[tuple[str, str, str, str, str]] = [
        # GitHub official MCP (classic + current names)
        ("github", "get_me", "Get details of the authenticated GitHub user and their context.", "include_auth", "public"),
        ("github", "get_teams", "Get teams for the authenticated GitHub user.", "", "public"),
        ("github", "get_team_members", "List members of a GitHub team.", "org team_slug", "public"),
        ("github", "search_repositories", "Search GitHub repositories by name, description, or topic.", "query perPage sort", "public"),
        ("github", "get_file_contents", "Get file or directory contents from a GitHub repository.", "owner repo path ref", "public"),
        ("github", "list_commits", "List commits on a GitHub repository branch.", "owner repo sha page", "public"),
        ("github", "search_code", "Search code across GitHub repositories.", "query perPage", "public"),
        ("github", "search_commits", "Search commits across GitHub.", "query", "public"),
        ("github", "get_commit", "Get a single GitHub commit by SHA.", "owner repo sha", "public"),
        ("github", "get_file_blame", "Get git blame for a file in a GitHub repository.", "owner repo path", "public"),
        ("github", "list_branches", "List branches in a GitHub repository.", "owner repo", "public"),
        ("github", "list_tags", "List git tags in a GitHub repository.", "owner repo", "public"),
        ("github", "get_tag", "Get a git tag from a GitHub repository.", "owner repo tag", "public"),
        ("github", "list_releases", "List GitHub releases for a repository.", "owner repo", "public"),
        ("github", "get_latest_release", "Get the latest GitHub release.", "owner repo", "public"),
        ("github", "get_release_by_tag", "Get a GitHub release by tag name.", "owner repo tag", "public"),
        ("github", "create_or_update_file", "Create or update a single file in a GitHub repository.", "owner repo path content message branch", "public"),
        ("github", "create_repository", "Create a new GitHub repository.", "name description private", "public"),
        ("github", "delete_repository", "Delete a GitHub repository.", "owner repo", "public"),
        ("github", "fork_repository", "Fork a GitHub repository.", "owner repo organization", "public"),
        ("github", "create_branch", "Create a branch in a GitHub repository.", "owner repo branch from_branch", "public"),
        ("github", "push_files", "Push multiple files to a GitHub repository in one commit.", "owner repo branch files message", "public"),
        ("github", "delete_file", "Delete a file from a GitHub repository.", "owner repo path message branch", "public"),
        ("github", "list_starred_repositories", "List repositories starred by a GitHub user.", "username", "public"),
        ("github", "star_repository", "Star a GitHub repository.", "owner repo", "public"),
        ("github", "unstar_repository", "Unstar a GitHub repository.", "owner repo", "public"),
        ("github", "list_repository_collaborators", "List collaborators on a GitHub repository.", "owner repo", "public"),
        ("github", "get_repository_tree", "Get the git tree of a GitHub repository.", "owner repo tree_sha recursive", "public"),
        ("github", "create_issue", "Create an issue in a GitHub repository.", "owner repo title body labels assignees", "public"),
        ("github", "issue_write", "Create or update a GitHub issue (consolidated write tool).", "method owner repo title body issue_number", "public"),
        ("github", "issue_read", "Read a GitHub issue by number.", "method owner repo issue_number", "public"),
        ("github", "search_issues", "Search GitHub issues.", "query owner repo", "public"),
        ("github", "list_issues", "List issues in a GitHub repository.", "owner repo state labels", "public"),
        ("github", "add_issue_comment", "Add a comment to a GitHub issue.", "owner repo issue_number body", "public"),
        ("github", "update_issue_comment", "Update a comment on a GitHub issue.", "owner repo comment_id body", "public"),
        ("github", "create_pull_request", "Open a new pull request on GitHub.", "owner repo title head base body draft", "public"),
        ("github", "list_pull_requests", "List pull requests in a GitHub repository.", "owner repo state", "public"),
        ("github", "search_pull_requests", "Search GitHub pull requests.", "query", "public"),
        ("github", "pull_request_read", "Read a GitHub pull request by number.", "owner repo pull_number", "public"),
        ("github", "update_pull_request", "Update title, body, or state of a GitHub pull request.", "owner repo pull_number title body state", "public"),
        ("github", "merge_pull_request", "Merge a GitHub pull request.", "owner repo pull_number merge_method", "public"),
        ("github", "update_pull_request_branch", "Update a pull request branch with the base branch.", "owner repo pull_number", "public"),
        ("github", "pull_request_review_write", "Create or submit a GitHub pull request review.", "method owner repo pull_number body event", "public"),
        ("github", "add_comment_to_pending_review", "Add a comment to a pending GitHub pull request review.", "owner repo pull_number path body line", "public"),
        ("github", "assign_copilot_to_issue", "Assign GitHub Copilot to work on an issue.", "owner repo issue_number", "public"),
        ("github", "request_copilot_review", "Request a Copilot review on a GitHub pull request.", "owner repo pull_number", "public"),
        ("github", "get_code_scanning_alert", "Get a GitHub code scanning alert.", "owner repo alert_number", "public"),
        ("github", "list_code_scanning_alerts", "List GitHub code scanning alerts.", "owner repo state", "public"),
        ("github", "get_secret_scanning_alert", "Get a GitHub secret scanning alert.", "owner repo alert_number", "public"),
        ("github", "list_secret_scanning_alerts", "List GitHub secret scanning alerts.", "owner repo", "public"),
        ("github", "get_dependabot_alert", "Get a Dependabot alert.", "owner repo alert_number", "public"),
        ("github", "list_dependabot_alerts", "List Dependabot alerts for a repository.", "owner repo", "public"),
        ("github", "list_notifications", "List GitHub notifications for the authenticated user.", "all participating", "public"),
        ("github", "get_notification_details", "Get details of a GitHub notification thread.", "thread_id", "public"),
        ("github", "dismiss_notification", "Dismiss or mark a GitHub notification as done.", "thread_id", "public"),
        ("github", "mark_all_notifications_read", "Mark all GitHub notifications as read.", "", "public"),
        ("github", "list_discussions", "List GitHub discussions in a repository.", "owner repo", "public"),
        ("github", "get_discussion", "Get a GitHub discussion.", "owner repo discussion_number", "public"),
        ("github", "get_discussion_comments", "Get comments on a GitHub discussion.", "owner repo discussion_number", "public"),
        ("github", "actions_list", "List GitHub Actions workflows.", "owner repo", "public"),
        ("github", "actions_get", "Get a GitHub Actions workflow or run.", "owner repo workflow_id", "public"),
        ("github", "actions_run_trigger", "Trigger a GitHub Actions workflow dispatch.", "owner repo workflow_id ref inputs", "public"),
        ("github", "actions_get_job_logs", "Get logs for a GitHub Actions job.", "owner repo job_id", "public"),
        ("github", "list_gists", "List GitHub gists for a user.", "username", "public"),
        ("github", "get_gist", "Get a GitHub gist by id.", "gist_id", "public"),
        ("github", "create_gist", "Create a GitHub gist.", "description files public", "public"),
        ("github", "update_gist", "Update a GitHub gist.", "gist_id description files", "public"),
        ("github", "projects_list", "List GitHub Projects.", "owner owner_type", "public"),
        ("github", "projects_get", "Get a GitHub Project.", "project_number owner", "public"),
        ("github", "projects_write", "Create or update a GitHub Project item.", "method project_id title", "public"),
        ("github", "get_label", "Get a GitHub label.", "owner repo name", "public"),
        ("github", "list_labels", "List labels in a GitHub repository.", "owner repo", "public"),
        ("github", "label_write", "Create, update, or delete a GitHub label.", "method owner repo name color", "public"),
        ("github", "search_users", "Search GitHub users.", "query", "public"),
        ("github", "search_orgs", "Search GitHub organizations.", "query", "public"),
        # Official filesystem / memory / fetch / git / postgres / sequential-thinking
        ("filesystem", "read_file", "Read the complete contents of a file from the local filesystem.", "path", "public"),
        ("filesystem", "read_text_file", "Read a text file from the local filesystem.", "path head tail", "public"),
        ("filesystem", "read_media_file", "Read an image or audio file from the local filesystem.", "path", "public"),
        ("filesystem", "write_file", "Create a new file or completely overwrite an existing file.", "path content", "public"),
        ("filesystem", "edit_file", "Make a line-based edit to a text file using old and new strings.", "path old_string new_string", "public"),
        ("filesystem", "create_directory", "Create a new directory or ensure a directory exists.", "path", "public"),
        ("filesystem", "list_directory", "Get a detailed listing of files and directories.", "path", "public"),
        ("filesystem", "list_directory_with_sizes", "Get a listing of files and directories with sizes.", "path", "public"),
        ("filesystem", "directory_tree", "Get a recursive tree view of files and directories.", "path", "public"),
        ("filesystem", "move_file", "Move or rename files and directories.", "source destination", "public"),
        ("filesystem", "search_files", "Recursively search for files matching a pattern.", "path pattern", "public"),
        ("filesystem", "get_file_info", "Retrieve metadata about a file or directory.", "path", "public"),
        ("filesystem", "list_allowed_directories", "List directories the filesystem server is allowed to access.", "", "public"),
        ("memory", "create_entities", "Create multiple entities in the knowledge graph.", "entities", "public"),
        ("memory", "create_relations", "Create relations between entities in the knowledge graph.", "relations", "public"),
        ("memory", "add_observations", "Add observations to existing entities in the knowledge graph.", "observations", "public"),
        ("memory", "delete_entities", "Delete entities and their relations from the knowledge graph.", "entityNames", "public"),
        ("memory", "delete_observations", "Delete specific observations from entities.", "deletions", "public"),
        ("memory", "delete_relations", "Delete relations from the knowledge graph.", "relations", "public"),
        ("memory", "read_graph", "Read the entire knowledge graph.", "", "public"),
        ("memory", "search_nodes", "Search for nodes in the knowledge graph based on a query.", "query", "public"),
        ("memory", "open_nodes", "Open specific nodes in the knowledge graph by name.", "names", "public"),
        ("postgres", "query", "Run a read-only SQL query against PostgreSQL.", "sql", "public"),
        ("postgres", "list_tables", "List tables in the connected PostgreSQL database.", "schema", "public"),
        ("postgres", "describe_table", "Describe columns and types of a PostgreSQL table.", "schema table", "public"),
        ("postgres", "list_schemas", "List schemas in the PostgreSQL database.", "", "public"),
        ("postgres", "explain_query", "EXPLAIN a PostgreSQL query plan.", "sql", "public"),
        ("fetch", "fetch", "Fetch a URL and return the contents as markdown or HTML.", "url max_length raw", "public"),
        ("git", "git_status", "Show the working tree status of a git repository.", "repo_path", "public"),
        ("git", "git_diff_unstaged", "Show unstaged git differences.", "repo_path", "public"),
        ("git", "git_diff_staged", "Show staged git differences.", "repo_path", "public"),
        ("git", "git_diff", "Show git diff between branches or commits.", "repo_path target", "public"),
        ("git", "git_commit", "Record staged changes to the git repository.", "repo_path message", "public"),
        ("git", "git_add", "Add file contents to the git staging area.", "repo_path files", "public"),
        ("git", "git_reset", "Unstage all staged changes.", "repo_path", "public"),
        ("git", "git_log", "Show commit logs.", "repo_path max_count", "public"),
        ("git", "git_create_branch", "Create a new git branch.", "repo_path branch_name base_branch", "public"),
        ("git", "git_checkout", "Switch git branches.", "repo_path branch_name", "public"),
        ("git", "git_show", "Show a git commit.", "repo_path revision", "public"),
        ("git", "git_branch", "List git branches.", "repo_path", "public"),
        ("sequential_thinking", "sequentialthinking", "A detailed tool for dynamic and reflective problem-solving through thoughts.", "thought nextThoughtNeeded thoughtNumber totalThoughts", "public"),
        ("time", "get_current_time", "Get the current time in a timezone.", "timezone", "public"),
        ("time", "convert_time", "Convert time between timezones.", "source_timezone time target_timezone", "public"),
        ("brave_search", "brave_web_search", "Search the web using Brave Search.", "query count offset", "public"),
        ("brave_search", "brave_local_search", "Search for local businesses and places using Brave.", "query count", "public"),
        # Slack official-style
        ("slack", "slack_post_message", "Post a message to a Slack channel.", "channel_id text", "public"),
        ("slack", "slack_reply_to_thread", "Reply to a Slack thread.", "channel_id thread_ts text", "public"),
        ("slack", "slack_add_reaction", "Add an emoji reaction to a Slack message.", "channel_id timestamp emoji", "public"),
        ("slack", "slack_get_channel_history", "Get recent messages from a Slack channel.", "channel_id limit", "public"),
        ("slack", "slack_get_thread_replies", "Get replies in a Slack thread.", "channel_id thread_ts", "public"),
        ("slack", "slack_list_channels", "List Slack channels in the workspace.", "limit cursor", "public"),
        ("slack", "slack_get_users", "Get a list of Slack users.", "cursor limit", "public"),
        ("slack", "slack_get_user_profile", "Get a Slack user's profile.", "user_id", "public"),
        ("slack", "slack_join_channel", "Join a Slack channel.", "channel_id", "public"),
        ("slack", "slack_leave_channel", "Leave a Slack channel.", "channel_id", "public"),
        ("slack", "slack_create_channel", "Create a Slack channel.", "name is_private", "public"),
        ("slack", "slack_set_channel_topic", "Set the topic of a Slack channel.", "channel_id topic", "public"),
        ("slack", "slack_upload_file", "Upload a file to Slack.", "channel_id filename content", "public"),
        ("slack", "slack_search_messages", "Search Slack messages.", "query count", "public"),
        ("slack", "slack_list_users", "List Slack workspace users.", "limit cursor", "public"),
        # Linear
        ("linear", "linear_create_issue", "Create a Linear issue in a team.", "title description team teamId priority labels", "public"),
        ("linear", "linear_update_issue", "Update a Linear issue.", "id title description state priority", "public"),
        ("linear", "linear_list_issues", "List Linear issues, optionally filtered.", "team state assignee", "public"),
        ("linear", "linear_get_issue", "Get a Linear issue by id or identifier.", "id", "public"),
        ("linear", "linear_search_issues", "Search Linear issues by text.", "query", "public"),
        ("linear", "linear_create_comment", "Add a comment to a Linear issue.", "issueId body", "public"),
        ("linear", "linear_list_teams", "List Linear teams.", "", "public"),
        ("linear", "linear_list_projects", "List Linear projects.", "team", "public"),
        ("linear", "linear_create_project", "Create a Linear project.", "name team description", "public"),
        ("linear", "linear_assign_issue", "Assign a Linear issue to a user.", "id assigneeId", "public"),
        # Jira
        ("jira", "jira_create_issue", "Create a Jira issue or ticket in a project.", "project key summary description issuetype", "public"),
        ("jira", "jira_update_issue", "Update an existing Jira issue.", "issue_key fields", "public"),
        ("jira", "jira_get_issue", "Get a Jira issue by key.", "issue_key", "public"),
        ("jira", "jira_search_issues", "Search Jira issues with JQL.", "jql maxResults", "public"),
        ("jira", "jira_add_comment", "Add a comment to a Jira issue.", "issue_key body", "public"),
        ("jira", "jira_transition_issue", "Transition a Jira issue to a new status.", "issue_key transition", "public"),
        ("jira", "jira_assign_issue", "Assign a Jira issue.", "issue_key account_id", "public"),
        ("jira", "jira_list_projects", "List Jira projects.", "", "public"),
        ("jira", "jira_create_sprint", "Create a Jira Software sprint.", "board_id name startDate endDate", "public"),
        ("jira", "jira_add_worklog", "Add a worklog to a Jira issue.", "issue_key timeSpent comment", "public"),
        # Notion
        ("notion", "notion_search", "Search Notion pages and databases.", "query filter", "public"),
        ("notion", "notion_get_page", "Retrieve a Notion page.", "page_id", "public"),
        ("notion", "notion_create_page", "Create a Notion page in a parent page or database.", "parent properties children", "public"),
        ("notion", "notion_update_page", "Update a Notion page properties.", "page_id properties", "public"),
        ("notion", "notion_get_block", "Get a Notion block.", "block_id", "public"),
        ("notion", "notion_append_block", "Append children blocks to a Notion block.", "block_id children", "public"),
        ("notion", "notion_query_database", "Query a Notion database.", "database_id filter sorts", "public"),
        ("notion", "notion_create_database", "Create a Notion database.", "parent title properties", "public"),
        ("notion", "notion_list_users", "List Notion workspace users.", "", "public"),
        ("notion", "notion_get_comments", "Get comments on a Notion page.", "block_id", "public"),
        # Playwright / puppeteer
        ("playwright", "browser_navigate", "Navigate the browser to a URL.", "url", "public"),
        ("playwright", "browser_snapshot", "Capture an accessibility snapshot of the current page.", "", "public"),
        ("playwright", "browser_click", "Click an element on the page.", "element ref", "public"),
        ("playwright", "browser_type", "Type text into an editable element.", "element ref text", "public"),
        ("playwright", "browser_fill_form", "Fill multiple form fields.", "fields", "public"),
        ("playwright", "browser_take_screenshot", "Take a screenshot of the page or an element.", "filename fullPage", "public"),
        ("playwright", "browser_evaluate", "Evaluate JavaScript on the page.", "function", "public"),
        ("playwright", "browser_tab_list", "List open browser tabs.", "", "public"),
        ("playwright", "browser_tab_new", "Open a new browser tab.", "url", "public"),
        ("playwright", "browser_tab_close", "Close a browser tab.", "index", "public"),
        ("playwright", "browser_wait_for", "Wait for text or time to pass.", "text time", "public"),
        ("playwright", "browser_press_key", "Press a key on the page.", "key", "public"),
        ("puppeteer", "puppeteer_navigate", "Navigate to a URL with Puppeteer.", "url", "public"),
        ("puppeteer", "puppeteer_screenshot", "Take a screenshot with Puppeteer.", "name selector", "public"),
        ("puppeteer", "puppeteer_click", "Click an element with Puppeteer.", "selector", "public"),
        ("puppeteer", "puppeteer_fill", "Fill an input with Puppeteer.", "selector value", "public"),
        ("puppeteer", "puppeteer_evaluate", "Execute JavaScript with Puppeteer.", "script", "public"),
        # Docker / k8s
        ("docker", "docker_ps", "List running Docker containers.", "all", "public"),
        ("docker", "docker_logs", "Fetch logs from a Docker container.", "container tail", "public"),
        ("docker", "docker_run", "Run a Docker container.", "image name ports env", "public"),
        ("docker", "docker_stop", "Stop a Docker container.", "container", "public"),
        ("docker", "docker_rm", "Remove a Docker container.", "container force", "public"),
        ("docker", "docker_images", "List Docker images.", "", "public"),
        ("docker", "docker_build", "Build a Docker image.", "path tag", "public"),
        ("docker", "docker_exec", "Run a command in a running Docker container.", "container command", "public"),
        ("kubernetes", "k8s_list_pods", "List Kubernetes pods in a namespace.", "namespace", "public"),
        ("kubernetes", "k8s_get_pod", "Get a Kubernetes pod.", "namespace name", "public"),
        ("kubernetes", "k8s_pod_logs", "Get logs from a Kubernetes pod.", "namespace name container", "public"),
        ("kubernetes", "k8s_apply", "Apply a Kubernetes manifest.", "manifest namespace", "public"),
        ("kubernetes", "k8s_delete", "Delete a Kubernetes resource.", "kind name namespace", "public"),
        ("kubernetes", "k8s_list_deployments", "List Kubernetes deployments.", "namespace", "public"),
        ("kubernetes", "k8s_scale_deployment", "Scale a Kubernetes deployment.", "namespace name replicas", "public"),
        ("kubernetes", "k8s_list_services", "List Kubernetes services.", "namespace", "public"),
        ("kubernetes", "k8s_get_events", "List Kubernetes events.", "namespace", "public"),
        # Stripe / Shopify / Salesforce
        ("stripe", "stripe_create_customer", "Create a Stripe customer.", "email name", "public"),
        ("stripe", "stripe_get_customer", "Retrieve a Stripe customer.", "customer_id", "public"),
        ("stripe", "stripe_list_customers", "List Stripe customers.", "email limit", "public"),
        ("stripe", "stripe_create_payment_intent", "Create a Stripe PaymentIntent.", "amount currency customer", "public"),
        ("stripe", "stripe_get_payment_intent", "Retrieve a Stripe PaymentIntent.", "id", "public"),
        ("stripe", "stripe_create_invoice", "Create a Stripe invoice.", "customer", "public"),
        ("stripe", "stripe_list_invoices", "List Stripe invoices.", "customer", "public"),
        ("stripe", "stripe_create_product", "Create a Stripe product.", "name description", "public"),
        ("stripe", "stripe_create_price", "Create a Stripe price.", "product unit_amount currency", "public"),
        ("stripe", "stripe_list_subscriptions", "List Stripe subscriptions.", "customer status", "public"),
        ("stripe", "stripe_cancel_subscription", "Cancel a Stripe subscription.", "subscription_id", "public"),
        ("stripe", "stripe_create_refund", "Create a Stripe refund.", "payment_intent amount", "public"),
        ("shopify", "shopify_list_products", "List Shopify products.", "limit query", "public"),
        ("shopify", "shopify_get_product", "Get a Shopify product.", "id", "public"),
        ("shopify", "shopify_create_product", "Create a Shopify product.", "title body_html vendor", "public"),
        ("shopify", "shopify_update_product", "Update a Shopify product.", "id title", "public"),
        ("shopify", "shopify_list_orders", "List Shopify orders.", "status limit", "public"),
        ("shopify", "shopify_get_order", "Get a Shopify order.", "id", "public"),
        ("shopify", "shopify_create_order", "Create a Shopify order.", "line_items email", "public"),
        ("shopify", "shopify_list_customers", "List Shopify customers.", "limit", "public"),
        ("salesforce", "salesforce_query", "Run a SOQL query against Salesforce.", "soql", "public"),
        ("salesforce", "salesforce_create_record", "Create a Salesforce record.", "sobject fields", "public"),
        ("salesforce", "salesforce_update_record", "Update a Salesforce record.", "sobject id fields", "public"),
        ("salesforce", "salesforce_get_record", "Get a Salesforce record by id.", "sobject id", "public"),
        ("salesforce", "salesforce_delete_record", "Delete a Salesforce record.", "sobject id", "public"),
        ("salesforce", "salesforce_list_opportunities", "List Salesforce opportunities.", "stage", "public"),
        ("salesforce", "salesforce_create_lead", "Create a Salesforce lead.", "firstName lastName company email", "public"),
        ("salesforce", "salesforce_convert_lead", "Convert a Salesforce lead.", "leadId", "public"),
        # Observability / incident
        ("sentry", "sentry_list_issues", "List Sentry issues for a project.", "organization project query", "public"),
        ("sentry", "sentry_get_issue", "Get a Sentry issue.", "organization issue_id", "public"),
        ("sentry", "sentry_list_events", "List events for a Sentry issue.", "organization issue_id", "public"),
        ("sentry", "sentry_update_issue", "Update status of a Sentry issue.", "organization issue_id status", "public"),
        ("sentry", "sentry_list_projects", "List Sentry projects.", "organization", "public"),
        ("datadog", "datadog_query_metrics", "Query Datadog timeseries metrics.", "query from_ts to_ts", "public"),
        ("datadog", "datadog_list_monitors", "List Datadog monitors.", "query", "public"),
        ("datadog", "datadog_get_monitor", "Get a Datadog monitor.", "monitor_id", "public"),
        ("datadog", "datadog_create_monitor", "Create a Datadog monitor.", "name type query message", "public"),
        ("datadog", "datadog_list_logs", "Search Datadog logs.", "query from_ts to_ts", "public"),
        ("pagerduty", "pagerduty_list_incidents", "List PagerDuty incidents.", "status urgency", "public"),
        ("pagerduty", "pagerduty_get_incident", "Get a PagerDuty incident.", "id", "public"),
        ("pagerduty", "pagerduty_create_incident", "Create a PagerDuty incident.", "title service_id urgency", "public"),
        ("pagerduty", "pagerduty_acknowledge_incident", "Acknowledge a PagerDuty incident.", "id", "public"),
        ("pagerduty", "pagerduty_resolve_incident", "Resolve a PagerDuty incident.", "id", "public"),
        ("pagerduty", "pagerduty_list_oncalls", "List PagerDuty on-call users.", "schedule_id", "public"),
        # Gmail / Drive / Calendar
        ("gmail", "gmail_send_email", "Send an email via Gmail.", "to subject body cc", "public"),
        ("gmail", "gmail_search_emails", "Search Gmail messages.", "query maxResults", "public"),
        ("gmail", "gmail_get_email", "Get a Gmail message by id.", "id", "public"),
        ("gmail", "gmail_create_draft", "Create a Gmail draft.", "to subject body", "public"),
        ("gmail", "gmail_list_labels", "List Gmail labels.", "", "public"),
        ("gmail", "gmail_modify_email", "Add or remove Gmail labels on a message.", "id addLabelIds removeLabelIds", "public"),
        ("gmail", "gmail_trash_email", "Move a Gmail message to trash.", "id", "public"),
        ("google_drive", "gdrive_search", "Search files in Google Drive.", "query", "public"),
        ("google_drive", "gdrive_get_file", "Get Google Drive file metadata or content.", "file_id", "public"),
        ("google_drive", "gdrive_create_file", "Create a file in Google Drive.", "name mimeType content parent", "public"),
        ("google_drive", "gdrive_update_file", "Update a Google Drive file.", "file_id content name", "public"),
        ("google_drive", "gdrive_list_folder", "List files in a Google Drive folder.", "folder_id", "public"),
        ("google_drive", "gdrive_share_file", "Share a Google Drive file.", "file_id email role", "public"),
        ("google_calendar", "gcal_list_events", "List Google Calendar events.", "calendar_id timeMin timeMax", "public"),
        ("google_calendar", "gcal_create_event", "Create a Google Calendar event.", "calendar_id summary start end attendees", "public"),
        ("google_calendar", "gcal_update_event", "Update a Google Calendar event.", "calendar_id event_id summary", "public"),
        ("google_calendar", "gcal_delete_event", "Delete a Google Calendar event.", "calendar_id event_id", "public"),
        ("google_calendar", "gcal_list_calendars", "List Google calendars.", "", "public"),
        # GitLab / Bitbucket
        ("gitlab", "gitlab_create_issue", "Create a GitLab issue.", "project_id title description", "public"),
        ("gitlab", "gitlab_list_issues", "List GitLab issues.", "project_id state", "public"),
        ("gitlab", "gitlab_get_issue", "Get a GitLab issue.", "project_id issue_iid", "public"),
        ("gitlab", "gitlab_create_merge_request", "Create a GitLab merge request.", "project_id source_branch target_branch title", "public"),
        ("gitlab", "gitlab_list_merge_requests", "List GitLab merge requests.", "project_id state", "public"),
        ("gitlab", "gitlab_get_merge_request", "Get a GitLab merge request.", "project_id merge_request_iid", "public"),
        ("gitlab", "gitlab_merge_merge_request", "Merge a GitLab merge request.", "project_id merge_request_iid", "public"),
        ("gitlab", "gitlab_list_projects", "List GitLab projects.", "search", "public"),
        ("gitlab", "gitlab_get_file", "Get a file from a GitLab project.", "project_id file_path ref", "public"),
        ("gitlab", "gitlab_create_pipeline", "Create a GitLab CI pipeline.", "project_id ref", "public"),
        ("bitbucket", "bitbucket_create_pr", "Create a Bitbucket pull request.", "workspace repo title source dest", "public"),
        ("bitbucket", "bitbucket_list_prs", "List Bitbucket pull requests.", "workspace repo", "public"),
        ("bitbucket", "bitbucket_create_issue", "Create a Bitbucket issue.", "workspace repo title", "public"),
        ("bitbucket", "bitbucket_list_repos", "List Bitbucket repositories.", "workspace", "public"),
        # Databases
        ("sqlite", "sqlite_query", "Run a SQL query against SQLite.", "sql", "public"),
        ("sqlite", "sqlite_list_tables", "List tables in the SQLite database.", "", "public"),
        ("sqlite", "sqlite_describe_table", "Describe a SQLite table.", "table", "public"),
        ("mysql", "mysql_query", "Run a SQL query against MySQL.", "sql", "public"),
        ("mysql", "mysql_list_tables", "List MySQL tables.", "schema", "public"),
        ("mongodb", "mongo_find", "Find documents in a MongoDB collection.", "database collection filter", "public"),
        ("mongodb", "mongo_insert", "Insert documents into MongoDB.", "database collection documents", "public"),
        ("mongodb", "mongo_update", "Update documents in MongoDB.", "database collection filter update", "public"),
        ("mongodb", "mongo_delete", "Delete documents from MongoDB.", "database collection filter", "public"),
        ("mongodb", "mongo_list_collections", "List MongoDB collections.", "database", "public"),
        ("redis", "redis_get", "Get a Redis key.", "key", "public"),
        ("redis", "redis_set", "Set a Redis key.", "key value ttl", "public"),
        ("redis", "redis_delete", "Delete Redis keys.", "keys", "public"),
        ("redis", "redis_keys", "List Redis keys matching a pattern.", "pattern", "public"),
        ("elasticsearch", "es_search", "Search an Elasticsearch index.", "index query", "public"),
        ("elasticsearch", "es_index_doc", "Index a document in Elasticsearch.", "index document id", "public"),
        ("elasticsearch", "es_get_doc", "Get a document from Elasticsearch.", "index id", "public"),
        # Cloud
        ("aws_s3", "s3_list_buckets", "List AWS S3 buckets.", "", "public"),
        ("aws_s3", "s3_list_objects", "List objects in an S3 bucket.", "bucket prefix", "public"),
        ("aws_s3", "s3_get_object", "Get an object from S3.", "bucket key", "public"),
        ("aws_s3", "s3_put_object", "Upload an object to S3.", "bucket key body", "public"),
        ("aws_s3", "s3_delete_object", "Delete an S3 object.", "bucket key", "public"),
        ("cloudflare", "cf_list_zones", "List Cloudflare zones.", "", "public"),
        ("cloudflare", "cf_list_dns", "List DNS records for a Cloudflare zone.", "zone_id", "public"),
        ("cloudflare", "cf_create_dns", "Create a Cloudflare DNS record.", "zone_id type name content", "public"),
        ("cloudflare", "cf_purge_cache", "Purge Cloudflare cache.", "zone_id files", "public"),
        ("vercel", "vercel_list_projects", "List Vercel projects.", "", "public"),
        ("vercel", "vercel_list_deployments", "List Vercel deployments.", "projectId", "public"),
        ("vercel", "vercel_get_deployment", "Get a Vercel deployment.", "id", "public"),
        ("vercel", "vercel_create_project", "Create a Vercel project.", "name", "public"),
        ("supabase", "supabase_list_tables", "List tables in a Supabase project.", "", "public"),
        ("supabase", "supabase_select", "Select rows from a Supabase table.", "table filter", "public"),
        ("supabase", "supabase_insert", "Insert rows into a Supabase table.", "table rows", "public"),
        ("supabase", "supabase_update", "Update rows in a Supabase table.", "table filter values", "public"),
        ("supabase", "supabase_invoke_fn", "Invoke a Supabase edge function.", "name body", "public"),
        # Misc public MCP-style
        ("figma", "figma_get_file", "Get a Figma file.", "file_key", "public"),
        ("figma", "figma_get_file_nodes", "Get specific nodes from a Figma file.", "file_key ids", "public"),
        ("figma", "figma_get_comments", "Get comments on a Figma file.", "file_key", "public"),
        ("figma", "figma_post_comment", "Post a comment on a Figma file.", "file_key message", "public"),
        ("figma", "figma_get_images", "Export images from a Figma file.", "file_key ids format", "public"),
        ("twilio", "twilio_send_sms", "Send an SMS via Twilio.", "to from_ body", "public"),
        ("twilio", "twilio_list_messages", "List Twilio SMS messages.", "to", "public"),
        ("twilio", "twilio_make_call", "Place a phone call via Twilio.", "to from_ url", "public"),
        ("okta", "okta_list_users", "List Okta users.", "q", "public"),
        ("okta", "okta_get_user", "Get an Okta user.", "user_id", "public"),
        ("okta", "okta_create_user", "Create an Okta user.", "profile", "public"),
        ("okta", "okta_deactivate_user", "Deactivate an Okta user.", "user_id", "public"),
        ("prometheus", "prom_query", "Instant query Prometheus.", "query", "public"),
        ("prometheus", "prom_query_range", "Range query Prometheus.", "query start end step", "public"),
        ("prometheus", "prom_list_metrics", "List Prometheus metric names.", "match", "public"),
        ("grafana", "grafana_search_dashboards", "Search Grafana dashboards.", "query", "public"),
        ("grafana", "grafana_get_dashboard", "Get a Grafana dashboard.", "uid", "public"),
        ("grafana", "grafana_create_annotation", "Create a Grafana annotation.", "text time tags", "public"),
        ("circleci", "circleci_list_pipelines", "List CircleCI pipelines.", "project_slug", "public"),
        ("circleci", "circleci_get_pipeline", "Get a CircleCI pipeline.", "pipeline_id", "public"),
        ("circleci", "circleci_trigger_pipeline", "Trigger a CircleCI pipeline.", "project_slug branch", "public"),
        ("terraform", "tf_plan", "Run terraform plan.", "dir", "public"),
        ("terraform", "tf_apply", "Run terraform apply.", "dir auto_approve", "public"),
        ("terraform", "tf_state_list", "List resources in terraform state.", "dir", "public"),
        ("asana", "asana_create_task", "Create an Asana task.", "name notes projects assignee", "public"),
        ("asana", "asana_list_tasks", "List Asana tasks.", "project assignee", "public"),
        ("asana", "asana_get_task", "Get an Asana task.", "task_gid", "public"),
        ("asana", "asana_update_task", "Update an Asana task.", "task_gid name completed", "public"),
        ("asana", "asana_create_project", "Create an Asana project.", "name workspace", "public"),
        ("trello", "trello_create_card", "Create a Trello card.", "idList name desc", "public"),
        ("trello", "trello_list_cards", "List cards on a Trello board or list.", "idBoard idList", "public"),
        ("trello", "trello_create_board", "Create a Trello board.", "name", "public"),
        ("trello", "trello_add_comment", "Comment on a Trello card.", "idCard text", "public"),
        ("clickup", "clickup_create_task", "Create a ClickUp task.", "list_id name description", "public"),
        ("clickup", "clickup_list_tasks", "List ClickUp tasks.", "list_id", "public"),
        ("clickup", "clickup_get_task", "Get a ClickUp task.", "task_id", "public"),
        ("clickup", "clickup_update_task", "Update a ClickUp task.", "task_id name status", "public"),
        ("confluence", "confluence_get_page", "Get a Confluence page.", "id", "public"),
        ("confluence", "confluence_create_page", "Create a Confluence page.", "spaceId title body", "public"),
        ("confluence", "confluence_update_page", "Update a Confluence page.", "id title body", "public"),
        ("confluence", "confluence_search", "Search Confluence content.", "query", "public"),
        ("hubspot", "hubspot_create_contact", "Create a HubSpot contact.", "email firstname lastname", "public"),
        ("hubspot", "hubspot_get_contact", "Get a HubSpot contact.", "id", "public"),
        ("hubspot", "hubspot_list_contacts", "List HubSpot contacts.", "limit", "public"),
        ("hubspot", "hubspot_create_deal", "Create a HubSpot deal.", "dealname amount pipeline", "public"),
        ("hubspot", "hubspot_search_contacts", "Search HubSpot contacts.", "query", "public"),
        ("zendesk", "zendesk_create_ticket", "Create a Zendesk support ticket.", "subject comment requester", "public"),
        ("zendesk", "zendesk_get_ticket", "Get a Zendesk ticket.", "id", "public"),
        ("zendesk", "zendesk_list_tickets", "List Zendesk tickets.", "status", "public"),
        ("zendesk", "zendesk_update_ticket", "Update a Zendesk ticket.", "id status comment", "public"),
        ("zendesk", "zendesk_search", "Search Zendesk tickets and users.", "query", "public"),
        ("discord", "discord_send_message", "Send a message to a Discord channel.", "channel_id content", "public"),
        ("discord", "discord_list_channels", "List Discord guild channels.", "guild_id", "public"),
        ("discord", "discord_get_channel", "Get a Discord channel.", "channel_id", "public"),
        ("discord", "discord_add_reaction", "Add a reaction to a Discord message.", "channel_id message_id emoji", "public"),
        ("discord", "discord_list_members", "List Discord guild members.", "guild_id", "public"),
    ]
    tools = []
    for server, name, desc, params, source in rows:
        tools.append(_tool(server, name, desc, [p for p in params.split() if p], source=source))
    return tools


def _expand_family(server: str, resources: list[str], actions: list[str], source: str) -> list[dict[str, Any]]:
    out = []
    for resource in resources:
        singular = resource.rstrip("s") if resource.endswith("s") and not resource.endswith("ss") else resource
        for action in actions:
            if action == "list":
                name = f"{action}_{resource}"
                desc = f"{action.capitalize()} {resource.replace('_', ' ')} in {server.replace('_', ' ')}."
            elif action == "search":
                name = f"{action}_{resource}"
                desc = f"Search {resource.replace('_', ' ')} in {server.replace('_', ' ')}."
            else:
                name = f"{action}_{singular}"
                desc = f"{action.capitalize()} a {singular.replace('_', ' ')} in {server.replace('_', ' ')}."
            params = {
                "create": ["name", "title", "description", "body"],
                "get": ["id"],
                "list": ["limit", "cursor", "status"],
                "update": ["id", "fields"],
                "delete": ["id"],
                "search": ["query", "limit"],
            }.get(action, ["id"])
            out.append(_tool(server, name, desc, params, source=source))
    return out


def _pad_to_target(core: list[dict[str, Any]], target: int = 536) -> list[dict[str, Any]]:
    seen = {t["id"] for t in core}
    extras: list[dict[str, Any]] = []
    families = [
        ("github", ["milestones", "hooks", "environments", "packages", "check_runs", "artifacts", "runners"], ["create", "get", "list", "update", "delete"]),
        ("gitlab", ["pipelines", "jobs", "wikis", "snippets", "labels", "milestones", "releases"], ["create", "get", "list", "update", "delete"]),
        ("jira", ["boards", "sprints", "filters", "webhooks", "attachments", "versions"], ["create", "get", "list", "update", "delete"]),
        ("linear", ["cycles", "labels", "users", "comments", "attachments"], ["create", "get", "list", "update", "delete"]),
        ("slack", ["reminders", "canvases", "bookmarks", "usergroups", "files", "pins"], ["create", "get", "list", "update", "delete"]),
        ("notion", ["comments", "users_tokens", "data_sources"], ["create", "get", "list", "update", "delete"]),
        ("postgres", ["indexes", "views", "roles", "extensions", "publications"], ["list", "get", "create", "delete"]),
        ("filesystem", ["symlinks", "permissions"], ["get", "list", "update"]),
        ("docker", ["volumes", "networks", "compose_services"], ["create", "get", "list", "delete"]),
        ("kubernetes", ["configmaps", "secrets", "ingresses", "namespaces", "nodes", "jobs"], ["create", "get", "list", "update", "delete"]),
        ("stripe", ["coupons", "disputes", "payouts", "webhooks", "checkout_sessions"], ["create", "get", "list", "update", "delete"]),
        ("shopify", ["collections", "inventory_items", "discounts", "fulfillments"], ["create", "get", "list", "update", "delete"]),
        ("salesforce", ["accounts", "contacts", "cases", "campaigns", "tasks"], ["create", "get", "list", "update", "delete"]),
        ("sentry", ["releases", "alerts", "projects_keys"], ["create", "get", "list", "update", "delete"]),
        ("datadog", ["dashboards", "slos", "synthetics", "incidents"], ["create", "get", "list", "update", "delete"]),
        ("gmail", ["filters", "threads", "attachments", "vacation"], ["create", "get", "list", "update", "delete"]),
        ("google_drive", ["permissions", "revisions", "comments", "drives"], ["create", "get", "list", "update", "delete"]),
        ("google_calendar", ["acl_rules", "freebusy"], ["get", "list", "create", "delete"]),
        ("aws_s3", ["bucket_policies", "multipart_uploads"], ["create", "get", "list", "delete"]),
        ("cloudflare", ["workers", "waf_rules", "certificates"], ["create", "get", "list", "update", "delete"]),
        ("vercel", ["env_vars", "domains", "aliases", "checks"], ["create", "get", "list", "update", "delete"]),
        ("supabase", ["buckets", "policies", "functions"], ["create", "get", "list", "update", "delete"]),
        ("hubspot", ["companies", "tickets", "engagements"], ["create", "get", "list", "update", "delete"]),
        ("zendesk", ["users", "organizations", "macros"], ["create", "get", "list", "update", "delete"]),
        ("discord", ["roles", "webhooks", "threads", "emojis"], ["create", "get", "list", "update", "delete"]),
        ("asana", ["sections", "portfolios", "tags", "stories"], ["create", "get", "list", "update", "delete"]),
        ("trello", ["lists", "checklists", "labels", "members"], ["create", "get", "list", "update", "delete"]),
        ("clickup", ["lists", "folders", "spaces", "comments"], ["create", "get", "list", "update", "delete"]),
        ("confluence", ["spaces", "attachments", "labels"], ["create", "get", "list", "update", "delete"]),
        ("okta", ["groups", "apps", "factors"], ["create", "get", "list", "update", "delete"]),
        ("twilio", ["phone_numbers", "verify_services"], ["create", "get", "list", "delete"]),
        ("figma", ["projects", "components", "styles"], ["get", "list"]),
        ("prometheus", ["alerts", "targets", "rules"], ["get", "list"]),
        ("grafana", ["folders", "alert_rules", "datasources"], ["create", "get", "list", "update", "delete"]),
        ("circleci", ["workflows", "jobs", "contexts"], ["get", "list", "create"]),
        ("terraform", ["workspaces", "variables"], ["create", "get", "list", "update", "delete"]),
        ("pagerduty", ["services", "schedules", "escalation_policies"], ["create", "get", "list", "update", "delete"]),
        ("elasticsearch", ["indices", "aliases", "templates"], ["create", "get", "list", "delete"]),
        ("redis", ["hashes", "lists", "streams"], ["get", "list", "create", "delete"]),
        ("mongodb", ["indexes", "aggregations"], ["create", "get", "list", "delete"]),
        ("mysql", ["users", "indexes", "views"], ["create", "get", "list", "delete"]),
        ("sqlite", ["indexes", "views"], ["create", "get", "list", "delete"]),
        ("git", ["stashes", "remotes", "tags"], ["create", "get", "list", "delete"]),
        ("playwright", ["console_messages", "network_requests"], ["get", "list"]),
        ("memory", ["observations_batch"], ["create", "get", "list", "delete"]),
        ("fetch", ["headers"], ["get"]),
        ("brave_search", ["news", "images"], ["search"]),
        ("time", ["timezones"], ["list", "get"]),
        ("sequential_thinking", ["revisions"], ["list"]),
        ("bitbucket", ["pipelines", "downloads", "snippets"], ["create", "get", "list", "delete"]),
    ]
    for server, resources, actions in families:
        for t in _expand_family(server, resources, actions, source="expanded"):
            if t["id"] not in seen:
                extras.append(t)
                seen.add(t["id"])
            if len(core) + len(extras) >= target:
                return core + extras[: target - len(core)]
    if len(core) + len(extras) < target:
        raise RuntimeError(f"only produced {len(core)+len(extras)} tools, need {target}")
    return core + extras[: target - len(core)]


def build_catalog(n: int = 536) -> list[dict[str, Any]]:
    core = _real_core()
    # Dedup core by id, keep first.
    uniq = []
    seen = set()
    for t in core:
        if t["id"] in seen:
            continue
        seen.add(t["id"])
        uniq.append(t)
    return _pad_to_target(uniq, n)


DISTRACTOR_VENDORS = [
    "acme", "northstar", "globex", "initech", "umbrella", "wayne", "stark",
    "hooli", "piedpiper", "wonka", "oscorp", "cyberdyne", "tyrell", "weyland",
    "massive", "apex", "lumen", "nimbus", "cobalt", "aurora", "harbor",
    "ridge", "cinder", "quartz", "helium", "ion", "kestrel", "lynx", "otter",
    "puffin", "quail", "raven", "sable", "teal", "umbra", "velvet", "willow",
    "xenon", "yarrow", "zephyr",
]

DISTRACTOR_RESOURCES = [
    "issues", "tickets", "tasks", "messages", "comments", "users", "projects",
    "orders", "invoices", "customers", "files", "documents", "events",
    "alerts", "incidents", "deployments", "pipelines", "records", "items",
    "contacts", "leads", "candidates", "employees", "channels", "boards",
]


def build_distractors(count: int, seed: int = 20261020) -> list[dict[str, Any]]:
    rng = random.Random(seed)
    out = []
    i = 0
    while len(out) < count:
        vendor = DISTRACTOR_VENDORS[i % len(DISTRACTOR_VENDORS)]
        resource = DISTRACTOR_RESOURCES[(i // len(DISTRACTOR_VENDORS)) % len(DISTRACTOR_RESOURCES)]
        action = VERBS[i % len(VERBS)]
        suffix = i // (len(DISTRACTOR_VENDORS) * len(DISTRACTOR_RESOURCES) * len(VERBS))
        server = f"{vendor}_{suffix}" if suffix else vendor
        singular = resource[:-1] if resource.endswith("s") else resource
        name = f"{action}_{resource}" if action in ("list", "search") else f"{action}_{singular}"
        if suffix:
            name = f"{name}_{suffix}"
        desc = (
            f"{action.capitalize()} {resource.replace('_', ' ')} in the {vendor} "
            f"{singular} workspace. Supports the usual {action} workflow."
        )
        out.append(_tool(server, name, desc, ["id", "name", "query", "limit"], source="distractor"))
        i += 1
    return out


def _hand_queries() -> list[dict[str, Any]]:
    """Natural-language queries labelled against the reproduction catalog."""
    return [
        {"id": "q001", "query": "Create a GitHub issue", "gold": ["github.create_issue"], "alts": ["github.issue_write"], "kind": "verb_product"},
        {"id": "q002", "query": "Create a Jira ticket", "gold": ["jira.jira_create_issue"], "alts": [], "kind": "verb_product"},
        {"id": "q003", "query": "Send a Slack message", "gold": ["slack.slack_post_message"], "alts": [], "kind": "verb_product"},
        {"id": "q004", "query": "List open pull requests", "gold": ["github.list_pull_requests"], "alts": ["github.search_pull_requests"], "kind": "resource"},
        {"id": "q005", "query": "Open a pull request on GitHub", "gold": ["github.create_pull_request"], "alts": [], "kind": "verb_product"},
        {"id": "q006", "query": "Run a SQL query against postgres", "gold": ["postgres.query"], "alts": [], "kind": "verb_product"},
        {"id": "q007", "query": "Read a local file from disk", "gold": ["filesystem.read_file"], "alts": ["filesystem.read_text_file"], "kind": "paraphrase"},
        {"id": "q008", "query": "What files are in this folder", "gold": ["filesystem.list_directory"], "alts": ["filesystem.list_directory_with_sizes", "filesystem.directory_tree"], "kind": "paraphrase"},
        {"id": "q009", "query": "Remember this fact in the knowledge graph", "gold": ["memory.add_observations"], "alts": ["memory.create_entities"], "kind": "paraphrase"},
        {"id": "q010", "query": "Search the web with Brave", "gold": ["brave_search.brave_web_search"], "alts": [], "kind": "verb_product"},
        {"id": "q011", "query": "Fetch the contents of a URL", "gold": ["fetch.fetch"], "alts": [], "kind": "verb_product"},
        {"id": "q012", "query": "Show git status", "gold": ["git.git_status"], "alts": [], "kind": "identifier"},
        {"id": "q013", "query": "Commit staged changes", "gold": ["git.git_commit"], "alts": [], "kind": "paraphrase"},
        {"id": "q014", "query": "Create a Linear issue", "gold": ["linear.linear_create_issue"], "alts": [], "kind": "verb_product"},
        {"id": "q015", "query": "Make a task in my project tracker Linear", "gold": ["linear.linear_create_issue"], "alts": [], "kind": "paraphrase"},
        {"id": "q016", "query": "Post a comment on a GitHub issue", "gold": ["github.add_issue_comment"], "alts": [], "kind": "verb_product"},
        {"id": "q017", "query": "Merge the pull request", "gold": ["github.merge_pull_request"], "alts": ["gitlab.gitlab_merge_merge_request"], "kind": "ambiguous"},
        {"id": "q018", "query": "Trigger a GitHub Actions workflow", "gold": ["github.actions_run_trigger"], "alts": [], "kind": "verb_product"},
        {"id": "q019", "query": "Get Dependabot alerts", "gold": ["github.list_dependabot_alerts"], "alts": ["github.get_dependabot_alert"], "kind": "resource"},
        {"id": "q020", "query": "List Sentry issues", "gold": ["sentry.sentry_list_issues"], "alts": [], "kind": "verb_product"},
        {"id": "q021", "query": "Create a Stripe customer", "gold": ["stripe.stripe_create_customer"], "alts": [], "kind": "verb_product"},
        {"id": "q022", "query": "Refund a Stripe payment", "gold": ["stripe.stripe_create_refund"], "alts": [], "kind": "paraphrase"},
        {"id": "q023", "query": "Send an email with Gmail", "gold": ["gmail.gmail_send_email"], "alts": [], "kind": "verb_product"},
        {"id": "q024", "query": "Search my Gmail inbox", "gold": ["gmail.gmail_search_emails"], "alts": [], "kind": "verb_product"},
        {"id": "q025", "query": "Upload a file to Google Drive", "gold": ["google_drive.gdrive_create_file"], "alts": [], "kind": "paraphrase"},
        {"id": "q026", "query": "Create a calendar event", "gold": ["google_calendar.gcal_create_event"], "alts": [], "kind": "resource"},
        {"id": "q027", "query": "List Kubernetes pods", "gold": ["kubernetes.k8s_list_pods"], "alts": [], "kind": "verb_product"},
        {"id": "q028", "query": "Get logs from a k8s pod", "gold": ["kubernetes.k8s_pod_logs"], "alts": [], "kind": "verb_product"},
        {"id": "q029", "query": "Run a docker container", "gold": ["docker.docker_run"], "alts": [], "kind": "verb_product"},
        {"id": "q030", "query": "Show docker container logs", "gold": ["docker.docker_logs"], "alts": [], "kind": "verb_product"},
        {"id": "q031", "query": "Navigate the browser to a URL", "gold": ["playwright.browser_navigate"], "alts": ["puppeteer.puppeteer_navigate"], "kind": "ambiguous"},
        {"id": "q032", "query": "Take a screenshot of the page", "gold": ["playwright.browser_take_screenshot"], "alts": ["puppeteer.puppeteer_screenshot"], "kind": "ambiguous"},
        {"id": "q033", "query": "Create a GitLab merge request", "gold": ["gitlab.gitlab_create_merge_request"], "alts": [], "kind": "verb_product"},
        {"id": "q034", "query": "Search Notion pages", "gold": ["notion.notion_search"], "alts": [], "kind": "verb_product"},
        {"id": "q035", "query": "Create a Notion page", "gold": ["notion.notion_create_page"], "alts": [], "kind": "verb_product"},
        {"id": "q036", "query": "Query a Notion database", "gold": ["notion.notion_query_database"], "alts": [], "kind": "verb_product"},
        {"id": "q037", "query": "Create a Zendesk ticket", "gold": ["zendesk.zendesk_create_ticket"], "alts": [], "kind": "verb_product"},
        {"id": "q038", "query": "Create a HubSpot contact", "gold": ["hubspot.hubspot_create_contact"], "alts": [], "kind": "verb_product"},
        {"id": "q039", "query": "Create a Salesforce lead", "gold": ["salesforce.salesforce_create_lead"], "alts": [], "kind": "verb_product"},
        {"id": "q040", "query": "Run a SOQL query", "gold": ["salesforce.salesforce_query"], "alts": [], "kind": "identifier"},
        {"id": "q041", "query": "List Shopify orders", "gold": ["shopify.shopify_list_orders"], "alts": [], "kind": "verb_product"},
        {"id": "q042", "query": "Create a PagerDuty incident", "gold": ["pagerduty.pagerduty_create_incident"], "alts": [], "kind": "verb_product"},
        {"id": "q043", "query": "Who is on call in PagerDuty", "gold": ["pagerduty.pagerduty_list_oncalls"], "alts": [], "kind": "paraphrase"},
        {"id": "q044", "query": "Query Datadog metrics", "gold": ["datadog.datadog_query_metrics"], "alts": [], "kind": "verb_product"},
        {"id": "q045", "query": "Search Datadog logs", "gold": ["datadog.datadog_list_logs"], "alts": [], "kind": "verb_product"},
        {"id": "q046", "query": "List S3 buckets", "gold": ["aws_s3.s3_list_buckets"], "alts": [], "kind": "verb_product"},
        {"id": "q047", "query": "Upload an object to S3", "gold": ["aws_s3.s3_put_object"], "alts": [], "kind": "paraphrase"},
        {"id": "q048", "query": "Purge Cloudflare cache", "gold": ["cloudflare.cf_purge_cache"], "alts": [], "kind": "verb_product"},
        {"id": "q049", "query": "Create a Cloudflare DNS record", "gold": ["cloudflare.cf_create_dns"], "alts": [], "kind": "verb_product"},
        {"id": "q050", "query": "List Vercel deployments", "gold": ["vercel.vercel_list_deployments"], "alts": [], "kind": "verb_product"},
        {"id": "q051", "query": "Insert a row into Supabase", "gold": ["supabase.supabase_insert"], "alts": [], "kind": "verb_product"},
        {"id": "q052", "query": "Export images from Figma", "gold": ["figma.figma_get_images"], "alts": [], "kind": "paraphrase"},
        {"id": "q053", "query": "Send an SMS with Twilio", "gold": ["twilio.twilio_send_sms"], "alts": [], "kind": "verb_product"},
        {"id": "q054", "query": "Create an Okta user", "gold": ["okta.okta_create_user"], "alts": [], "kind": "verb_product"},
        {"id": "q055", "query": "Instant query Prometheus", "gold": ["prometheus.prom_query"], "alts": [], "kind": "verb_product"},
        {"id": "q056", "query": "Search Grafana dashboards", "gold": ["grafana.grafana_search_dashboards"], "alts": [], "kind": "verb_product"},
        {"id": "q057", "query": "Trigger a CircleCI pipeline", "gold": ["circleci.circleci_trigger_pipeline"], "alts": [], "kind": "verb_product"},
        {"id": "q058", "query": "Run terraform plan", "gold": ["terraform.tf_plan"], "alts": [], "kind": "identifier"},
        {"id": "q059", "query": "Create an Asana task", "gold": ["asana.asana_create_task"], "alts": [], "kind": "verb_product"},
        {"id": "q060", "query": "Create a Trello card", "gold": ["trello.trello_create_card"], "alts": [], "kind": "verb_product"},
        {"id": "q061", "query": "Create a ClickUp task", "gold": ["clickup.clickup_create_task"], "alts": [], "kind": "verb_product"},
        {"id": "q062", "query": "Create a Confluence page", "gold": ["confluence.confluence_create_page"], "alts": [], "kind": "verb_product"},
        {"id": "q063", "query": "Send a Discord message", "gold": ["discord.discord_send_message"], "alts": [], "kind": "verb_product"},
        {"id": "q064", "query": "Search Elasticsearch", "gold": ["elasticsearch.es_search"], "alts": [], "kind": "verb_product"},
        {"id": "q065", "query": "Get a Redis key", "gold": ["redis.redis_get"], "alts": [], "kind": "verb_product"},
        {"id": "q066", "query": "Find MongoDB documents", "gold": ["mongodb.mongo_find"], "alts": [], "kind": "verb_product"},
        {"id": "q067", "query": "List SQLite tables", "gold": ["sqlite.sqlite_list_tables"], "alts": [], "kind": "verb_product"},
        {"id": "q068", "query": "Describe a postgres table", "gold": ["postgres.describe_table"], "alts": [], "kind": "verb_product"},
        {"id": "q069", "query": "github_create_issue", "gold": ["github.create_issue"], "alts": ["github.issue_write"], "kind": "identifier"},
        {"id": "q070", "query": "createIssue", "gold": ["github.create_issue"], "alts": ["jira.jira_create_issue", "linear.linear_create_issue"], "kind": "identifier"},
        {"id": "q071", "query": "list-directory", "gold": ["filesystem.list_directory"], "alts": [], "kind": "identifier"},
        {"id": "q072", "query": "sequential thinking next thought", "gold": ["sequential_thinking.sequentialthinking"], "alts": [], "kind": "paraphrase"},
        {"id": "q073", "query": "What time is it in Tokyo", "gold": ["time.get_current_time"], "alts": ["time.convert_time"], "kind": "paraphrase"},
        {"id": "q074", "query": "Convert time between timezones", "gold": ["time.convert_time"], "alts": [], "kind": "verb_product"},
        {"id": "q075", "query": "Star a GitHub repo", "gold": ["github.star_repository"], "alts": [], "kind": "verb_product"},
        {"id": "q076", "query": "Fork a repository", "gold": ["github.fork_repository"], "alts": [], "kind": "resource"},
        {"id": "q077", "query": "Get the latest GitHub release", "gold": ["github.get_latest_release"], "alts": [], "kind": "verb_product"},
        {"id": "q078", "query": "Create a gist", "gold": ["github.create_gist"], "alts": [], "kind": "resource"},
        {"id": "q079", "query": "Search GitHub code", "gold": ["github.search_code"], "alts": [], "kind": "verb_product"},
        {"id": "q080", "query": "List GitHub notifications", "gold": ["github.list_notifications"], "alts": [], "kind": "verb_product"},
        {"id": "q081", "query": "Assign Copilot to an issue", "gold": ["github.assign_copilot_to_issue"], "alts": [], "kind": "verb_product"},
        {"id": "q082", "query": "Get secret scanning alerts", "gold": ["github.list_secret_scanning_alerts"], "alts": ["github.get_secret_scanning_alert"], "kind": "resource"},
        {"id": "q083", "query": "Create or update a file on GitHub", "gold": ["github.create_or_update_file"], "alts": ["github.push_files"], "kind": "verb_product"},
        {"id": "q084", "query": "List collaborators on a repo", "gold": ["github.list_repository_collaborators"], "alts": [], "kind": "resource"},
        {"id": "q085", "query": "Reply in a Slack thread", "gold": ["slack.slack_reply_to_thread"], "alts": [], "kind": "verb_product"},
        {"id": "q086", "query": "Add an emoji reaction on Slack", "gold": ["slack.slack_add_reaction"], "alts": ["discord.discord_add_reaction"], "kind": "verb_product"},
        {"id": "q087", "query": "Search Slack messages", "gold": ["slack.slack_search_messages"], "alts": [], "kind": "verb_product"},
        {"id": "q088", "query": "Create a Slack channel", "gold": ["slack.slack_create_channel"], "alts": [], "kind": "verb_product"},
        {"id": "q089", "query": "Transition a Jira issue", "gold": ["jira.jira_transition_issue"], "alts": [], "kind": "verb_product"},
        {"id": "q090", "query": "Search Jira with JQL", "gold": ["jira.jira_search_issues"], "alts": [], "kind": "identifier"},
        {"id": "q091", "query": "Add a worklog to Jira", "gold": ["jira.jira_add_worklog"], "alts": [], "kind": "verb_product"},
        {"id": "q092", "query": "List Linear teams", "gold": ["linear.linear_list_teams"], "alts": [], "kind": "verb_product"},
        {"id": "q093", "query": "Comment on a Linear issue", "gold": ["linear.linear_create_comment"], "alts": [], "kind": "verb_product"},
        {"id": "q094", "query": "Move a local file", "gold": ["filesystem.move_file"], "alts": [], "kind": "paraphrase"},
        {"id": "q095", "query": "Recursively search files by pattern", "gold": ["filesystem.search_files"], "alts": [], "kind": "paraphrase"},
        {"id": "q096", "query": "Edit a file in place with old and new string", "gold": ["filesystem.edit_file"], "alts": [], "kind": "paraphrase"},
        {"id": "q097", "query": "Read the whole knowledge graph", "gold": ["memory.read_graph"], "alts": [], "kind": "paraphrase"},
        {"id": "q098", "query": "Search memory nodes", "gold": ["memory.search_nodes"], "alts": [], "kind": "verb_product"},
        {"id": "q099", "query": "Show unstaged git diff", "gold": ["git.git_diff_unstaged"], "alts": [], "kind": "verb_product"},
        {"id": "q100", "query": "Stage files with git add", "gold": ["git.git_add"], "alts": [], "kind": "identifier"},
        {"id": "q101", "query": "Create a Shopify product", "gold": ["shopify.shopify_create_product"], "alts": [], "kind": "verb_product"},
        {"id": "q102", "query": "Cancel a Stripe subscription", "gold": ["stripe.stripe_cancel_subscription"], "alts": [], "kind": "verb_product"},
        {"id": "q103", "query": "Create a payment intent", "gold": ["stripe.stripe_create_payment_intent"], "alts": [], "kind": "resource"},
        {"id": "q104", "query": "Acknowledge a PagerDuty incident", "gold": ["pagerduty.pagerduty_acknowledge_incident"], "alts": [], "kind": "verb_product"},
        {"id": "q105", "query": "Create a Datadog monitor", "gold": ["datadog.datadog_create_monitor"], "alts": [], "kind": "verb_product"},
        {"id": "q106", "query": "Resolve a Sentry issue", "gold": ["sentry.sentry_update_issue"], "alts": [], "kind": "paraphrase"},
        {"id": "q107", "query": "Scale a Kubernetes deployment", "gold": ["kubernetes.k8s_scale_deployment"], "alts": [], "kind": "verb_product"},
        {"id": "q108", "query": "Apply a Kubernetes manifest", "gold": ["kubernetes.k8s_apply"], "alts": [], "kind": "verb_product"},
        {"id": "q109", "query": "Stop a docker container", "gold": ["docker.docker_stop"], "alts": [], "kind": "verb_product"},
        {"id": "q110", "query": "Build a docker image", "gold": ["docker.docker_build"], "alts": [], "kind": "verb_product"},
        {"id": "q111", "query": "Click an element in Playwright", "gold": ["playwright.browser_click"], "alts": [], "kind": "verb_product"},
        {"id": "q112", "query": "Type text into a browser input", "gold": ["playwright.browser_type"], "alts": ["puppeteer.puppeteer_fill"], "kind": "paraphrase"},
        {"id": "q113", "query": "List GitLab projects", "gold": ["gitlab.gitlab_list_projects"], "alts": [], "kind": "verb_product"},
        {"id": "q114", "query": "Create a Bitbucket pull request", "gold": ["bitbucket.bitbucket_create_pr"], "alts": [], "kind": "verb_product"},
        {"id": "q115", "query": "Create a Gmail draft", "gold": ["gmail.gmail_create_draft"], "alts": [], "kind": "verb_product"},
        {"id": "q116", "query": "Share a Google Drive file", "gold": ["google_drive.gdrive_share_file"], "alts": [], "kind": "verb_product"},
        {"id": "q117", "query": "List Google Calendar events", "gold": ["google_calendar.gcal_list_events"], "alts": [], "kind": "verb_product"},
        {"id": "q118", "query": "Delete a calendar event", "gold": ["google_calendar.gcal_delete_event"], "alts": [], "kind": "resource"},
        {"id": "q119", "query": "List Vercel projects", "gold": ["vercel.vercel_list_projects"], "alts": [], "kind": "verb_product"},
        {"id": "q120", "query": "Select rows from Supabase", "gold": ["supabase.supabase_select"], "alts": [], "kind": "verb_product"},
        {"id": "q121", "query": "Post a Figma comment", "gold": ["figma.figma_post_comment"], "alts": [], "kind": "verb_product"},
        {"id": "q122", "query": "List Okta users", "gold": ["okta.okta_list_users"], "alts": [], "kind": "verb_product"},
        {"id": "q123", "query": "Range query Prometheus", "gold": ["prometheus.prom_query_range"], "alts": [], "kind": "verb_product"},
        {"id": "q124", "query": "Create a Grafana annotation", "gold": ["grafana.grafana_create_annotation"], "alts": [], "kind": "verb_product"},
        {"id": "q125", "query": "Apply terraform", "gold": ["terraform.tf_apply"], "alts": [], "kind": "identifier"},
        {"id": "q126", "query": "List Asana tasks", "gold": ["asana.asana_list_tasks"], "alts": [], "kind": "verb_product"},
        {"id": "q127", "query": "Comment on a Trello card", "gold": ["trello.trello_add_comment"], "alts": [], "kind": "verb_product"},
        {"id": "q128", "query": "Update a ClickUp task", "gold": ["clickup.clickup_update_task"], "alts": [], "kind": "verb_product"},
        {"id": "q129", "query": "Search Confluence", "gold": ["confluence.confluence_search"], "alts": [], "kind": "verb_product"},
        {"id": "q130", "query": "Create a HubSpot deal", "gold": ["hubspot.hubspot_create_deal"], "alts": [], "kind": "verb_product"},
        {"id": "q131", "query": "List Zendesk tickets", "gold": ["zendesk.zendesk_list_tickets"], "alts": [], "kind": "verb_product"},
        {"id": "q132", "query": "List Discord channels", "gold": ["discord.discord_list_channels"], "alts": [], "kind": "verb_product"},
        {"id": "q133", "query": "Set a Redis key", "gold": ["redis.redis_set"], "alts": [], "kind": "verb_product"},
        {"id": "q134", "query": "Insert MongoDB documents", "gold": ["mongodb.mongo_insert"], "alts": [], "kind": "verb_product"},
        {"id": "q135", "query": "Run a MySQL query", "gold": ["mysql.mysql_query"], "alts": [], "kind": "verb_product"},
        {"id": "q136", "query": "Index a document in Elasticsearch", "gold": ["elasticsearch.es_index_doc"], "alts": [], "kind": "verb_product"},
        {"id": "q137", "query": "Get an S3 object", "gold": ["aws_s3.s3_get_object"], "alts": [], "kind": "verb_product"},
        {"id": "q138", "query": "List Cloudflare zones", "gold": ["cloudflare.cf_list_zones"], "alts": [], "kind": "verb_product"},
        {"id": "q139", "query": "Create a Stripe invoice", "gold": ["stripe.stripe_create_invoice"], "alts": [], "kind": "verb_product"},
        {"id": "q140", "query": "List GitHub Actions workflows", "gold": ["github.actions_list"], "alts": [], "kind": "verb_product"},
        {"id": "q141", "query": "Get GitHub Actions job logs", "gold": ["github.actions_get_job_logs"], "alts": [], "kind": "verb_product"},
        {"id": "q142", "query": "Create a GitHub repository", "gold": ["github.create_repository"], "alts": [], "kind": "verb_product"},
        {"id": "q143", "query": "Checkout a git branch", "gold": ["git.git_checkout"], "alts": [], "kind": "verb_product"},
        {"id": "q144", "query": "Show git log", "gold": ["git.git_log"], "alts": [], "kind": "identifier"},
        {"id": "q145", "query": "List postgres schemas", "gold": ["postgres.list_schemas"], "alts": [], "kind": "verb_product"},
        {"id": "q146", "query": "Open nodes in the knowledge graph", "gold": ["memory.open_nodes"], "alts": [], "kind": "verb_product"},
        {"id": "q147", "query": "Get file metadata from the filesystem", "gold": ["filesystem.get_file_info"], "alts": [], "kind": "paraphrase"},
        {"id": "q148", "query": "Write a new local file", "gold": ["filesystem.write_file"], "alts": [], "kind": "paraphrase"},
        {"id": "q149", "query": "Search GitHub issues", "gold": ["github.search_issues"], "alts": [], "kind": "verb_product"},
        {"id": "q150", "query": "Get the authenticated GitHub user", "gold": ["github.get_me"], "alts": [], "kind": "paraphrase"},
    ]


def build_queries(tools: list[dict[str, Any]]) -> list[dict[str, Any]]:
    ids = {t["id"] for t in tools}
    queries = []
    missing = []
    for q in _hand_queries():
        gold = [g for g in q["gold"] if g in ids]
        alts = [a for a in q.get("alts", []) if a in ids]
        if not gold:
            missing.append(q["id"] + ":" + ",".join(q["gold"]))
            continue
        queries.append({**q, "gold": gold, "alts": alts})
    if missing:
        raise RuntimeError("gold tools missing from catalog: " + "; ".join(missing))
    if len(queries) != 150:
        raise RuntimeError(f"expected 150 queries, got {len(queries)}")
    return queries


def tool_document(t: dict[str, Any]) -> str:
    params = " ".join(t.get("params") or [])
    return (
        f"server {t['server']}\n"
        f"name {t['name']}\n"
        f"tool {t['id']}\n"
        f"{t['description']}\n"
        f"params {params}\n"
    )


def materialize_codedb_corpus(tools: list[dict[str, Any]], dest: Path) -> Path:
    """One Python file per tool so codedb can index name/desc/params/server."""
    dest.mkdir(parents=True, exist_ok=True)
    for existing in dest.glob("*.py"):
        existing.unlink()
    id_map: dict[str, str] = {}
    for t in tools:
        safe = f"{t['server']}__{t['name']}"
        safe = re.sub(r"[^a-zA-Z0-9_]+", "_", safe)
        path = dest / f"{safe}.py"
        id_map[f"{safe}.py"] = t["id"]
        params = t.get("params") or []
        sig = ", ".join(f"{p}: str = ''" for p in params) or ""
        path.write_text(
            f'"""{t["description"]}\n\n'
            f'Server: {t["server"]}\n'
            f'Tool: {t["name"]}\n'
            f'Id: {t["id"]}\n'
            f'Params: {" ".join(params)}\n'
            f'"""\n\n'
            f"def {t['name']}({sig}):\n"
            f'    """{t["description"]} ({t["server"]})"""\n'
            f"    return {t['id']!r}\n",
            encoding="utf-8",
        )
    (dest / "id_map.json").write_text(json.dumps(id_map, indent=2) + "\n", encoding="utf-8")
    return dest


def write_frozen(tools: list[dict[str, Any]], queries: list[dict[str, Any]]) -> None:
    DATA.mkdir(parents=True, exist_ok=True)
    (DATA / "catalog.json").write_text(json.dumps(tools, indent=2) + "\n", encoding="utf-8")
    (DATA / "queries.json").write_text(json.dumps(queries, indent=2) + "\n", encoding="utf-8")
    stats = {
        "n_tools": len(tools),
        "n_queries": len(queries),
        "n_servers": len({t["server"] for t in tools}),
        "by_source": {},
        "reproduction": True,
        "zed_fixtures_public": False,
    }
    for t in tools:
        stats["by_source"][t["source"]] = stats["by_source"].get(t["source"], 0) + 1
    (DATA / "catalog_stats.json").write_text(json.dumps(stats, indent=2) + "\n", encoding="utf-8")


def load_frozen() -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    tools = json.loads((DATA / "catalog.json").read_text(encoding="utf-8"))
    queries = json.loads((DATA / "queries.json").read_text(encoding="utf-8"))
    return tools, queries


if __name__ == "__main__":
    tools = build_catalog(536)
    queries = build_queries(tools)
    write_frozen(tools, queries)
    print(f"wrote {len(tools)} tools, {len(queries)} queries")
