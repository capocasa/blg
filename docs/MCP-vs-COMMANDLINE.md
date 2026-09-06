# Why blg is a command line tool, not an MCP server

## What is MCP?

Model Context Protocol (MCP) lets AI assistants call tools through a structured interface with typed parameters, tool discovery, and rich data types. It works inside MCP-capable hosts like Claude Code, Claude Desktop, and some editors.

## Why we chose the command line

A blog generator has a handful of simple commands: `new`, `build`, `publish`. There are no complex queries, no rich data types, no need for the AI to discover dozens of endpoints at runtime. MCP adds indirection without adding value here.

**CLI is strictly more portable.** It works everywhere MCP does (Claude Code just calls it via shell) plus everywhere MCP doesn't: scripts, cron jobs, CI pipelines, SSH sessions, non-AI workflows. An MCP-only tool locks you into AI host apps for no practical gain.

## When MCP makes sense

MCP earns its keep when there are many operations, complex data types, and tool discovery matters:

- **Databases** — 50 tables, the LLM introspects schemas and builds queries without knowing SQL
- **Messaging platforms** — channels, threads, attachments, dozens of operations
- **Cloud infrastructure** — hundreds of resource types to inspect and manage

A blog generator has none of these characteristics. It's a hammer, not a database.

## Summary

| | CLI | MCP |
|---|---|---|
| Works in AI tools | Yes | Yes |
| Works in scripts/cron/CI | Yes | No |
| Works over SSH | Yes | No |
| Needs a host app | No | Yes |
| Adds value for simple commands | Same | No extra benefit |
| Adds value for complex queries | Limited | Yes |

We chose the right tool for the job. If you can type `blg publish "My Post"`, you don't need a protocol to do it for you.
