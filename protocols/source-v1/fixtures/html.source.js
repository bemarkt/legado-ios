/**
 * Project-authored HTML fixture for the proposed reader protocol.
 * Uses the local fixture server. Production apps must not enable arbitrary local origins by default.
 * This is a design example, not a plugin supported by the current app.
 */
export const metadata = {
  apiVersion: 1,
  id: "org.example.fixture.html",
  name: "HTML fixture",
  version: "1.0.0",
  origins: ["http://127.0.0.1:18764"]
};

const origin = "http://127.0.0.1:18764";

function required(value, field, ctx) {
  if (typeof value !== "string" || value.trim() === "") {
    throw ctx.errors.parse({ field, message: "缺少必要字段：" + field });
  }
  return value.trim();
}

function text(node, selector) {
  return node.querySelector(selector)?.textContent?.trim() ?? "";
}

function absoluteURL(value, baseURL) {
  return new URL(value, baseURL).href;
}

async function loadDocument(ctx, url) {
  const response = await ctx.http.fetch(url, { signal: ctx.signal });
  if (!response.ok) {
    throw ctx.errors.http({ status: response.status, url: response.url });
  }
  const html = await response.text();
  return {
    document: new DOMParser().parseFromString(html, "text/html"),
    url: response.url
  };
}

function bookItem(node, baseURL, ctx) {
  const id = required(node.getAttribute("data-book-id"), "book.id", ctx);
  const title = required(text(node, ".title"), "book.title", ctx);
  const href = required(node.querySelector("a")?.getAttribute("href"), "book.url", ctx);
  const item = {
    ref: { id, url: absoluteURL(href, baseURL) },
    title,
    author: text(node, ".author")
  };
  const cover = node.querySelector("img")?.getAttribute("src");
  if (cover) item.cover = { url: absoluteURL(cover, baseURL) };
  return item;
}

export async function search(ctx, { query, cursor = null }) {
  const url = new URL("/html/search", origin);
  url.searchParams.set("q", query);
  url.searchParams.set("page", String(cursor?.page ?? 1));
  const { document, url: finalURL } = await loadDocument(ctx, url.href);
  return {
    items: [...document.querySelectorAll(".book")].map(node => bookItem(node, finalURL, ctx)),
    nextCursor: document.querySelector("a.next")
      ? { page: (cursor?.page ?? 1) + 1 }
      : null
  };
}

export async function book(ctx, { ref }) {
  const { document } = await loadDocument(ctx, ref.url ?? absoluteURL("/html/book/" + encodeURIComponent(ref.id), origin));
  return {
    ref,
    title: required(text(document, "h1"), "book.title", ctx),
    author: text(document, ".author"),
    description: text(document, ".description")
  };
}

export async function chapters(ctx, { book, cursor = null }) {
  const url = new URL("/html/book/" + encodeURIComponent(book.id) + "/chapters", origin);
  url.searchParams.set("page", String(cursor?.page ?? 1));
  const { document, url: finalURL } = await loadDocument(ctx, url.href);
  const items = [...document.querySelectorAll(".chapter")].map(node => ({
    ref: {
      id: required(node.getAttribute("data-chapter-id"), "chapter.id", ctx),
      url: absoluteURL(required(node.getAttribute("href"), "chapter.url", ctx), finalURL)
    },
    title: required(node.textContent, "chapter.title", ctx)
  }));
  const page = {
    items,
    nextCursor: document.querySelector("a.next")
      ? { page: (cursor?.page ?? 1) + 1 }
      : null
  };
  const revision = document.querySelector('meta[name="catalog-revision"]')?.getAttribute("content");
  if (revision) page.revision = revision;
  return page;
}

export async function content(ctx, { book, chapter }) {
  const url = chapter.url ?? absoluteURL("/html/book/" + encodeURIComponent(book.id) + "/chapter/" + encodeURIComponent(chapter.id), origin);
  const { document, url: finalURL } = await loadDocument(ctx, url);
  const article = document.querySelector("article");
  if (!article) throw ctx.errors.parse({ field: "content.body", message: "正文节点不存在" });
  article.querySelectorAll("script, style, .ad").forEach(node => node.remove());
  return {
    title: required(text(document, "h1"), "content.title", ctx),
    body: {
      kind: "html",
      html: article.innerHTML,
      baseURL: finalURL
    }
  };
}
