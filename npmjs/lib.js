"use strict";

// Shared logic for the npm launcher: work out which prebuilt `serbox` binary
// belongs on this machine, and fetch it from GitHub Releases on demand.
//
// serbox deliberately ships **no install script**. As of npm 12 dependency
// lifecycle scripts are blocked unless the user opts in, and pnpm 12 fails a
// *project* install outright with ERR_PNPM_IGNORED_BUILDS when a dependency
// declares one. Downloading on first run works under every package manager,
// under `--ignore-scripts`, and under `npx`, so that is what this does.
//
// Overrides (all optional):
//   SERBOX_REPO            owner/repo       (default: kupas/serbox)
//   SERBOX_VERSION         release version  (default: this package's version)
//   SERBOX_DOWNLOAD_BASE   full base URL    (overrides SERBOX_REPO/SERBOX_VERSION)
//   SERBOX_CACHE_DIR       where the binary is kept
//   SERBOX_BINARY          run this binary and never download
//   SERBOX_FORCE_DOWNLOAD  re-download even if the binary is already present
//   SERBOX_SKIP_DOWNLOAD   never download; fail if the binary is absent
//   SERBOX_NO_VERIFY       skip SHA-256 verification

const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");
const https = require("https");
const http = require("http");

const pkg = require("./package.json");

// Node's `platform-arch` -> the release target name. serbox runs on the server
// that owns the boxes, which in practice means Linux; a macOS or Windows host
// should install a Linux VM or use Docker Desktop's Linux engine.
const TARGETS = {
  "linux-x64": "linux-x86_64",
  "linux-arm64": "linux-aarch64",
};

const SUPPORTED = "linux-x86_64 and linux-aarch64";

function targetName() {
  return TARGETS[`${process.platform}-${process.arch}`];
}

function repoSlug() {
  if (process.env.SERBOX_REPO) return process.env.SERBOX_REPO;
  const url =
    typeof pkg.repository === "string"
      ? pkg.repository
      : (pkg.repository && pkg.repository.url) || "";
  const m = url.match(/github\.com[/:]([^/]+)\/([^/.]+)/);
  return m ? `${m[1]}/${m[2]}` : "kupas/serbox";
}

function version() {
  return (process.env.SERBOX_VERSION || pkg.version).replace(/^v/, "");
}

function assetName(target) {
  return `serbox-${target}`;
}

// Both URLs are tried in order: the pinned version first, then whatever is
// latest. The fallback keeps the launcher useful when a release was re-cut
// under a different tag, or when package.json was bumped ahead of the tag.
function downloadUrls(target) {
  const asset = assetName(target);
  if (process.env.SERBOX_DOWNLOAD_BASE) {
    const base = process.env.SERBOX_DOWNLOAD_BASE.replace(/\/+$/, "");
    return [`${base}/${asset}`];
  }
  const repo = repoSlug();
  return [
    `https://github.com/${repo}/releases/download/v${version()}/${asset}`,
    `https://github.com/${repo}/releases/latest/download/${asset}`,
  ];
}

function cacheDir() {
  if (process.env.SERBOX_CACHE_DIR) return process.env.SERBOX_CACHE_DIR;
  const home = os.homedir();
  const base = process.env.XDG_CACHE_HOME || path.join(home, ".cache");
  return path.join(base, "serbox");
}

function binaryPath(target) {
  return path.join(cacheDir(), `serbox-${version()}-${target}`);
}

function isRunnable(file) {
  try {
    fs.accessSync(file, fs.constants.X_OK);
    return true;
  } catch {
    return false;
  }
}

// --- HTTP ------------------------------------------------------------------

function fetch(url, redirects) {
  return new Promise((resolve, reject) => {
    if (redirects > 10) {
      reject(new Error("too many redirects"));
      return;
    }
    const client = url.startsWith("http:") ? http : https;
    const req = client.get(
      url,
      { headers: { "user-agent": `serbox-npm/${pkg.version}` } },
      (res) => {
        const { statusCode, headers } = res;
        if (statusCode >= 300 && statusCode < 400 && headers.location) {
          res.resume();
          resolve(fetch(new URL(headers.location, url).toString(), redirects + 1));
          return;
        }
        if (statusCode !== 200) {
          res.resume();
          const err = new Error(`GET ${url} -> HTTP ${statusCode}`);
          err.statusCode = statusCode;
          reject(err);
          return;
        }
        resolve(res);
      }
    );
    req.on("error", reject);
    req.setTimeout(120000, () => req.destroy(new Error(`timed out fetching ${url}`)));
  });
}

async function fetchBuffer(url) {
  const res = await fetch(url, 0);
  const chunks = [];
  for await (const chunk of res) chunks.push(chunk);
  return Buffer.concat(chunks);
}

async function fetchText(url) {
  return (await fetchBuffer(url)).toString("utf8");
}

// --- install ---------------------------------------------------------------

// Download to a sibling temp file and rename into place, so a crashed or
// concurrent run can never leave a half-written binary at `dest`.
async function downloadTo(url, dest) {
  const res = await fetch(url, 0);
  fs.mkdirSync(path.dirname(dest), { recursive: true });
  const tmp = `${dest}.${process.pid}.${Date.now()}.part`;
  try {
    await new Promise((resolve, reject) => {
      const out = fs.createWriteStream(tmp, { mode: 0o755 });
      res.pipe(out);
      out.on("finish", () => out.close(resolve));
      out.on("error", reject);
      res.on("error", reject);
    });
    const size = fs.statSync(tmp).size;
    if (size === 0) throw new Error(`${url} returned an empty file`);
    fs.chmodSync(tmp, 0o755);
    fs.renameSync(tmp, dest);
  } catch (err) {
    fs.rmSync(tmp, { force: true });
    throw err;
  }
}

// Verify against the `<asset>.sha256` published next to the binary. A missing
// checksum is a warning, not a failure, so older releases keep working.
async function verify(dest, url, log) {
  if (process.env.SERBOX_NO_VERIFY) return;
  let published;
  try {
    published = (await fetchText(`${url}.sha256`)).trim();
  } catch {
    log(`serbox: warning: no checksum published for ${path.basename(url)}`);
    return;
  }
  const expected = (published.split(/\s+/)[0] || "").toLowerCase();
  if (!/^[0-9a-f]{64}$/.test(expected)) {
    log("serbox: warning: published checksum is not a SHA-256 digest");
    return;
  }
  const actual = crypto.createHash("sha256").update(fs.readFileSync(dest)).digest("hex");
  if (actual !== expected) {
    fs.rmSync(dest, { force: true });
    throw new Error(
      `checksum mismatch for ${path.basename(url)}\n` +
        `  expected ${expected}\n  actual   ${actual}`
    );
  }
}

/**
 * Resolve to a runnable `serbox` binary, downloading it when it is missing.
 */
async function ensureBinary({ force = false, log = () => {} } = {}) {
  if (process.env.SERBOX_BINARY) {
    if (!fs.existsSync(process.env.SERBOX_BINARY)) {
      throw new Error(
        `SERBOX_BINARY points at ${process.env.SERBOX_BINARY}, which does not exist`
      );
    }
    return process.env.SERBOX_BINARY;
  }

  const target = targetName();
  if (!target) {
    throw new Error(
      `serbox does not ship a binary for ${process.platform}/${process.arch}; ` +
        `supported: ${SUPPORTED}. Build from source instead: ` +
        `https://github.com/${repoSlug()}#build-from-source`
    );
  }

  const dest = binaryPath(target);
  const wanted = force || process.env.SERBOX_FORCE_DOWNLOAD;
  if (!wanted && isRunnable(dest)) return dest;

  if (process.env.SERBOX_SKIP_DOWNLOAD) {
    if (isRunnable(dest)) return dest;
    throw new Error(
      `SERBOX_SKIP_DOWNLOAD is set but no serbox binary is installed at ${dest}`
    );
  }

  const urls = downloadUrls(target);
  let lastError;
  for (const url of urls) {
    try {
      log(`serbox: downloading ${url}`);
      await downloadTo(url, dest);
      await verify(dest, url, log);
      log(`serbox: installed ${dest}`);
      return dest;
    } catch (err) {
      lastError = err;
      log(`serbox: ${err.message}`);
    }
  }

  throw new Error(
    `could not download the serbox binary for ${target}.\n` +
      `Tried:\n${urls.map((u) => `  ${u}`).join("\n")}\n` +
      `Last error: ${lastError && lastError.message}\n\n` +
      `Install it another way instead:\n` +
      `  curl -LsSf https://raw.githubusercontent.com/${repoSlug()}/main/install.sh | bash\n` +
      `or set SERBOX_DOWNLOAD_BASE to a mirror.`
  );
}

module.exports = {
  pkg,
  TARGETS,
  SUPPORTED,
  targetName,
  repoSlug,
  version,
  assetName,
  downloadUrls,
  cacheDir,
  binaryPath,
  isRunnable,
  ensureBinary,
};
