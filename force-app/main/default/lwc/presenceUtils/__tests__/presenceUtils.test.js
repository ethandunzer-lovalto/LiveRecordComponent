import {
  BLANK,
  clampInteger,
  formatRelative,
  formatTime,
  formatValue,
  initials,
  isNewChange,
  nextDelaySeconds,
  reduceError,
  toModalSummary
} from "c/presenceUtils";

const FORMAT = {
  locale: "en-US",
  timeZone: "America/Los_Angeles",
  currency: "USD"
};
// Intl puts a narrow no-break space before AM/PM in newer ICU versions
const normalize = (text) => text.replace(/\s/g, " ");

describe("c-presence-utils", () => {
  describe("clampInteger", () => {
    it("keeps values within the range and falls back for missing ones", () => {
      expect(clampInteger(25, 15, 120, 25)).toBe(25);
      expect(clampInteger("40", 15, 120, 25)).toBe(40);
      expect(clampInteger(5, 15, 120, 25)).toBe(15);
      expect(clampInteger(500, 15, 120, 25)).toBe(120);
      expect(clampInteger(undefined, 15, 120, 25)).toBe(25);
      expect(clampInteger("abc", 0, 60, 0)).toBe(0);
    });
  });

  describe("nextDelaySeconds", () => {
    it("jitters the interval by up to 20% either way", () => {
      expect(nextDelaySeconds(25, 0, 0)).toBeCloseTo(20);
      expect(nextDelaySeconds(25, 0, 0.5)).toBeCloseTo(25);
      expect(nextDelaySeconds(25, 0, 1)).toBeCloseTo(30);
    });

    it("backs off exponentially after failures, up to 120 seconds", () => {
      expect(nextDelaySeconds(25, 1, 0.5)).toBe(50);
      expect(nextDelaySeconds(25, 2, 0.5)).toBe(100);
      expect(nextDelaySeconds(25, 3, 0.5)).toBe(120);
      expect(nextDelaySeconds(25, 10, 0.5)).toBe(120);
    });
  });

  describe("isNewChange", () => {
    const changed = { meaningfulChange: true, latestChangeMillis: 2000 };

    it("is true for a meaningful change not yet alerted on", () => {
      expect(isNewChange(changed, null, null)).toBe(true);
      expect(isNewChange(changed, 1000, 1000)).toBe(true);
    });

    it("is false for the change already alerted on, or an older one", () => {
      expect(isNewChange(changed, 2000, 1000)).toBe(false);
      expect(isNewChange(changed, 3000, 1000)).toBe(false);
    });

    it("is false when the page already shows the change", () => {
      expect(isNewChange(changed, null, 2000)).toBe(false);
    });

    it("is false when nothing meaningful changed", () => {
      expect(
        isNewChange(
          { meaningfulChange: false, latestChangeMillis: 2000 },
          null,
          null
        )
      ).toBe(false);
      expect(isNewChange({ meaningfulChange: true }, null, null)).toBe(false);
      expect(isNewChange(undefined, null, null)).toBe(false);
    });
  });

  describe("initials", () => {
    it("uses the first and last names", () => {
      expect(initials("Maria Lopez")).toBe("ML");
      expect(initials("Ana Maria de la Cruz")).toBe("AC");
      expect(initials("cher")).toBe("C");
      expect(initials("")).toBe("?");
      expect(initials(undefined)).toBe("?");
    });
  });

  describe("formatRelative", () => {
    const now = Date.parse("2026-10-10T18:00:00Z");

    it("describes how long ago in the largest whole unit", () => {
      expect(formatRelative(now - 40000, now, "en-US")).toBe("40 seconds ago");
      expect(formatRelative(now, now, "en-US")).toBe("1 second ago");
      expect(formatRelative(now - 5 * 60000, now, "en-US")).toBe(
        "5 minutes ago"
      );
      expect(formatRelative(now - 3 * 3600000, now, "en-US")).toBe(
        "3 hours ago"
      );
      expect(formatRelative(now - 2 * 86400000, now, "en-US")).toBe(
        "2 days ago"
      );
    });
  });

  describe("formatTime", () => {
    const now = Date.parse("2026-10-10T20:00:00Z");

    it("shows only the time for today, in the user time zone", () => {
      expect(
        normalize(
          formatTime(
            Date.parse("2026-10-10T21:14:00Z"),
            now,
            "en-US",
            "America/Los_Angeles"
          )
        )
      ).toBe("2:14 PM");
    });

    it("adds the date for another day", () => {
      expect(
        normalize(
          formatTime(
            Date.parse("2026-10-09T21:14:00Z"),
            now,
            "en-US",
            "America/Los_Angeles"
          )
        )
      ).toBe("Oct 9, 2:14 PM");
    });
  });

  describe("formatValue", () => {
    it("formats currency, without cents for whole amounts", () => {
      expect(formatValue("52000", "CURRENCY", FORMAT)).toBe("$52,000");
      expect(formatValue("40000.5", "CURRENCY", FORMAT)).toBe("$40,000.50");
      expect(
        formatValue("100", "CURRENCY", { ...FORMAT, currency: "EUR" })
      ).toBe("€100");
    });

    it("formats numbers, percents and booleans", () => {
      expect(formatValue("1500", "INTEGER", FORMAT)).toBe("1,500");
      expect(formatValue("2.5", "DOUBLE", FORMAT)).toBe("2.5");
      expect(formatValue("25", "PERCENT", FORMAT)).toBe("25%");
      expect(formatValue("true", "BOOLEAN", FORMAT)).toBe("True");
      expect(formatValue("false", "BOOLEAN", FORMAT)).toBe("False");
    });

    it("formats dates without shifting them a day", () => {
      expect(formatValue("2026-04-15", "DATE", FORMAT)).toBe("Apr 15, 2026");
    });

    it("formats date/times in the user time zone", () => {
      expect(
        normalize(
          formatValue(
            String(Date.parse("2026-05-01T19:30:00Z")),
            "DATETIME",
            FORMAT
          )
        )
      ).toBe("May 1, 2026, 12:30 PM");
    });

    it("shows text as it is, and empty values as blank", () => {
      expect(formatValue("Closed Won", "PICKLIST", FORMAT)).toBe("Closed Won");
      expect(formatValue(null, "STRING", FORMAT)).toBe(BLANK);
      expect(formatValue("", "STRING", FORMAT)).toBe(BLANK);
    });

    it("falls back to the raw value when it cannot be formatted", () => {
      expect(
        formatValue("12", "CURRENCY", { ...FORMAT, currency: "not a currency" })
      ).toBe("12");
    });
  });

  describe("toModalSummary", () => {
    const now = Date.parse("2026-10-10T18:00:40Z");
    const changedMillis = Date.parse("2026-10-10T18:00:00Z");
    const stageChange = {
      fieldLabel: "Stage",
      fieldType: "PICKLIST",
      valuesRecorded: true,
      oldValue: "Proposal",
      newValue: "Closed Won",
      changedByName: "Maria Lopez",
      changedMillis
    };

    it("names who changed the record and when, and what changed", () => {
      const summary = toModalSummary(
        {
          byName: "Maria Lopez",
          changedMillis,
          totalChanges: 2,
          changes: [
            stageChange,
            {
              ...stageChange,
              fieldLabel: "Amount",
              fieldType: "CURRENCY",
              oldValue: "40000",
              newValue: "52000"
            }
          ]
        },
        { nowMillis: now, ...FORMAT }
      );

      expect(summary.headline).toBe(
        "Maria Lopez saved changes 40 seconds ago."
      );
      expect(summary.hasChanges).toBe(true);
      expect(
        summary.changes.map(
          (change) => `${change.fieldLabel}: ${change.detail}`
        )
      ).toEqual(["Stage: Proposal → Closed Won", "Amount: $40,000 → $52,000"]);
      expect(summary.changes[0].changedByName).toBeNull();
      expect(summary.moreText).toBe("");
    });

    it("shows five changes, then how many more", () => {
      const changes = Array.from({ length: 7 }, (unused, index) => ({
        ...stageChange,
        fieldLabel: `Field ${index}`
      }));

      const summary = toModalSummary(
        { byName: "Maria Lopez", changedMillis, changes, totalChanges: 30 },
        { nowMillis: now, ...FORMAT }
      );

      expect(summary.changes).toHaveLength(5);
      expect(summary.moreText).toBe("+25 more changes");
      expect(
        toModalSummary(
          {
            byName: "A",
            changedMillis,
            changes: changes.slice(0, 6),
            totalChanges: 6
          },
          { nowMillis: now, ...FORMAT }
        ).moreText
      ).toBe("+1 more change");
    });

    it("names who made each change when several people changed the record", () => {
      const summary = toModalSummary(
        {
          byName: "Sam Lee",
          changedMillis,
          changes: [{ ...stageChange, changedByName: "Sam Lee" }, stageChange],
          totalChanges: 2
        },
        { nowMillis: now, ...FORMAT }
      );

      expect(summary.changes.map((change) => change.changedByName)).toEqual([
        "Sam Lee",
        "Maria Lopez"
      ]);
    });

    it('says "changed" when history has no values, and handles no history at all', () => {
      const summary = toModalSummary(
        {
          byName: "Maria Lopez",
          changedMillis,
          changes: [
            { ...stageChange, fieldLabel: "Notes", valuesRecorded: false }
          ],
          totalChanges: 1
        },
        { nowMillis: now, ...FORMAT }
      );
      expect(summary.changes[0].detail).toBe("changed");

      const noHistory = toModalSummary(
        { changedMillis },
        { nowMillis: now, ...FORMAT }
      );
      expect(noHistory.headline).toBe("Someone saved changes 40 seconds ago.");
      expect(noHistory.hasChanges).toBe(false);
    });
  });

  describe("reduceError", () => {
    it("finds the message in Apex and JavaScript errors", () => {
      expect(reduceError({ body: { message: "Apex failed" } })).toBe(
        "Apex failed"
      );
      expect(reduceError(new Error("Script failed"))).toBe("Script failed");
      expect(reduceError("plain")).toBe("plain");
      expect(reduceError(undefined)).toBe("Unknown error");
    });
  });
});
