import { ApiValidationError } from "../ApiErrors.ts";

/** Unknown JSON is handled only at the decoding boundary. Extra fields are ignored. */
export function bodyObject(value: unknown): Record<string, unknown> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) {
    throw new ApiValidationError("The request body must be a JSON object.");
  }
  return value as Record<string, unknown>;
}

export function string(value: unknown, name: string): string {
  if (typeof value !== "string") throw new ApiValidationError(`${name} must be a string.`);
  return value;
}

export function optionalString(value: unknown, name: string): string | undefined {
  return value === undefined ? undefined : string(value, name);
}

export function optionalPhone(value: unknown): string | null | undefined {
  if (value === undefined || value === null || typeof value === "string") return value;
  throw new ApiValidationError("phone must be a string or null.");
}

export function number(value: unknown, name: string): number {
  if (typeof value !== "number") throw new ApiValidationError(`${name} must be a positive integer.`);
  return value;
}
