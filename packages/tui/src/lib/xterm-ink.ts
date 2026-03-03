import type { IBufferCell, Terminal } from "@xterm/headless";

/**
 * Extract visible lines from an xterm buffer as strings with ANSI escapes.
 * Returns an array of strings, one per row, for the visible viewport.
 *
 * Ink's <Text> component can render raw ANSI escape codes, so we preserve
 * foreground/background colors and text attributes (bold, italic, underline).
 */
export function extractBufferLines(terminal: Terminal, rows: number, cols: number): string[] {
  const buffer = terminal.buffer.active;
  const lines: string[] = [];

  for (let y = 0; y < rows; y++) {
    const line = buffer.getLine(y + buffer.viewportY);
    if (!line) {
      lines.push("");
      continue;
    }

    let str = "";
    let prevFg = -1;
    let prevBg = -1;
    let prevBold = false;
    let prevItalic = false;
    let prevUnderline = false;

    // Reuse a single cell object for performance
    const cell: IBufferCell = line.getCell(0)!;

    for (let x = 0; x < cols; x++) {
      line.getCell(x, cell);
      if (!cell) {
        str += " ";
        continue;
      }

      const fg = cell.getFgColor();
      const bg = cell.getBgColor();
      const bold = cell.isBold() !== 0;
      const italic = cell.isItalic() !== 0;
      const underline = cell.isUnderline() !== 0;

      // Emit ANSI reset + new attributes when they change
      if (fg !== prevFg || bg !== prevBg || bold !== prevBold || italic !== prevItalic || underline !== prevUnderline) {
        const codes: number[] = [0]; // reset
        if (bold) codes.push(1);
        if (italic) codes.push(3);
        if (underline) codes.push(4);

        // Foreground color
        if (cell.isFgPalette()) {
          if (fg < 8) {
            codes.push(30 + fg);
          } else if (fg < 16) {
            codes.push(90 + (fg - 8));
          } else {
            codes.push(38, 5, fg);
          }
        } else if (cell.isFgRGB()) {
          codes.push(38, 2, (fg >> 16) & 0xff, (fg >> 8) & 0xff, fg & 0xff);
        }

        // Background color
        if (cell.isBgPalette()) {
          if (bg < 8) {
            codes.push(40 + bg);
          } else if (bg < 16) {
            codes.push(100 + (bg - 8));
          } else {
            codes.push(48, 5, bg);
          }
        } else if (cell.isBgRGB()) {
          codes.push(48, 2, (bg >> 16) & 0xff, (bg >> 8) & 0xff, bg & 0xff);
        }

        str += `\x1b[${codes.join(";")}m`;
        prevFg = fg;
        prevBg = bg;
        prevBold = bold;
        prevItalic = italic;
        prevUnderline = underline;
      }

      str += cell.getChars() || " ";
    }

    str += "\x1b[0m"; // reset at end of line
    lines.push(str);
  }

  return lines;
}
