import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Box, Text } from "@earendil-works/pi-tui";

interface DiffDetails {
  command: string;
  output: string;
  code: number;
  truncated: boolean;
}

function parseCommandArgs(input: string): string[] {
  const args: string[] = [];
  let current = "";
  let quote: '"' | "'" | undefined;
  let escaping = false;

  for (const char of input.trim()) {
    if (escaping) {
      current += char;
      escaping = false;
      continue;
    }

    if (char === "\\") {
      escaping = true;
      continue;
    }

    if (quote) {
      if (char === quote) quote = undefined;
      else current += char;
      continue;
    }

    if (char === '"' || char === "'") {
      quote = char;
      continue;
    }

    if (/\s/.test(char)) {
      if (current.length > 0) {
        args.push(current);
        current = "";
      }
      continue;
    }

    current += char;
  }

  if (escaping) current += "\\";
  if (current.length > 0) args.push(current);
  return args;
}

function createDiffDetails(args: string[], stdout: string, stderr: string, code: number): DiffDetails {
  const command = ["git", "diff", ...args].join(" ");
  const body = stdout.trimEnd() || stderr.trimEnd() || "No diff.";
  const truncated = body.length > 60000;

  return {
    command,
    output: truncated ? `${body.slice(0, 60000)}\n\n... truncated ...` : body,
    code,
    truncated,
  };
}

function renderDiffText(details: DiffDetails, theme: any): string {
  const lines = details.output.split("\n").map((line) => {
    if (line.startsWith("+")) return theme.fg("success", line);
    if (line.startsWith("-")) return theme.fg("error", line);
    if (line.startsWith("@@")) return theme.fg("accent", line);
    if (line.startsWith("diff --git") || line.startsWith("index ")) return theme.fg("muted", line);
    if (line.startsWith("---") || line.startsWith("+++")) return theme.fg("warning", line);
    return line;
  });

  const status = details.code === 0 ? theme.fg("success", "ok") : theme.fg("error", `exit ${details.code}`);
  const truncated = details.truncated ? theme.fg("warning", " · truncated") : "";

  return [
    `${theme.fg("accent", "▣ git diff")} ${theme.fg("muted", `$ ${details.command}`)} ${status}${truncated}`,
    "",
    ...lines,
  ].join("\n");
}

export default function (pi: ExtensionAPI) {
  pi.registerMessageRenderer<DiffDetails>("git-diff", (message, _options, theme) => {
    const details = message.details ?? {
      command: "git diff",
      output: String(message.content ?? ""),
      code: 0,
      truncated: false,
    };

    const box = new Box(1, 1, (text) => theme.bg("customMessageBg", text));
    box.addChild(new Text(renderDiffText(details, theme), 0, 0));
    return box;
  });

  pi.registerCommand("diff", {
    description: "Show git diff (usage: /diff [git diff args], /diff staged, /diff stat)",
    getArgumentCompletions: (prefix) => {
      const options = ["staged", "stat", "HEAD", "--cached", "--stat", "--name-only", "--name-status"];
      const normalized = prefix.trim().toLowerCase();
      return options
        .filter((option) => option.toLowerCase().startsWith(normalized))
        .map((option) => ({ value: option, label: option }));
    },
    handler: async (args, ctx) => {
      const parsed = parseCommandArgs(args);
      const diffArgs = parsed.flatMap((arg) => {
        if (arg === "staged" || arg === "cached") return ["--cached"];
        if (arg === "stat") return ["--stat"];
        return [arg];
      });

      const result = await pi.exec("git", ["diff", ...diffArgs], {
        cwd: ctx.cwd,
        signal: ctx.signal,
        timeout: 30000,
      });

      if (result.code === 0 && !result.stdout.trim() && !result.stderr.trim()) {
        ctx.ui.notify("No git diff.", "info");
        return;
      }

      const details = createDiffDetails(diffArgs, result.stdout, result.stderr, result.code);

      pi.sendMessage({
        customType: "git-diff",
        content: `${details.command}\n${details.output}`,
        display: true,
        details,
      });
    },
  });
}
