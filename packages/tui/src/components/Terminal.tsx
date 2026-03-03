import React from "react";
import { Box, Text } from "ink";

interface Props {
  lines: string[];
  focused: boolean;
}

export function TerminalViewport({ lines, focused }: Props) {
  return (
    <Box
      flexDirection="column"
      flexGrow={1}
      borderStyle={focused ? "bold" : "single"}
      borderColor={focused ? "green" : "gray"}
    >
      {lines.length === 0 ? (
        <Text dimColor>Select an agent to view terminal output</Text>
      ) : (
        lines.map((line, i) => (
          <Text key={i}>{line}</Text>
        ))
      )}
    </Box>
  );
}
