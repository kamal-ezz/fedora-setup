import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { Editor } from "@earendil-works/pi-tui";

const CLIPBOARD_IMAGE_PATH_REGEX = /\/tmp\/pi-clipboard-[0-9a-f-]+(?:\.[a-z0-9]*)?/gi;
const PASTE_MARKER_REGEX = /\[paste #(\d+)(?: ((?:\+\d+ lines|\d+ chars)))?\]/gi;
const RENDER_PATCH_SYMBOL = Symbol.for("pi.extension.compactClipboardRendering.originalRender");
const INPUT_PATCH_SYMBOL = Symbol.for("pi.extension.compactClipboardRendering.originalHandleInput");

type EditorState = {
  lines: string[];
  cursorLine: number;
  cursorCol: number;
};

type PatchedEditorPrototype = typeof Editor.prototype & {
  [RENDER_PATCH_SYMBOL]?: (width: number) => string[];
  [INPUT_PATCH_SYMBOL]?: (data: string) => void;
};

type CursorMatch = { start: number; end: number; text: string };

function containsCompactableClipboardContent(line: string): boolean {
  CLIPBOARD_IMAGE_PATH_REGEX.lastIndex = 0;
  PASTE_MARKER_REGEX.lastIndex = 0;
  return CLIPBOARD_IMAGE_PATH_REGEX.test(line) || PASTE_MARKER_REGEX.test(line);
}

function formatPasteLabel(id: string, suffix?: string): string {
  return `[Pasted text #${id}${suffix ? ` ${suffix}` : ""}]`;
}

function findMatchAtCursor(
  line: string,
  cursorCol: number,
  direction: "backward" | "forward",
  regexes: RegExp[],
): CursorMatch | undefined {
  for (const regex of regexes) {
    regex.lastIndex = 0;
    for (const match of line.matchAll(regex)) {
      const text = match[0];
      const start = match.index ?? 0;
      const end = start + text.length;

      if (direction === "backward" && cursorCol > start && cursorCol <= end) {
        return { start, end, text };
      }

      if (direction === "forward" && cursorCol >= start && cursorCol < end) {
        return { start, end, text };
      }
    }
  }

  return undefined;
}

function deleteCompactClipboardContentAtCursor(editor: any, direction: "backward" | "forward"): boolean {
  const state = editor.state as EditorState | undefined;
  if (!state) return false;

  const line = state.lines[state.cursorLine] ?? "";
  const match = findMatchAtCursor(line, state.cursorCol, direction, [CLIPBOARD_IMAGE_PATH_REGEX, PASTE_MARKER_REGEX]);
  if (!match) return false;

  editor.cancelAutocomplete?.();
  editor.pushUndoSnapshot?.();
  editor.historyIndex = -1;
  editor.lastAction = null;

  state.lines[state.cursorLine] = line.slice(0, match.start) + line.slice(match.end);
  state.cursorCol = match.start;
  editor.onChange?.(editor.getText());
  return true;
}

function compactLine(line: string, imageIndexRef: { value: number }) {
  CLIPBOARD_IMAGE_PATH_REGEX.lastIndex = 0;
  PASTE_MARKER_REGEX.lastIndex = 0;

  return line
    .replace(CLIPBOARD_IMAGE_PATH_REGEX, () => {
      imageIndexRef.value += 1;
      return `[Image #${imageIndexRef.value}]`;
    })
    .replace(PASTE_MARKER_REGEX, (_match, id: string, suffix?: string) => formatPasteLabel(id, suffix));
}

function compactClipboardContent(lines: string[], cursorLine: number, cursorCol: number) {
  const imageIndexRef = { value: 0 };
  let adjustedCursorCol = cursorCol;

  const compactLines = lines.map((line, lineIndex) => {
    if (lineIndex === cursorLine) {
      // Cursor mapping is easiest and robust enough by compacting only the text before the cursor.
      adjustedCursorCol = compactLine(line.slice(0, cursorCol), { value: imageIndexRef.value }).length;
    }

    return compactLine(line, imageIndexRef);
  });

  return { compactLines, adjustedCursorCol };
}

function installCompactClipboardRendering() {
  const proto = Editor.prototype as PatchedEditorPrototype;

  // Survive /reload without stacking wrapper-on-wrapper patches.
  if (proto[RENDER_PATCH_SYMBOL]) return;

  const originalRender = proto.render;
  proto[RENDER_PATCH_SYMBOL] = originalRender;

  proto.render = function renderWithCompactClipboardContent(width: number) {
    const state = (this as unknown as { state?: EditorState }).state;

    if (!state?.lines?.some(containsCompactableClipboardContent)) {
      return originalRender.call(this, width);
    }

    const originalLines = state.lines;
    const originalCursorCol = state.cursorCol;
    const { compactLines, adjustedCursorCol } = compactClipboardContent(
      originalLines,
      state.cursorLine,
      originalCursorCol,
    );

    state.lines = compactLines;
    state.cursorCol = adjustedCursorCol;

    try {
      return originalRender.call(this, width);
    } finally {
      // Rendering is visual only. Keep real /tmp image paths and paste markers in editor state
      // so submit, history, and model input still receive the actual content.
      state.lines = originalLines;
      state.cursorCol = originalCursorCol;
    }
  };
}

function installCompactClipboardDeletion() {
  const proto = Editor.prototype as PatchedEditorPrototype;
  if (proto[INPUT_PATCH_SYMBOL]) return;

  const originalHandleInput = proto.handleInput;
  proto[INPUT_PATCH_SYMBOL] = originalHandleInput;

  proto.handleInput = function handleInputWithCompactClipboardDeletion(data: string) {
    if ((data === "\x7f" || data === "\b") && deleteCompactClipboardContentAtCursor(this, "backward")) {
      return;
    }

    if (data === "\x1b[3~" && deleteCompactClipboardContentAtCursor(this, "forward")) {
      return;
    }

    return originalHandleInput.call(this, data);
  };
}

export default function (_pi: ExtensionAPI) {
  installCompactClipboardRendering();
  installCompactClipboardDeletion();
}
