import { ApiValidationError } from "../ApiErrors.ts";

export function pathParameter(value: string, name: string): void {
  if (typeof value !== "string" || !value.trim() || value === "." || value === "..") {
    throw new ApiValidationError(`${name} must be a non-empty path parameter.`);
  }
}

export function optionalString(value: string | undefined, name: string): void {
  if (value !== undefined && typeof value !== "string") throw new ApiValidationError(`${name} must be a string.`);
}

export function positiveInteger(value: number, name: string): void {
  if (typeof value !== "number" || !Number.isInteger(value) || value <= 0) {
    throw new ApiValidationError(`${name} must be a positive integer.`);
  }
}
