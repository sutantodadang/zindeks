#!/usr/bin/env node
"use strict";

const fs = require("fs");

const host = getArg("--host") || "cursor";
const input = readJson();
const command = extractCommand(input);
const decision = decide(command);

if (host === "claude") {
  writeClaude(decision);
} else {
  writeCursor(decision);
}

function getArg(name) {
  const prefix = `${name}=`;
  for (let i = 2; i < process.argv.length; i += 1) {
    if (process.argv[i] === name) return process.argv[i + 1] || "";
    if (process.argv[i].startsWith(prefix)) return process.argv[i].slice(prefix.length);
  }
  return "";
}

function readJson() {
  const raw = fs.readFileSync(0, "utf8").trim();
  if (!raw) return {};
  try {
    return JSON.parse(raw);
  } catch (_) {
    return {};
  }
}

function extractCommand(value) {
  if (typeof value === "string") return value;
  if (!value || typeof value !== "object") return "";

  const candidates = [
    value.command,
    value.cmd,
    value.shellCommand,
    value.tool_input && value.tool_input.command,
    value.tool_input && value.tool_input.cmd,
    value.toolInput && value.toolInput.command,
    value.args && value.args.command,
  ];

  for (const candidate of candidates) {
    if (typeof candidate === "string" && candidate.trim()) return candidate;
  }
  return "";
}

function decide(command) {
  if (!command || invokesZindeks(command)) return allow();
  if (!usesBroadShellSearch(command)) return allow();

  return ask(
    "Use zindeks before broad shell search. Try `zindeks search \"<query>\"` or the zindeks MCP search/graph tools first; then retry the shell search if zindeks is insufficient."
  );
}

function invokesZindeks(command) {
  const normalized = command.replace(/\\/g, "/");
  return /(^|[\s;&|('"`])(?:rtk\s+)?(?:[A-Za-z]:)?(?:\.{0,2}\/)?(?:[^\s;&|('"`]+\/)?zindeks(?:\.exe)?(?=$|[\s;&|)'"`])/i.test(normalized);
}

function usesBroadShellSearch(command) {
  const c = command.trim();
  const patterns = [
    /\bgit\s+grep\b/i,
    /(^|[\s;&|('"`])grep(?=$|[\s;&|)'"`])/i,
    /(^|[\s;&|('"`])rg(?=$|[\s;&|)'"`])/i,
    /(^|[\s;&|('"`])findstr(?=$|[\s;&|)'"`])/i,
    /(^|[\s;&|('"`])select-string(?=$|[\s;&|)'"`])/i,
    /(^|[\s;&|('"`])(?:get-childitem|gci)(?=[\s;&|)'"`]|$).*?(?:\s-(?:recurse|r)\b|\s\/recurse\b)/i,
    /(^|[\s;&|('"`])dir\s+\/s\b/i,
  ];
  return patterns.some((pattern) => pattern.test(c));
}

function allow() {
  return { permission: "allow" };
}

function ask(message) {
  return { permission: "ask", message };
}

function writeCursor(result) {
  if (result.permission === "allow") {
    process.stdout.write(JSON.stringify({ permission: "allow" }));
    return;
  }
  process.stdout.write(JSON.stringify({
    permission: result.permission,
    user_message: result.message,
    agent_message: result.message,
  }));
}

function writeClaude(result) {
  if (result.permission === "allow") {
    process.stdout.write(JSON.stringify({
      hookSpecificOutput: {
        hookEventName: "PreToolUse",
        permissionDecision: "allow",
      },
    }));
    return;
  }
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: result.permission,
    },
    systemMessage: result.message,
  }));
}
