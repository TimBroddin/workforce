import { useState, useCallback } from "react";

export type Pane = "sidebar" | "terminal";

export function useFocus() {
  const [activePane, setActivePane] = useState<Pane>("sidebar");

  const toggle = useCallback(() => {
    setActivePane((prev) => (prev === "sidebar" ? "terminal" : "sidebar"));
  }, []);

  return { activePane, toggle };
}
