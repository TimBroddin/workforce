import { test, expect } from "bun:test";
import { parseMouseEvent, isMouseSequence } from "../src/lib/mouse";

test("parses SGR left click", () => {
  const event = parseMouseEvent("\x1b[<0;10;5M");
  expect(event).toEqual({ button: "left", x: 10, y: 5 });
});

test("parses SGR right click", () => {
  const event = parseMouseEvent("\x1b[<2;20;15M");
  expect(event).toEqual({ button: "right", x: 20, y: 15 });
});

test("parses SGR mouse release", () => {
  const event = parseMouseEvent("\x1b[<0;10;5m");
  expect(event).toEqual({ button: "release", x: 10, y: 5 });
});

test("parses SGR wheel up", () => {
  const event = parseMouseEvent("\x1b[<64;10;5M");
  expect(event).toEqual({ button: "wheel-up", x: 10, y: 5 });
});

test("parses SGR wheel down", () => {
  const event = parseMouseEvent("\x1b[<65;10;5M");
  expect(event).toEqual({ button: "wheel-down", x: 10, y: 5 });
});

test("parses X11 left click", () => {
  // X11: ESC [ M <button+32> <x+32> <y+32>
  const data = "\x1b[M" + String.fromCharCode(32, 42, 37); // button=0, x=10, y=5
  const event = parseMouseEvent(data);
  expect(event).toEqual({ button: "left", x: 10, y: 5 });
});

test("isMouseSequence detects SGR", () => {
  expect(isMouseSequence("\x1b[<0;10;5M")).toBe(true);
  expect(isMouseSequence("\x1b[<0;10;5m")).toBe(true);
});

test("isMouseSequence rejects keyboard", () => {
  expect(isMouseSequence("\x1b[A")).toBe(false);
  expect(isMouseSequence("a")).toBe(false);
  expect(isMouseSequence("\t")).toBe(false);
});

test("returns null for non-mouse data", () => {
  expect(parseMouseEvent("hello")).toBeNull();
  expect(parseMouseEvent("\x1b[A")).toBeNull();
});
