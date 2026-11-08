/** Offline example for the P1 protocol lab. This is a readable, self-contained source. */
export const metadata = {
  apiVersion: 1,
  id: "org.example.offline",
  name: "离线示例",
  version: "1.0.0",
  origins: ["https://example.org"]
};
export async function search(ctx, { query }) {
  return { items: [{ ref: { id: "demo" }, title: "离线示例", author: "协议实验室" }], nextCursor: null };
}
export async function book(ctx, { ref }) {
  return { ref, title: "离线示例", description: "这个示例不需要网络，可以用来检查单文件书源的四项操作。" };
}
export async function chapters(ctx, { book }) {
  return { items: [{ ref: { id: "chapter-1" }, title: "第一章" }], nextCursor: null };
}
export async function content(ctx, { book, chapter }) {
  const document = new DOMParser().parseFromString("<article><p>你好，阅读者。</p><p>引用可以跨执行会话恢复。</p></article>", "text/html");
  return { title: "第一章", body: { kind: "html", html: document.querySelector("article").innerHTML, baseURL: "https://example.org/" } };
}
