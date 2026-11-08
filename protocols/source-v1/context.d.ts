/** Candidate handwritten host/method contract. Data shapes come from schema.json. */
import type { Json, SearchInput, BookInput, ChaptersInput, ContentInput, SearchPage, BookDetails, ChapterPage, ChapterContent, SourceError, StorageEntry } from './types.generated';

export interface SourceHTTPResponse {
  readonly status: number;
  readonly ok: boolean;
  readonly url: string;
  readonly headers: Readonly<Record<string, string>>;
  readonly bodyUsed: boolean;
  text(): Promise<string>;
  json(): Promise<Json>;
  bytes(): Promise<Uint8Array>;
}
export interface SourceHTTP {
  fetch(url: string, init?: {
    method?: 'GET' | 'HEAD' | 'POST' | 'PUT' | 'PATCH' | 'DELETE';
    headers?: Readonly<Record<string, string>>;
    body?: string | Uint8Array;
    redirect?: 'follow' | 'error';
    signal?: AbortSignal;
  }): Promise<SourceHTTPResponse>;
}
export interface SourceStorage {
  get(key: string): Promise<StorageEntry | null>;
  set(key: string, value: Json, options?: { ifRevision: string | null }): Promise<StorageEntry>;
  remove(key: string, options?: { ifRevision: string | null }): Promise<void>;
}
export interface SourceErrors {
  http(details: { status: number; url?: string; retryAfterMs?: number }): Error & SourceError;
  parse(details: { field: string; message: string }): Error & SourceError;
  authRequired(details?: { message?: string }): Error & SourceError;
}
export interface SourceContext {
  readonly signal: AbortSignal;
  readonly config: Readonly<Record<string, Json>>;
  readonly http: SourceHTTP;
  readonly storage: SourceStorage;
  readonly errors: SourceErrors;
  readonly log: {
    debug(message: string, details?: Json): void;
    info(message: string, details?: Json): void;
    warn(message: string, details?: Json): void;
    error(message: string, details?: Json): void;
  };
}
export interface SourceOperations {
  search?(ctx: SourceContext, input: SearchInput): Promise<SearchPage>;
  book(ctx: SourceContext, input: BookInput): Promise<BookDetails>;
  chapters(ctx: SourceContext, input: ChaptersInput): Promise<ChapterPage>;
  content(ctx: SourceContext, input: ContentInput): Promise<ChapterContent>;
}
