// Helpers for the record presence components: heartbeat timing, deciding when to alert, and formatting for the user's
// locale and time zone. No component state, so they're easy to test.

export const DEFAULT_HEARTBEAT_SECONDS = 25;
export const MIN_HEARTBEAT_SECONDS = 15;
export const MAX_HEARTBEAT_SECONDS = 120;
// Longest wait between heartbeats while backing off after errors
export const MAX_BACKOFF_SECONDS = 120;
// The modal lists this many changes, then "+N more"
export const MAX_SHOWN_CHANGES = 5;
// Shown for an empty old or new value
export const BLANK = "(blank)";

// An integer property from Lightning App Builder, kept within min and max; fallback if it's missing or not a number.
export function clampInteger(value, min, max, fallback) {
  const number = Number.parseInt(value, 10);
  if (Number.isNaN(number)) {
    return fallback;
  }
  return Math.min(Math.max(number, min), max);
}

// Seconds until the next heartbeat. Normally the interval with ±20% jitter, so many tabs don't fire at the same moment.
// After failures, the interval doubles per failure (25, 50, 100...) up to MAX_BACKOFF_SECONDS.
export function nextDelaySeconds(
  intervalSeconds,
  failures,
  random = Math.random()
) {
  if (failures > 0) {
    return Math.min(intervalSeconds * 2 ** failures, MAX_BACKOFF_SECONDS);
  }
  return intervalSeconds * (0.8 + random * 0.4);
}

// Whether a heartbeat reports a meaningful change this tab hasn't alerted on, and that the page doesn't already show
// (the record can reload while a heartbeat is in flight).
export function isNewChange(snapshot, lastAlertedMillis, baselineMillis) {
  if (!snapshot || !snapshot.meaningfulChange || !snapshot.latestChangeMillis) {
    return false;
  }
  if (
    lastAlertedMillis != null &&
    snapshot.latestChangeMillis <= lastAlertedMillis
  ) {
    return false;
  }
  return baselineMillis == null || snapshot.latestChangeMillis > baselineMillis;
}

// "ML" for "Maria Lopez": first letters of the first and last names
export function initials(name) {
  const words = (name || "").trim().split(/\s+/).filter(Boolean);
  if (words.length === 0) {
    return "?";
  }
  const letters =
    words.length === 1 ? words[0][0] : words[0][0] + words[words.length - 1][0];
  return letters.toUpperCase();
}

// "40 seconds ago", "5 minutes ago"... in the user's locale
export function formatRelative(thenMillis, nowMillis, locale) {
  const format = new Intl.RelativeTimeFormat(locale, { numeric: "always" });
  const seconds = Math.max(1, Math.round((nowMillis - thenMillis) / 1000));
  if (seconds < 60) {
    return format.format(-seconds, "second");
  }
  const minutes = Math.round(seconds / 60);
  if (minutes < 60) {
    return format.format(-minutes, "minute");
  }
  const hours = Math.round(minutes / 60);
  if (hours < 24) {
    return format.format(-hours, "hour");
  }
  return format.format(-Math.round(hours / 24), "day");
}

// "2:14 PM", or "Oct 9, 2:14 PM" if it wasn't today, in the user's locale and time zone
export function formatTime(millis, nowMillis, locale, timeZone) {
  const day = new Intl.DateTimeFormat(locale, {
    timeZone,
    year: "numeric",
    month: "numeric",
    day: "numeric"
  });
  const sameDay = day.format(millis) === day.format(nowMillis);
  const options = sameDay
    ? { timeZone, hour: "numeric", minute: "2-digit" }
    : {
        timeZone,
        month: "short",
        day: "numeric",
        hour: "numeric",
        minute: "2-digit"
      };
  return new Intl.DateTimeFormat(locale, options).format(millis);
}

// A field history value from PresenceService, formatted by field type. Numbers come as plain decimals, dates as
// yyyy-MM-dd and date/times as epoch millis; anything that can't be formatted is shown as it came.
export function formatValue(value, fieldType, { locale, timeZone, currency }) {
  if (value === null || value === undefined || value === "") {
    return BLANK;
  }
  try {
    switch (fieldType) {
      case "CURRENCY": {
        const amount = Number(value);
        // Whole amounts without cents, like "$52,000"
        const digits = Number.isInteger(amount) ? 0 : 2;
        return new Intl.NumberFormat(locale, {
          style: "currency",
          currency,
          minimumFractionDigits: digits,
          maximumFractionDigits: 2
        }).format(amount);
      }
      case "PERCENT":
        return new Intl.NumberFormat(locale, {
          style: "percent",
          maximumFractionDigits: 2
        }).format(Number(value) / 100);
      case "DOUBLE":
      case "INTEGER":
      case "LONG":
        return new Intl.NumberFormat(locale).format(Number(value));
      case "DATE": {
        const [year, month, dayOfMonth] = value.split("-").map(Number);
        // A date has no time zone: format it as UTC so it doesn't shift a day
        return new Intl.DateTimeFormat(locale, {
          dateStyle: "medium",
          timeZone: "UTC"
        }).format(Date.UTC(year, month - 1, dayOfMonth));
      }
      case "DATETIME":
        return new Intl.DateTimeFormat(locale, {
          dateStyle: "medium",
          timeStyle: "short",
          timeZone
        }).format(Number(value));
      case "BOOLEAN":
        return value === "true" ? "True" : "False";
      default:
        return String(value);
    }
  } catch {
    return String(value);
  }
}

// What the modal shows for a change: who saved it and when, then up to MAX_SHOWN_CHANGES field changes. Each change
// names who made it only when several people changed the record.
export function toModalSummary(
  stale,
  { nowMillis, locale, timeZone, currency }
) {
  const changes = stale.changes || [];
  const showAuthors =
    new Set(changes.map((change) => change.changedByName)).size > 1;
  const shown = changes.slice(0, MAX_SHOWN_CHANGES).map((change, index) => ({
    key: `${change.changedMillis}-${index}`,
    fieldLabel: change.fieldLabel,
    detail:
      change.valuesRecorded === false
        ? "changed"
        : `${formatValue(change.oldValue, change.fieldType, { locale, timeZone, currency })} → ${formatValue(
            change.newValue,
            change.fieldType,
            { locale, timeZone, currency }
          )}`,
    changedByName: showAuthors ? change.changedByName : null
  }));
  const moreCount =
    Math.max(stale.totalChanges || 0, changes.length) - shown.length;
  return {
    headline: `${stale.byName || "Someone"} saved changes ${formatRelative(stale.changedMillis, nowMillis, locale)}.`,
    changes: shown,
    hasChanges: shown.length > 0,
    moreCount,
    moreText:
      moreCount > 0
        ? `+${moreCount} more ${moreCount === 1 ? "change" : "changes"}`
        : ""
  };
}

// The message from an Apex or JavaScript error
export function reduceError(error) {
  if (!error) {
    return "Unknown error";
  }
  if (error.body && error.body.message) {
    return error.body.message;
  }
  return error.message || String(error);
}
