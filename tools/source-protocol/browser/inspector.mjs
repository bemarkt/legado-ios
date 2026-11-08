import { parseSource } from '../lib/static-parser.mjs';
import { validateValue, profile } from '../lib/contracts.mjs';
import { ContractError } from '../lib/errors.mjs';

function checked(action) {
  try { return { value: action() }; }
  catch (error) { return { error: error instanceof ContractError ? error.toJSON() : { code: 'INVALID_DATA', message: String(error.message) } }; }
}
export function inspect(source) {
  return checked(() => {
    if (new TextEncoder().encode(source).length > profile.limits.sourceBytes) throw new ContractError('RESOURCE_LIMIT', 'Source byte budget exceeded');
    return parseSource(source);
  });
}
export function validate(name, json) {
  return checked(() => {
    if (new TextEncoder().encode(json).length > profile.limits.outputBytes) throw new ContractError('RESOURCE_LIMIT', 'Result byte budget exceeded');
    validateValue(name, JSON.parse(json));
    return true;
  });
}
