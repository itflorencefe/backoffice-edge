/** Small decoding primitives; endpoint decoders select fields explicitly. */
export function object(value: unknown, path: string): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new TypeError(`${path} must be an object.`);
  }
  return value as Record<string, unknown>;
}

export function string(value: unknown, path: string): string {
  if (typeof value !== "string") throw new TypeError(`${path} must be a string.`);
  return value;
}

export function integer(value: unknown, path: string): number {
  if (typeof value !== "number" || !Number.isInteger(value)) {
    throw new TypeError(`${path} must be an integer.`);
  }
  return value;
}

export function nullable<T>(value: unknown, decode: (value: unknown, path: string) => T, path: string): T | null {
  return value === null ? null : decode(value, path);
}

export function array<T>(value: unknown, decode: (value: unknown, path: string) => T, path: string): T[] {
  if (!Array.isArray(value)) throw new TypeError(`${path} must be an array.`);
  return value.map((item: unknown, index: number) => decode(item, `${path}[${index}]`));
}
