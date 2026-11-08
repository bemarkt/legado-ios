import { readFileSync } from 'node:fs';
import Ajv2020 from 'ajv/dist/2020.js';
import { createContracts } from './contract-core.mjs';

export const schema = JSON.parse(readFileSync(new URL('../../../protocols/source-v1/schema.json', import.meta.url), 'utf8'));
export const profile = JSON.parse(readFileSync(new URL('../../../protocols/source-v1/profile.json', import.meta.url), 'utf8'));
const ajv = new Ajv2020({ strict: true, allErrors: false, ownProperties: true });
ajv.addSchema(schema);
const validators = Object.fromEntries(Object.keys(schema.$defs).map(name => [name, ajv.getSchema(`${schema.$id}#/$defs/${name}`)]));
export const { validateValue, assertJSON } = createContracts(schema, profile, validators);
