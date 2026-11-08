import type { SourceContext } from '../../../protocols/source-v1/context';
import type { BookInput, ContentInput } from '../../../protocols/source-v1/types.generated';
import { title, paragraphs } from './catalog';

export const metadata = {
  apiVersion: 1,
  id: 'org.example.built-offline',
  name: '多文件离线示例',
  version: '1.0.0',
  origins: ['https://example.org']
};
export async function search() {
  return { items: [{ ref: { id: 'demo' }, title }], nextCursor: null };
}
export async function book(ctx: SourceContext, { ref }: BookInput) {
  return { ref, title, description: '本示例不会访问网络。' };
}
export async function chapters() {
  return { items: Object.keys(paragraphs).map((id, index) => ({ ref: { id }, title: `第 ${index + 1} 章` })), nextCursor: null };
}
export async function content(ctx: SourceContext, { chapter }: ContentInput) {
  const text = paragraphs[chapter.id];
  if (!text) throw ctx.errors.parse({ field: 'chapter.id', message: '找不到该章节，请刷新目录' });
  return { body: { kind: 'text', text } };
}
