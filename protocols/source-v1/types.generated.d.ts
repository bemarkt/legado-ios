// Generated from schema.json; do not edit. Candidate protocol; not an App SDK.
// Types describe shape; runtime semantic and resource validation remains required.

export type Json = null | boolean | number | string | Array<Json> | { [key: string]: Json };

export type SourceRef = {
  "id": string;
  "url"?: string;
  "state"?: Json;
};

export type Cover = {
  "url": string;
};

export type BookSummary = {
  "ref": SourceRef;
  "title": string;
  "author"?: string;
  "cover"?: Cover;
};

export type BookDetails = {
  "ref": SourceRef;
  "title": string;
  "author"?: string;
  "cover"?: Cover;
  "description"?: string;
  "status"?: "ongoing" | "completed" | "unknown";
};

export type Volume = {
  "id": string;
  "title": string;
};

export type Chapter = {
  "ref": SourceRef;
  "title": string;
  "volume"?: Volume;
};

export type SearchPage = {
  "items": Array<BookSummary>;
  "nextCursor": Json;
  "revision"?: string;
};

export type ChapterPage = {
  "items": Array<Chapter>;
  "nextCursor": Json;
  "revision"?: string;
};

export type TextBody = {
  "kind": "text";
  "text": string;
};

export type HTMLBody = {
  "kind": "html";
  "html": string;
  "baseURL": string;
};

export type ChapterContent = {
  "title"?: string;
  "revision"?: string;
  "body": TextBody | HTMLBody;
};

export type SearchInput = {
  "query": string;
  "cursor"?: Json;
};

export type BookInput = {
  "ref": SourceRef;
};

export type ChaptersInput = {
  "book": SourceRef;
  "cursor"?: Json;
};

export type ContentInput = {
  "book": SourceRef;
  "chapter": SourceRef;
};

export type TextSetting = {
  "type": "text";
  "label": string;
  "default": string;
  "maxLength": number;
};

export type BooleanSetting = {
  "type": "boolean";
  "label": string;
  "default": boolean;
};

export type EnumChoice = {
  "value": string;
  "label": string;
};

export type EnumSetting = {
  "type": "enum";
  "label": string;
  "default": string;
  "options": Array<EnumChoice>;
};

export type NumberSetting = {
  "type": "number";
  "label": string;
  "default": number;
  "minimum": number;
  "maximum": number;
};

export type Setting = TextSetting | BooleanSetting | EnumSetting | NumberSetting;

export type Metadata = {
  "apiVersion": 1;
  "id": string;
  "name": string;
  "version": string;
  "origins": Array<string>;
  "requires"?: Array<string>;
  "author"?: string;
  "homepage"?: string;
  "description"?: string;
  "settings"?: { [key: string]: Setting };
};

export type ErrorCode = "INVALID_INPUT" | "INVALID_RESULT" | "NETWORK" | "HTTP" | "RATE_LIMITED" | "AUTH_REQUIRED" | "PARSE" | "UNSUPPORTED" | "TIMEOUT" | "CANCELLED" | "RESOURCE_LIMIT" | "PERMISSION_DENIED" | "STORAGE_CONFLICT";

export type SourceError = {
  "code": ErrorCode;
  "message": string;
  "details"?: Json;
  "retryAfterMs"?: number;
};

export type StorageEntry = {
  "value": Json;
  "revision": string;
};
