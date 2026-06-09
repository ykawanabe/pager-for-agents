import { test, expect, describe } from "bun:test";
import { classify, isInsideMount, type ToolCall } from "./autonomy-policy";

const MOUNT = "/work/proj";
const call = (toolName: string, toolInput: Record<string, unknown> = {}, cwd = MOUNT): ToolCall =>
  ({ toolName, toolInput, cwd });
const bash = (command: string, cwd = MOUNT) => call("Bash", { command }, cwd);

describe("read-only tools", () => {
  for (const t of ["Read", "Glob", "Grep", "LS", "WebFetch", "WebSearch", "NotebookRead", "TodoWrite"]) {
    test(`${t} → silent`, () => expect(classify(call(t)).tier).toBe("silent"));
  }
});

describe("edit tools — in-mount silent, outside ask", () => {
  test("Edit inside mount (relative) → silent", () =>
    expect(classify(call("Edit", { file_path: "src/index.ts" })).tier).toBe("silent"));
  test("Edit inside mount (absolute) → silent", () =>
    expect(classify(call("Edit", { file_path: `${MOUNT}/src/a.ts` })).tier).toBe("silent"));
  test("Write inside mount → silent", () =>
    expect(classify(call("Write", { file_path: `${MOUNT}/new.txt` })).tier).toBe("silent"));
  test("Edit outside mount (absolute) → ask", () =>
    expect(classify(call("Edit", { file_path: "/etc/hosts" })).tier).toBe("ask"));
  test("Write to home (~) → ask", () =>
    expect(classify(call("Write", { file_path: "~/.zshrc" })).tier).toBe("ask"));
  test("Edit escaping mount via .. → ask", () =>
    expect(classify(call("Edit", { file_path: "../../etc/hosts" })).tier).toBe("ask"));
  test("MultiEdit inside → silent; NotebookEdit inside → silent", () => {
    expect(classify(call("MultiEdit", { file_path: `${MOUNT}/x.ts` })).tier).toBe("silent");
    expect(classify(call("NotebookEdit", { notebook_path: `${MOUNT}/n.ipynb` })).tier).toBe("silent");
  });
});

describe("bash — safe verbs silent", () => {
  for (const c of ["ls -la", "cat README.md", "rg TODO src", "bun test", "npm test", "tsc --noEmit", "jq . package.json", "echo hi", "pwd"]) {
    test(`'${c}' → silent`, () => expect(classify(bash(c)).tier).toBe("silent"));
  }
});

describe("bash — metacharacters never silent", () => {
  for (const c of ["echo hi && rm foo", "ls; cat /etc/passwd", "cat a | tee b", "echo $(whoami)", "echo `id`", "ls > out.txt", "ls &"]) {
    test(`'${c}' → not silent`, () => expect(classify(bash(c)).tier).not.toBe("silent"));
  }
  test("metachar without destructive token → ask", () =>
    expect(classify(bash("rg foo | head")).tier).toBe("ask"));
});

describe("bash — git/gh", () => {
  test("git status → silent", () => expect(classify(bash("git status")).tier).toBe("silent"));
  test("git diff → silent", () => expect(classify(bash("git diff HEAD")).tier).toBe("silent"));
  test("git add/commit → silent", () => {
    expect(classify(bash("git add -A")).tier).toBe("silent");
    expect(classify(bash("git commit -m wip")).tier).toBe("silent");
  });
  test("git push → ask (outward)", () => {
    const c = classify(bash("git push origin main"));
    expect(c.tier).toBe("ask");
    expect(c.reversibility).toBe("outward");
  });
  test("git reset --hard → ask", () => expect(classify(bash("git reset --hard HEAD~1")).tier).toBe("ask"));
  test("gh pr list → silent", () => expect(classify(bash("gh pr list")).tier).toBe("silent"));
  test("gh pr merge → ask", () => expect(classify(bash("gh pr merge 42")).tier).toBe("ask"));
  test("gh pr create → ask", () => expect(classify(bash("gh pr create --fill")).tier).toBe("ask"));
});

describe("bash — mutating / outward → ask", () => {
  for (const c of ["rm foo.txt", "mv a b", "cp x /tmp/y", "chmod +x s.sh", "curl https://x.com", "wget http://y", "npm publish"]) {
    test(`'${c}' → ask`, () => expect(classify(bash(c)).tier).toBe("ask"));
  }
});

describe("bash — destructive → deny", () => {
  for (const c of ["sudo rm -rf /", "rm -rf ~", "rm -rf $HOME", "mkfs.ext4 /dev/sda", "sudo reboot"]) {
    test(`'${c}' → deny`, () => expect(classify(bash(c)).tier).toBe("deny"));
  }
  test("fork bomb → deny", () => expect(classify(bash(":(){ :|:& };:")).tier).toBe("deny"));
});

describe("bash — unknown verb defaults to ask", () => {
  test("'frobnicate x' → ask", () => expect(classify(bash("frobnicate x")).tier).toBe("ask"));
  test("empty command → ask", () => expect(classify(call("Bash", {})).tier).toBe("ask"));
});

describe("MCP tools", () => {
  test("get/list/search → silent", () => {
    expect(classify(call("mcp__telegram-user__get_chat")).tier).toBe("silent");
    expect(classify(call("mcp__claude_ai_Gmail__search_threads")).tier).toBe("silent");
    expect(classify(call("mcp__withings__get_sleep")).tier).toBe("silent");
  });
  test("send/create/delete → ask (outward)", () => {
    expect(classify(call("mcp__telegram-user__send_message")).tier).toBe("ask");
    expect(classify(call("mcp__claude_ai_Gmail__create_draft")).tier).toBe("ask");
    expect(classify(call("mcp__claude_ai_Google_Calendar__create_event")).tier).toBe("ask");
    expect(classify(call("mcp__telegram-user__delete_message")).tier).toBe("ask");
  });
});

describe("subagent + unknown tools → ask", () => {
  test("Task → ask", () => expect(classify(call("Task")).tier).toBe("ask"));
  test("unknown tool → ask", () => expect(classify(call("SomeFutureTool")).tier).toBe("ask"));
});

describe("isInsideMount", () => {
  test("relative inside", () => expect(isInsideMount("src/a.ts", MOUNT)).toBe(true));
  test("absolute inside", () => expect(isInsideMount(`${MOUNT}/x`, MOUNT)).toBe(true));
  test("absolute outside", () => expect(isInsideMount("/etc/hosts", MOUNT)).toBe(false));
  test("traversal escape", () => expect(isInsideMount("../../../etc", MOUNT)).toBe(false));
  test("home tilde outside", () => expect(isInsideMount("~/secret", MOUNT)).toBe(false));
  test("sibling prefix not inside", () => expect(isInsideMount("/work/proj-evil/x", MOUNT)).toBe(false));
});
