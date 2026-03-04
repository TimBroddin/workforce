export interface MouseEvent {
  button: "left" | "middle" | "right" | "release" | "wheel-up" | "wheel-down";
  x: number; // 1-indexed column
  y: number; // 1-indexed row
}

// SGR format: ESC [ < button ; x ; y M (press) or m (release)
const SGR_RE = /\x1b\[<(\d+);(\d+);(\d+)([Mm])/;

// X11 format: ESC [ M <3 bytes>
const X11_RE = /\x1b\[M([\s\S]{3})/;

export function parseMouseEvent(data: string): MouseEvent | null {
  // Try SGR first (more reliable, supports large coordinates)
  const sgr = SGR_RE.exec(data);
  if (sgr) {
    const code = parseInt(sgr[1], 10);
    const x = parseInt(sgr[2], 10);
    const y = parseInt(sgr[3], 10);
    const isRelease = sgr[4] === "m";

    if (isRelease) return { button: "release", x, y };

    const isWheel = !!(code & 64);
    if (isWheel) {
      return { button: code & 1 ? "wheel-down" : "wheel-up", x, y };
    }

    const base = code & 3;
    const button = base === 0 ? "left" : base === 1 ? "middle" : base === 2 ? "right" : "release";
    return { button, x, y };
  }

  // Fallback: X11 format
  const x11 = X11_RE.exec(data);
  if (x11) {
    const raw = x11[1];
    const code = raw.charCodeAt(0) - 32;
    const x = raw.charCodeAt(1) - 32;
    const y = raw.charCodeAt(2) - 32;

    const isWheel = !!(code & 64);
    if (isWheel) {
      return { button: code & 1 ? "wheel-down" : "wheel-up", x, y };
    }

    const base = code & 3;
    const button = base === 0 ? "left" : base === 1 ? "middle" : base === 2 ? "right" : "release";
    return { button, x, y };
  }

  return null;
}

// Check if data starts with a mouse escape sequence
export function isMouseSequence(data: string): boolean {
  return SGR_RE.test(data) || X11_RE.test(data);
}
