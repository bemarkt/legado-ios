/** Synthetic, project-authored fixture. No credentials and no third-party sites. */
export const metadata = {
  apiVersion: 1,
  id: 'org.example.fixture.json',
  name: 'JSON fixture',
  version: '1.0.0',
  origins: ['http://127.0.0.1:18764']
};
const origin = 'http://127.0.0.1:18764';
async function get(ctx, path) {
  const response = await ctx.http.fetch(new URL(path, origin).href);
  if (!response.ok) throw ctx.errors.http({ status: response.status, url: response.url });
  return response.json();
}
export async function search(ctx, { query, cursor = null }) {
  return get(ctx, '/api/search?q=' + encodeURIComponent(query) + '&page=' + (cursor?.page ?? 1));
}
export async function book(ctx, { ref }) {
  return get(ctx, '/api/book/' + encodeURIComponent(ref.id));
}
export async function chapters(ctx, { book, cursor = null }) {
  return get(ctx, '/api/book/' + encodeURIComponent(book.id) + '/chapters?page=' + (cursor?.page ?? 1));
}
export async function content(ctx, { book, chapter }) {
  return get(ctx, '/api/book/' + encodeURIComponent(book.id) + '/content/' + encodeURIComponent(chapter.id));
}
