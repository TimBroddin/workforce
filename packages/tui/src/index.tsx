import { render } from "ink";
import { App } from "./App";

export interface TuiOptions {
  port: number;
  token: string;
}

export function startTui(options: TuiOptions) {
  const { waitUntilExit } = render(
    <App port={options.port} token={options.token} />,
    { exitOnCtrlC: false }
  );
  return waitUntilExit;
}
