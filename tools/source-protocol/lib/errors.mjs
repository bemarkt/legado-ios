export class ContractError extends Error {
  constructor(code, message, details = {}) {
    super(message);
    this.name = 'ContractError';
    this.code = code;
    Object.assign(this, details);
  }
  toJSON() {
    const { code, message, path, line, column, diagnostics } = this;
    return { code, message, ...(path ? { path } : {}),
      ...(line ? { line, column } : {}), ...(diagnostics ? { diagnostics } : {}) };
  }
}
