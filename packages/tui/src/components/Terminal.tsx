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
      borderStyle="round"
      borderColor={focused ? "#22c55e" : "#374151"}
    >
      {lines.length === 0 ? (
        <Box flexDirection="column" justifyContent="center" alignItems="center" flexGrow={1}>
          <Text color="#4b5563">╭─────────────────────╮</Text>
          <Text color="#4b5563">│                     │</Text>
          <Text color="#4b5563">│  <Text color="#6b7280">Select an agent</Text>   │</Text>
          <Text color="#4b5563">│  <Text color="#6b7280">to view terminal</Text>  │</Text>
          <Text color="#4b5563">│                     │</Text>
          <Text color="#4b5563">╰─────────────────────╯</Text>
        </Box>
      ) : (
        lines.map((line, i) => (
          <Text key={i}>{line}</Text>
        ))
      )}
    </Box>
  );
}
