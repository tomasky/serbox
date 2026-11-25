"use strict";

// Unit tests for the launcher's platform mapping and URL construction, plus a
// local download exercised against a file://-style HTTP server. Run with
// `node --test` from this directory.

const test = require("node:test");
const assert = require("node:assert/strict");
const path = require("node:path");
const fs = require("node:fs");
const os = require("node:os");
const http = require("node:http");
const { execFileSync } = require("node:child_process");

const lib = require("./lib.js");

test("maps every supported Node platform-arch to a release target", () => {
  assert.equal(lib.TARGETS["linux-x64"], "linux-x86_64");
  assert.equal(lib.TARGETS["linux-arm64"], "linux-aarch64");
  assert.equal(Object.keys(lib.TARGETS).length, 2);
});

test("resolves the repository slug from package.json", () => {
  assert.equal(lib.repoSlug(), "kupas/serbox");
});

test("falls back from the pinned version to latest", () => {
  const urls = lib.downloadUrls("linux-x86_64");
  assert.equal(urls.length, 2);
  assert.match(
    urls[0],
    /^https:\/\/github\.com\/kupas\/serbox\/releases\/download\/v\d+\.\d+\.\d+\/serbox-linux-x86_64$/
  );
  assert.equal(
    urls[1],
    "https://github.com/kupas/serbox/releases/latest/download/serbox-linux-x86_64"
  );
});

test("SERBOX_DOWNLOAD_BASE replaces both default URLs", () => {
  const saved = process.env.SERBOX_DOWNLOAD_BASE;
  process.env.SERBOX_DOWNLOAD_BASE = "https://mirror.example.com/serbox/";
  try {
    assert.deepEqual(lib.downloadUrls("linux-aarch64"), [
      "https://mirror.example.com/serbox/serbox-linux-aarch64",
    ]);
  } finally {
    if (saved === undefined) delete process.env.SERBOX_DOWNLOAD_BASE;
    else process.env.SERBOX_DOWNLOAD_BASE = saved;
  }
});

test("SERBOX_VERSION wins over the package version and tolerates a v prefix", () => {
  const saved = process.env.SERBOX_VERSION;
  process.env.SERBOX_VERSION = "v9.9.9";
  try {
    assert.equal(lib.version(), "9.9.9");
    assert.match(lib.downloadUrls("linux-aarch64")[0], /\/v9\.9\.9\//);
  } finally {
    if (saved === undefined) delete process.env.SERBOX_VERSION;
    else process.env.SERBOX_VERSION = saved;
  }
});

test("the cache directory can be redirected", () => {
  const saved = process.env.SERBOX_CACHE_DIR;
  process.env.SERBOX_CACHE_DIR = "/tmp/serbox-test-cache";
  try {
    assert.equal(lib.cacheDir(), "/tmp/serbox-test-cache");
    assert.equal(
      lib.binaryPath("linux-x86_64"),
      path.join("/tmp/serbox-test-cache", `serbox-${lib.version()}-linux-x86_64`)
    );
  } finally {
    if (saved === undefined) delete process.env.SERBOX_CACHE_DIR;
    else process.env.SERBOX_CACHE_DIR = saved;
  }
});

test("SERBOX_BINARY short-circuits every download path", async () => {
  const saved = process.env.SERBOX_BINARY;
  process.env.SERBOX_BINARY = "/bin/sh";
  try {
    assert.equal(await lib.ensureBinary(), "/bin/sh");
  } finally {
    if (saved === undefined) delete process.env.SERBOX_BINARY;
    else process.env.SERBOX_BINARY = saved;
  }
});

test("SERBOX_BINARY pointing nowhere is a clear error", async () => {
  const saved = process.env.SERBOX_BINARY;
  process.env.SERBOX_BINARY = "/nonexistent/serbox";
  try {
    await assert.rejects(lib.ensureBinary(), /does not exist/);
  } finally {
    if (saved === undefined) delete process.env.SERBOX_BINARY;
    else process.env.SERBOX_BINARY = saved;
  }
});

test("an unsupported platform explains itself", async () => {
  const saved = process.env.SERBOX_BINARY;
  delete process.env.SERBOX_BINARY;
  const realPlatform = process.platform;
  const realArch = process.arch;
  try {
    Object.defineProperty(process, "platform", { value: "sunos" });
    Object.defineProperty(process, "arch", { value: "sparc" });
    await assert.rejects(lib.ensureBinary(), /does not ship a binary/);
  } finally {
    Object.defineProperty(process, "platform", { value: realPlatform });
    Object.defineProperty(process, "arch", { value: realArch });
    if (saved === undefined) delete process.env.SERBOX_BINARY;
    else process.env.SERBOX_BINARY = saved;
  }
});

// The next two tests exercise the download itself, against a local HTTP server
// that serves a fake "binary". They are what catch a broken checksum check or a
// rename that leaves a half-written file behind.
async function withServer(handler, fn) {
  const server = http.createServer(handler);
  await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    return await fn(base);
  } finally {
    await new Promise((resolve) => server.close(resolve));
  }
}

const FAKE = Buffer.from("#!/bin/sh\necho fake-serbox \"$@\"\n");
const FAKE_SHA = require("crypto").createHash("sha256").update(FAKE).digest("hex");

test("ensureBinary downloads, verifies and marks the binary executable", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "serbox-dl-"));
  const saved = {
    base: process.env.SERBOX_DOWNLOAD_BASE,
    cache: process.env.SERBOX_CACHE_DIR,
    binary: process.env.SERBOX_BINARY,
  };
  delete process.env.SERBOX_BINARY;
  process.env.SERBOX_CACHE_DIR = dir;
  try {
    await withServer(
      (req, res) => {
        if (req.url.endsWith(".sha256")) {
          res.writeHead(200).end(`${FAKE_SHA}  serbox-${lib.targetName()}\n`);
        } else {
          res.writeHead(200).end(FAKE);
        }
      },
      async (base) => {
        process.env.SERBOX_DOWNLOAD_BASE = base;
        const bin = await lib.ensureBinary();
        assert.equal(bin, lib.binaryPath(lib.targetName()));
        assert.equal(fs.readFileSync(bin).toString(), FAKE.toString());
        assert.equal(execFileSync(bin, ["version"]).toString().trim(), "fake-serbox version");
      }
    );
  } finally {
    for (const [key, value] of [
      ["SERBOX_DOWNLOAD_BASE", saved.base],
      ["SERBOX_CACHE_DIR", saved.cache],
      ["SERBOX_BINARY", saved.binary],
    ]) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("a checksum mismatch removes the downloaded file", async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "serbox-bad-"));
  const saved = {
    base: process.env.SERBOX_DOWNLOAD_BASE,
    cache: process.env.SERBOX_CACHE_DIR,
    binary: process.env.SERBOX_BINARY,
  };
  delete process.env.SERBOX_BINARY;
  process.env.SERBOX_CACHE_DIR = dir;
  try {
    await withServer(
      (req, res) => {
        if (req.url.endsWith(".sha256")) {
          res.writeHead(200).end(`${"0".repeat(64)}  serbox\n`);
        } else {
          res.writeHead(200).end(FAKE);
        }
      },
      async (base) => {
        process.env.SERBOX_DOWNLOAD_BASE = base;
        await assert.rejects(lib.ensureBinary(), /could not download/);
        assert.equal(fs.existsSync(lib.binaryPath(lib.targetName())), false);
      }
    );
  } finally {
    for (const [key, value] of [
      ["SERBOX_DOWNLOAD_BASE", saved.base],
      ["SERBOX_CACHE_DIR", saved.cache],
      ["SERBOX_BINARY", saved.binary],
    ]) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
