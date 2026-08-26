import { mkdir, writeFile, chmod, readFile } from 'node:fs/promises';
import { homedir } from 'node:os';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

/**
 * Registers the bridge as a native-messaging host.
 *
 * A browser will only start a native host it has been told about in advance, by
 * a manifest in a fixed per-browser directory that names both the executable and
 * exactly which extension may talk to it. That last part is the security model:
 * without the id in `allowed_origins`, any extension could drive the engine.
 *
 * Run with `npm run install-host` in the bridge folder.
 */

const HOST_NAME = 'com.duckdownloader.engine';

const here = dirname(fileURLToPath(import.meta.url));
const root = resolve(here, '..');
const repoRoot = resolve(root, '..');

/** Where each browser looks, per platform. */
function hostDirectories() {
  const home = homedir();

  if (process.platform === 'darwin') {
    const support = join(home, 'Library', 'Application Support');
    return {
      Chrome: join(support, 'Google', 'Chrome', 'NativeMessagingHosts'),
      Brave: join(support, 'BraveSoftware', 'Brave-Browser', 'NativeMessagingHosts'),
      Edge: join(support, 'Microsoft Edge', 'NativeMessagingHosts'),
      Chromium: join(support, 'Chromium', 'NativeMessagingHosts'),
    };
  }

  if (process.platform === 'linux') {
    const config = process.env.XDG_CONFIG_HOME ?? join(home, '.config');
    return {
      Chrome: join(config, 'google-chrome', 'NativeMessagingHosts'),
      Brave: join(config, 'BraveSoftware', 'Brave-Browser', 'NativeMessagingHosts'),
      Chromium: join(config, 'chromium', 'NativeMessagingHosts'),
    };
  }

  // On Windows the manifest path lives in the registry rather than a fixed
  // folder, so the file is written here and the command to register it printed.
  return { Windows: join(root, 'dist') };
}

/**
 * The manifest must point at something the OS will execute directly. Node is
 * not that, so a launcher script carries the interpreter — and on Windows a
 * `.cmd`, because a shebang means nothing there.
 */
async function writeLauncher() {
  const entry = join(root, 'dist', 'bridge', 'src', 'index.js');

  if (process.platform === 'win32') {
    const path = join(root, 'dist', 'duck-bridge.cmd');
    await writeFile(path, `@echo off\r\n"${process.execPath}" "${entry}" %*\r\n`, 'utf8');
    return path;
  }

  const path = join(root, 'dist', 'duck-bridge');
  await writeFile(path, `#!/bin/sh\nexec "${process.execPath}" "${entry}" "$@"\n`, 'utf8');
  await chmod(path, 0o755);
  return path;
}

async function main() {
  const id = (await readFile(join(repoRoot, 'extension', 'keys', 'id.txt'), 'utf8')).trim();
  const launcher = await writeLauncher();

  const manifest = {
    name: HOST_NAME,
    description: 'Duck Engine bridge',
    path: launcher,
    type: 'stdio',
    // Only this extension. Any other caller is refused by the browser itself.
    allowed_origins: [`chrome-extension://${id}/`],
  };

  console.log(`extension id : ${id}`);
  console.log(`launcher     : ${launcher}\n`);

  for (const [browser, directory] of Object.entries(hostDirectories())) {
    await mkdir(directory, { recursive: true });
    const target = join(directory, `${HOST_NAME}.json`);
    await writeFile(target, JSON.stringify(manifest, null, 2), 'utf8');
    console.log(`installed for ${browser.padEnd(9)} ${target}`);
  }

  if (process.platform === 'win32') {
    console.log(
      `\nOn Windows, register it once:\n` +
        `  reg add "HKCU\\Software\\Google\\Chrome\\NativeMessagingHosts\\${HOST_NAME}" ` +
        `/ve /t REG_SZ /d "${join(root, 'dist', `${HOST_NAME}.json`)}" /f`,
    );
  }
}

main().catch((error) => {
  console.error('could not install the native host:', error);
  process.exit(1);
});
