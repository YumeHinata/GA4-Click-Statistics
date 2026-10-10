#!/usr/bin/env node
"use strict";

const fs = require("node:fs/promises");
const { JSDOM } = require("jsdom");

const BLOG_ORIGIN = new URL(
  process.env.BLOG_ORIGIN || "https://www.yumehinata.com/"
);

const SITEMAP_URL =
  process.env.SITEMAP_URL ||
  new URL("sitemap-index.xml", BLOG_ORIGIN).href;

const TWIKOO_ENV_ID =
  process.env.TWIKOO_ENV_ID || "https://twikoo.yumehinata.com/";

const TWIKOO_SCRIPT =
  "https://fastly.jsdelivr.net/npm/twikoo@2.0.12/dist/twikoo.min.js";

const BATCH_SIZE = 50;

// 统一文章路径：移除 index.html 和末尾斜杠。
// 输出格式与现有 views.json 保持一致。
function normalizePath(input) {
  let pathname;

  try {
    pathname = new URL(input, BLOG_ORIGIN).pathname;
  } catch {
    throw new Error(`无效的文章路径：${input}`);
  }

  pathname = pathname
    .replace(/\/index\.html?$/i, "")
    .replace(/\/+$/, "");

  return pathname || "/";
}

// 仅用于匹配 API 返回的路径。
// 兼容中文 URL 的编码形式差异。
function comparisonPath(input) {
  let pathname = normalizePath(input);

  try {
    pathname = decodeURI(pathname);
  } catch {
    // 遇到非标准编码时，保留原路径。
  }

  return pathname;
}

function decodeXml(value) {
  return value
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&amp;/g, "&");
}

function extractLocs(xml) {
  return [...xml.matchAll(/<loc>([\s\S]*?)<\/loc>/gi)]
    .map((match) => decodeXml(match[1].trim()));
}

// 递归读取 Sitemap 索引及其子 Sitemap。
async function fetchSitemap(url, visited = new Set()) {
  if (visited.has(url)) return [];
  visited.add(url);

  const response = await fetch(url, {
    signal: AbortSignal.timeout(30000),
  });

  if (!response.ok) {
    throw new Error(`Sitemap 请求失败：${url}，HTTP ${response.status}`);
  }

  const xml = await response.text();
  const locations = extractLocs(xml);

  if (/<sitemapindex\b/i.test(xml)) {
    const allLocations = [];

    for (const location of locations) {
      const childUrl = new URL(location, url).href;
      allLocations.push(...await fetchSitemap(childUrl, visited));
    }

    return allLocations;
  }

  if (!/<urlset\b/i.test(xml)) {
    throw new Error(`无法识别 Sitemap 格式：${url}`);
  }

  return locations;
}

function withTimeout(promise, ms, message) {
  let timer;

  return Promise.race([
    promise,
    new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(message)), ms);
    }),
  ]).finally(() => clearTimeout(timer));
}

async function main() {
  if (!TWIKOO_ENV_ID) {
    throw new Error("缺少 TWIKOO_ENV_ID");
  }

  console.log("正在读取博客 Sitemap...");

  const locations = await fetchSitemap(SITEMAP_URL);

  // key 为输出路径，apiUrl 为传给 Twikoo 的原始路径。
  const articles = new Map();

  for (const location of locations) {
    const url = new URL(location, BLOG_ORIGIN);

    if (!url.pathname.startsWith("/posts/")) continue;

    const key = normalizePath(url.pathname);
    if (key === "/posts") continue;

    if (!articles.has(key)) {
      articles.set(key, {
        key,
        apiUrl: url.pathname,
      });
    }
  }

  const articleList = [...articles.values()].sort(
    (a, b) => a.key.localeCompare(b.key)
  );

  if (articleList.length === 0) {
    throw new Error(
      "Sitemap 中没有找到 /posts/ 文章，请检查 Sitemap 和博客路由。"
    );
  }

  console.log(`找到 ${articleList.length} 篇文章。`);
  console.log("正在加载 Twikoo SDK...");

  // 使用博客自身的 Origin，模拟正常网站中的跨域 API 调用。
  const dom = new JSDOM(
    "<!doctype html><html><head></head><body></body></html>",
    {
      url: BLOG_ORIGIN.href,
      runScripts: "dangerously",
      resources: "usable",
    }
  );

  try {
    const script = dom.window.document.createElement("script");
    script.src = TWIKOO_SCRIPT;

    const scriptLoading = new Promise((resolve, reject) => {
      script.onload = resolve;
      script.onerror = () => reject(
        new Error("Twikoo SDK 下载失败，请检查 CDN。")
      );

      dom.window.document.head.appendChild(script);
    });

    await withTimeout(
      scriptLoading,
      30000,
      "Twikoo SDK 加载超时"
    );

    const twikoo = dom.window.twikoo;

    if (!twikoo || typeof twikoo.getCommentsCount !== "function") {
      throw new Error("Twikoo SDK 加载完成，但没有找到 getCommentsCount()");
    }

    console.log("正在批量获取文章评论数...");

    const counts = Object.fromEntries(
      articleList.map((article) => [article.key, 0])
    );

    // 分批请求，避免一次提交过长的 URL 数组。
    for (let i = 0; i < articleList.length; i += BATCH_SIZE) {
      const batch = articleList.slice(i, i + BATCH_SIZE);

      const result = await withTimeout(
        twikoo.getCommentsCount({
          envId: TWIKOO_ENV_ID,
          urls: batch.map((article) => article.apiUrl),
          includeReply: true,
        }),
        60000,
        `Twikoo 第 ${Math.floor(i / BATCH_SIZE) + 1} 批请求超时`
      );

      if (!Array.isArray(result)) {
        throw new Error("Twikoo 返回的数据不是预期的数组格式。");
      }

      for (const item of result) {
        const key = articles.get(comparisonPath(item.url))?.key;

        if (key === undefined) continue;

        const count = Number(item.count);

        if (!Number.isFinite(count) || count < 0) {
          throw new Error(`文章评论数无效：${item.url}`);
        }

        counts[key] = count;
      }

      console.log(
        `已处理 ${Math.min(i + BATCH_SIZE, articleList.length)}/${articleList.length} 篇文章`
      );
    }

    const output = Object.fromEntries(
      Object.entries(counts).sort(([a], [b]) => a.localeCompare(b))
    );

    await fs.mkdir("data", { recursive: true });

    const temporaryFile = "data/comments.json.tmp";
    await fs.writeFile(
      temporaryFile,
      JSON.stringify(output, null, 2) + "\n",
      "utf8"
    );

    await fs.rename(temporaryFile, "data/comments.json");

    console.log(
      `评论数同步成功，共 ${Object.keys(output).length} 篇文章。`
    );
    console.log("已写入 data/comments.json");
  } finally {
    dom.window.close();
  }
}

main().catch((error) => {
  console.error("Twikoo 评论数同步失败：", error);
  process.exitCode = 1;
});
