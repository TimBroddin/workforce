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
      borderStyle="round"
      borderColor="#8b5cf6"
      paddingX={3}
      paddingY={1}
    >
      <Text bold color="#e2e8f0">⚡ Spawn New Agent</Text>
      <Text color="#6b7280">Select a workspace:</Text>
      <Text> </Text>
      {folders.map((folder, i) => (
        <Text key={folder}>
          {i === selectedIndex
            ? <Text color="#8b5cf6" bold> ▸ </Text>
            : <Text color="#374151">   </Text>
          }
          <Text
            backgroundColor={i === selectedIndex ? "#8b5cf6" : undefined}
            color={i === selectedIndex ? "white" : "#9ca3af"}
            bold={i === selectedIndex}
          >
            {" "}{shortenPath(folder)}{" "}
          </Text>
        </Text>
      ))}
      <Text> </Text>
      <Text color="#6b7280">
        <Text color="#60a5fa" bold>Enter</Text> spawn  <Text color="#60a5fa" bold>Esc</Text> cancel
      </Text>
    </Box>
  );
}
