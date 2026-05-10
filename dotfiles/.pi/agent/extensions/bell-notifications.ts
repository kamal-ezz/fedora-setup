import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const BELL_AFTER_MS = 10_000;
let terminalFocused = true;
let agentStartedAt: number | undefined;
let unsubscribeFocusInput: (() => void) | undefined;

function ringBellIfUnfocused() {
  if (process.stdout.isTTY && !terminalFocused) {
    process.stdout.write("\x07");
  }
}

export default function (pi: ExtensionAPI) {
  pi.on("session_start", (_event, ctx) => {
    terminalFocused = true;
    unsubscribeFocusInput?.();
    unsubscribeFocusInput = ctx.ui.onTerminalInput((data) => {
      if (data.includes("\x1b[I")) terminalFocused = true;
      if (data.includes("\x1b[O")) terminalFocused = false;
      return undefined;
    });

    // Enable terminal focus reporting. Terminals that do not support it ignore this.
    if (process.stdout.isTTY) process.stdout.write("\x1b[?1004h");
  });

  pi.on("session_shutdown", () => {
    unsubscribeFocusInput?.();
    unsubscribeFocusInput = undefined;
    if (process.stdout.isTTY) process.stdout.write("\x1b[?1004l");
  });

  pi.on("agent_start", () => {
    agentStartedAt = Date.now();
  });

  pi.on("agent_end", () => {
    const elapsed = agentStartedAt ? Date.now() - agentStartedAt : 0;
    agentStartedAt = undefined;
    if (elapsed >= BELL_AFTER_MS) {
      ringBellIfUnfocused();
    }
  });
}
