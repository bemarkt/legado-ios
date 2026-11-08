import { parse } from 'acorn';
import { validateValue, profile } from './contracts.mjs';
import { ContractError } from './errors.mjs';

const operations = ['search', 'book', 'chapters', 'content'];
function fail(code, message, node) {
  throw new ContractError(code, message, { line: node?.loc?.start.line, column: node ? node.loc.start.column + 1 : undefined });
}
function literal(node) {
  if (node.type === 'Literal' && !node.regex && !node.bigint &&
      (node.value === null || ['string', 'number', 'boolean'].includes(typeof node.value))) return node.value;
  if (node.type === 'UnaryExpression' && node.operator === '-' && node.argument.type === 'Literal' && typeof node.argument.value === 'number') return -node.argument.value;
  if (node.type === 'ArrayExpression') return node.elements.map(child => {
    if (!child) fail('METADATA_NOT_STATIC', 'Sparse metadata arrays are forbidden', node);
    return literal(child);
  });
  if (node.type === 'ObjectExpression') {
    const value = Object.create(null);
    for (const property of node.properties) {
      if (property.type !== 'Property' || property.computed || property.method || property.shorthand || property.kind !== 'init') fail('METADATA_NOT_STATIC', 'Expected an ordinary literal property', property);
      const key = property.key.type === 'Identifier' ? property.key.name : property.key.value;
      if (typeof key !== 'string' || ['__proto__', 'prototype', 'constructor'].includes(key)) fail('METADATA_NOT_STATIC', 'Unsupported metadata key', property);
      if (Object.hasOwn(value, key)) fail('DUPLICATE_KEY', `Duplicate metadata key: ${key}`, property);
      value[key] = literal(property.value);
    }
    return value;
  }
  fail('METADATA_NOT_STATIC', 'Metadata must contain only literal JSON data', node);
}

// Call via inspectSource(), which executes this parser in a bounded worker.
// The parser traverses syntax only. It never imports or evaluates source text.
export function parseSource(source) {
  let ast;
  try { ast = parse(source, { ecmaVersion: profile.ecmaVersion, sourceType: 'module', locations: true }); }
  catch (error) { throw new ContractError('SYNTAX_ERROR', error.message, { line: error.loc?.line, column: error.loc ? error.loc.column + 1 : undefined }); }
  const stack = [{ node: ast, depth: 0, inFunction: false }];
  let nodes = 0;
  while (stack.length) {
    const { node, depth, inFunction } = stack.pop();
    if (++nodes > profile.limits.astNodes || depth > profile.limits.astDepth) fail('RESOURCE_LIMIT', 'AST budget exceeded', node);
    if (['ImportDeclaration', 'ImportExpression', 'ExportAllDeclaration'].includes(node.type) || node.source) fail('EXTERNAL_MODULE', 'External modules and dynamic import are not part of v1', node);
    if (!inFunction && (node.type === 'AwaitExpression' || (node.type === 'ForOfStatement' && node.await))) fail('TOP_LEVEL_AWAIT', 'Module initialization must be synchronous', node);
    const childFunction = inFunction || ['FunctionDeclaration', 'FunctionExpression', 'ArrowFunctionExpression'].includes(node.type);
    for (const [key, child] of Object.entries(node)) {
      if (['loc', 'start', 'end'].includes(key)) continue;
      if (Array.isArray(child)) {
        for (const item of child) if (item && typeof item.type === 'string') stack.push({ node: item, depth: depth + 1, inFunction: childFunction });
      } else if (child && typeof child.type === 'string') stack.push({ node: child, depth: depth + 1, inFunction: childFunction });
    }
  }
  const bindings = new Map();
  const exported = new Map();
  let metadataNode;
  for (const statement of ast.body) {
    if (statement.type === 'ExportDefaultDeclaration') fail('UNSUPPORTED_EXPORT', 'Default export is not a source entry', statement);
    const declaration = statement.type === 'ExportNamedDeclaration' ? statement.declaration : statement;
    if (declaration?.type === 'FunctionDeclaration') bindings.set(declaration.id.name, declaration);
    if (declaration?.type === 'VariableDeclaration') for (const binding of declaration.declarations) {
      if (binding.id.type !== 'Identifier') continue;
      bindings.set(binding.id.name, binding.init);
      if (statement.type === 'ExportNamedDeclaration' && binding.id.name === 'metadata') {
        if (declaration.kind !== 'const') fail('METADATA_NOT_STATIC', 'metadata must be const', binding);
        metadataNode = binding.init;
      }
    }
    if (statement.type !== 'ExportNamedDeclaration') continue;
    if (declaration?.type === 'FunctionDeclaration') exported.set(declaration.id.name, declaration.id.name);
    if (declaration?.type === 'VariableDeclaration') for (const binding of declaration.declarations) {
      if (binding.id.type !== 'Identifier') fail('UNSUPPORTED_EXPORT', 'Exported bindings must be identifiers', binding);
      exported.set(binding.id.name, binding.id.name);
    }
    for (const specifier of statement.specifiers) exported.set(specifier.exported.name ?? specifier.exported.value, specifier.local.name);
  }
  if (!metadataNode) fail('MISSING_METADATA', 'Expected direct export const metadata = {...}', ast);
  const metadata = literal(metadataNode);
  try { validateValue('Metadata', metadata); } catch (error) {
    throw new ContractError(error.code, error.message, { line: metadataNode.loc.start.line, column: metadataNode.loc.start.column + 1, path: error.path, diagnostics: error.diagnostics });
  }
  for (const name of exported.keys()) if (name !== 'metadata' && !operations.includes(name)) fail('UNSUPPORTED_EXPORT', `Unknown v1 export: ${name}`, ast);
  for (const name of ['book', 'chapters', 'content']) if (!exported.has(name)) fail('MISSING_OPERATION', `Missing ${name}`, ast);
  for (const name of operations.filter(name => exported.has(name))) {
    const binding = bindings.get(exported.get(name));
    if (!binding || !['FunctionDeclaration', 'FunctionExpression', 'ArrowFunctionExpression'].includes(binding.type) || !binding.async || binding.generator) fail('INVALID_OPERATION', `${name} must bind to an async function`, binding ?? ast);
  }
  const unsupported = (metadata.requires ?? []).filter(name => !profile.extensions.includes(name));
  return { metadata, operations: operations.filter(name => exported.has(name)), unsupportedRequirements: unsupported, astNodes: nodes };
}
