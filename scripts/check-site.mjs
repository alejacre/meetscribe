#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";

const root = path.resolve(process.cwd(), "site");
const required = [
  "index.html",
  "styles.css",
  "main.js",
  "manifest.webmanifest",
  ".nojekyll",
  "assets/app-icon.png",
  "assets/product-preview.png",
];
const failures = [];

for (const relative of required) {
  const absolute = path.join(root, relative);
  if (!fs.existsSync(absolute)) {
    failures.push(`Missing required site file: ${relative}`);
  }
}

if (!fs.existsSync(root)) {
  failures.push("Missing site directory");
} else {
  const htmlFiles = fs.readdirSync(root)
    .filter((name) => name.endsWith(".html"))
    .map((name) => path.join(root, name));

  for (const file of htmlFiles) {
    const body = fs.readFileSync(file, "utf8");
    const relativeFile = path.relative(process.cwd(), file);

    if (path.basename(file) === "index.html") {
      if (!/<meta\s+name=["']viewport["']/i.test(body)) {
        failures.push(`${relativeFile}: missing viewport metadata`);
      }
      if (!/<title>[^<]+<\/title>/i.test(body)) {
        failures.push(`${relativeFile}: missing title`);
      }
      if (!/<h1(?:\s[^>]*)?>[^<]+<\/h1>/i.test(body)) {
        failures.push(`${relativeFile}: missing visible h1`);
      }
    }

    for (const match of body.matchAll(/\b(href|src)=["']([^"']+)["']/gi)) {
      const target = match[2];
      if (
        target.startsWith("#")
        || target.startsWith("http://")
        || target.startsWith("https://")
        || target.startsWith("mailto:")
        || target.startsWith("data:")
      ) {
        continue;
      }

      if (target.startsWith("/")) {
        failures.push(`${relativeFile}: project Pages links must be relative: ${target}`);
        continue;
      }

      const cleanTarget = target.split(/[?#]/, 1)[0];
      if (!cleanTarget) continue;
      let resolved = path.resolve(path.dirname(file), cleanTarget);
      if (fs.existsSync(resolved) && fs.statSync(resolved).isDirectory()) {
        resolved = path.join(resolved, "index.html");
      }
      if (!fs.existsSync(resolved)) {
        failures.push(`${relativeFile}: broken local reference: ${target}`);
      }
    }

    for (const match of body.matchAll(/<a\b([^>]*target=["']_blank["'][^>]*)>/gi)) {
      if (!/\brel=["'][^"']*noopener[^"']*["']/i.test(match[1])) {
        failures.push(`${relativeFile}: target="_blank" link is missing rel="noopener"`);
      }
    }
  }
}

const manifestPath = path.join(root, "manifest.webmanifest");
if (fs.existsSync(manifestPath)) {
  try {
    JSON.parse(fs.readFileSync(manifestPath, "utf8"));
  } catch (error) {
    failures.push(`site/manifest.webmanifest: invalid JSON (${error.message})`);
  }
}

const cssPath = path.join(root, "styles.css");
if (fs.existsSync(cssPath)) {
  const css = fs.readFileSync(cssPath, "utf8");
  if (/(?:linear|radial)-gradient\s*\(/i.test(css)) {
    failures.push("site/styles.css: gradients are not part of the site design");
  }
  if (/letter-spacing\s*:\s*-\d/i.test(css)) {
    failures.push("site/styles.css: negative letter spacing is not allowed");
  }
  if (/font-size\s*:\s*clamp\s*\(/i.test(css)) {
    failures.push("site/styles.css: font sizes must use stable breakpoint values");
  }
}

const previewPath = path.join(root, "assets/product-preview.png");
if (fs.existsSync(previewPath) && fs.statSync(previewPath).size < 50_000) {
  failures.push("site/assets/product-preview.png: preview image is unexpectedly small");
}

if (failures.length > 0) {
  console.error("Site checks failed:");
  failures.forEach((failure) => console.error(`  ${failure}`));
  process.exit(1);
}

console.log("Site checks passed");
