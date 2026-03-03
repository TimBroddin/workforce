import { Box, Text } from "ink";
import { shortenPath } from "../lib/path-utils";

interface Props {
  folders: string[];
  selectedIndex: number;
}

export function SpawnModal({ folders, selectedIndex }: Props) {
  return (
    <Box
      flexDirection="column"
      borderStyle="bold"
      borderColor="cyan"
      paddingX={2}
      paddingY={1}
    >
      <Text bold>Spawn new agent</Text>
      <Text dimColor>Select folder:</Text>
      <Text> </Text>
      {folders.map((folder, i) => (
        <Text
          key={folder}
          backgroundColor={i === selectedIndex ? "cyan" : undefined}
          color={i === selectedIndex ? "black" : undefined}
        >
          {i === selectedIndex ? " ▸ " : "   "}
          {shortenPath(folder)}
        </Text>
      ))}
      <Text> </Text>
      <Text dimColor>Enter to spawn · Esc to cancel</Text>
    </Box>
  );
}
