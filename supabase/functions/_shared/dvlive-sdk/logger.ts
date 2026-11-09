export type LogLevel = "WARNING" | "INFO" | "DEBUG";

const priority: Record<LogLevel, number> = { WARNING: 0, INFO: 1, DEBUG: 2 };
const sensitiveKey = /token|secret|password|authorization|apikey|fingerprint|email|phone|uniqref|userref|firstname|lastname|useragent|subscription|picture|^ip$/i;

function collectSecrets(value: unknown, depth = 0): string[] {
  if (!value || typeof value !== "object" || depth > 8) return [];
  return Object.entries(value).flatMap(([key, item]) => {
    if (sensitiveKey.test(key.replace(/[-_]/g, "")) && typeof item === "string") {
      return [item, encodeURIComponent(item)];
    }
    return collectSecrets(item, depth + 1);
  });
}

function sanitize(value: unknown, secrets: readonly string[], depth = 0): unknown {
  if (depth > 8) return "[OMITTED]";
  if (typeof value === "string") {
    let result = value;
    for (const secret of secrets) {
      if (secret) result = result.split(secret).join("[REDACTED]");
    }
    return result
      .replace(/\b[NU]_[^\s"'<>]+/g, "[REDACTED]")
      .replace(/\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/g, "[REDACTED]")
      .replace(/[^\s@"<>]+@[^\s@"<>]+\.[^\s@"<>]+/g, "[REDACTED]");
  }
  if (Array.isArray(value)) return value.map(item => sanitize(item, secrets, depth + 1));
  if (value && typeof value === "object") {
    return Object.fromEntries(Object.entries(value).map(([key, item]) => [
      key, sensitiveKey.test(key.replace(/[-_]/g, "")) ? "[REDACTED]" : sanitize(item, secrets, depth + 1),
    ]));
  }
  return value;
}

/** Instance-local logging: no environment reads and no shared mutable state. */
export class DvLiveLogger {
  private readonly enabled: boolean;
  private readonly level: LogLevel;

  constructor(enable?: boolean | string, level?: string) {
    if (enable === undefined) this.enabled = false;
    else if (typeof enable === "boolean") this.enabled = enable;
    else if (typeof enable === "string" && /^(true|false)$/i.test(enable.trim())) this.enabled = enable.trim().toUpperCase() === "TRUE";
    else throw new TypeError("logEnable must be TRUE or FALSE.");

    const resolved = level === undefined ? "WARNING" : level.trim().toUpperCase();
    if (this.enabled && !Object.hasOwn(priority, resolved)) throw new TypeError("logLevel must be WARNING, INFO or DEBUG.");
    this.level = this.enabled ? resolved as LogLevel : "WARNING";
  }

  write(level: LogLevel, event: string, details: Record<string, unknown>, secrets: readonly string[] = []): void {
    if (!this.enabled || priority[level] > priority[this.level]) return;
    // A failing console must never change API behavior or hide the original error.
    try {
      const output = sanitize(details, [...secrets, ...collectSecrets(details)]);
      const prefix = `[DVLive][${level}] ${event}`;
      if (level === "WARNING") console.warn(prefix, output);
      else if (level === "INFO") console.info(prefix, output);
      else console.debug(prefix, output);
    } catch { /* Logging is best-effort. */ }
  }
}
