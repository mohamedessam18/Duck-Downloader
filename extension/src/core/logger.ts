/**
 * Logging that disappears in production builds. `import.meta.env.DEV` is
 * statically replaced by the bundler, so the calls tree-shake away entirely —
 * shipping console noise to users is a review smell.
 */
const PREFIX = '[duck]';

export const log = {
  debug(...args: unknown[]) {
    if (import.meta.env.DEV) console.debug(PREFIX, ...args);
  },
  info(...args: unknown[]) {
    if (import.meta.env.DEV) console.info(PREFIX, ...args);
  },
  warn(...args: unknown[]) {
    console.warn(PREFIX, ...args);
  },
  error(...args: unknown[]) {
    console.error(PREFIX, ...args);
  },
};
