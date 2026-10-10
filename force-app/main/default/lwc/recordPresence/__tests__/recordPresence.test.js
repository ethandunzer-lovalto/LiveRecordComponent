import { createElement } from "lwc";
import RecordPresence from "c/recordPresence";
import RecordPresenceModal from "c/recordPresenceModal";
import heartbeat from "@salesforce/apex/PresenceService.heartbeat";
import leave from "@salesforce/apex/PresenceService.leave";
import { getRecord, notifyRecordUpdateAvailable } from "lightning/uiRecordApi";

jest.mock(
  "@salesforce/apex/PresenceService.heartbeat",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/PresenceService.leave",
  () => ({ default: jest.fn() }),
  { virtual: true }
);
// Users without the admin permission
jest.mock(
  "@salesforce/customPermission/Record_Presence_Admin",
  () => ({ default: undefined }),
  { virtual: true }
);

const RECORD_ID = "006000000000001AAA";
// 11:00 AM in the test user's time zone (America/Los_Angeles)
const T0 = Date.parse("2026-10-10T18:00:00.000Z");

function snapshot(overrides) {
  return {
    enabled: true,
    viewers: [],
    meaningfulChange: false,
    changes: [],
    totalChanges: 0,
    storageMode: "CACHE",
    ...overrides
  };
}

// A snapshot reporting that someone else saved the record at changedMillis
function changedAt(changedMillis, byName = "Maria Lopez") {
  return snapshot({
    meaningfulChange: true,
    latestChangeMillis: changedMillis,
    latestChangeByName: byName,
    lastModifiedMillis: changedMillis,
    lastModifiedByName: byName,
    changes: [
      {
        fieldLabel: "Stage",
        fieldType: "PICKLIST",
        valuesRecorded: true,
        oldValue: "Proposal",
        newValue: "Closed Won",
        changedByName: byName,
        changedMillis
      }
    ],
    totalChanges: 1
  });
}

function viewer(index) {
  return {
    userId: `005000000000${String(index).padStart(3, "0")}AAA`,
    name: `Viewer ${index}`,
    smallPhotoUrl: `/photo/${index}`,
    lastSeenMillis: T0
  };
}

// Lets Apex promises and modal results settle without moving the fake clock
async function flush() {
  for (let i = 0; i < 10; i++) {
    // eslint-disable-next-line no-await-in-loop
    await Promise.resolve();
  }
}

async function advance(millis) {
  jest.advanceTimersByTime(millis);
  await flush();
}

let tabHidden = false;
// Resolves the modal that's open, like the user choosing a button
let closeModal;

describe("c-record-presence", () => {
  beforeAll(() => {
    Object.defineProperty(document, "hidden", {
      configurable: true,
      get: () => tabHidden
    });
  });

  beforeEach(() => {
    jest.useFakeTimers();
    jest.setSystemTime(T0 + 40000);
    // No jitter: heartbeats exactly every heartbeatSeconds
    jest.spyOn(Math, "random").mockReturnValue(0.5);
    tabHidden = false;
    heartbeat.mockResolvedValue(snapshot());
    leave.mockResolvedValue();
    RecordPresenceModal.open.mockImplementation(
      () =>
        new Promise((resolve) => {
          closeModal = resolve;
        })
    );
  });

  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
    jest.restoreAllMocks();
    jest.useRealTimers();
  });

  async function render(props = {}) {
    const element = createElement("c-record-presence", { is: RecordPresence });
    Object.assign(element, {
      recordId: RECORD_ID,
      objectApiName: "Opportunity",
      ...props
    });
    document.body.appendChild(element);
    await flush();
    return element;
  }

  // The version on the page, as Lightning Data Service reports it
  async function emitBaseline(millis) {
    getRecord.emit({
      fields: { LastModifiedDate: { value: new Date(millis).toISOString() } }
    });
    await flush();
  }

  // Renders with the page showing the version saved at T0, then has the next heartbeat report a change
  async function renderWithChange(props = {}, changeMillis = T0 + 5000) {
    const element = await render(props);
    await emitBaseline(T0);
    heartbeat.mockResolvedValue(changedAt(changeMillis));
    await advance(25000);
    return element;
  }

  const banner = (element) =>
    element.shadowRoot.querySelector("c-record-presence-banner");
  const avatars = (element) =>
    element.shadowRoot.querySelectorAll("lightning-avatar");

  describe("heartbeats", () => {
    it("sends one on connect and then every interval", async () => {
      await render();
      expect(heartbeat).toHaveBeenCalledTimes(1);
      expect(heartbeat).toHaveBeenCalledWith({
        recordId: RECORD_ID,
        baselineMillis: null,
        heartbeatSeconds: 25
      });

      await advance(24999);
      expect(heartbeat).toHaveBeenCalledTimes(1);
      await advance(1);
      expect(heartbeat).toHaveBeenCalledTimes(2);
    });

    it("uses the configured interval, within 15 to 120 seconds", async () => {
      await render({ heartbeatSeconds: 5 });
      expect(heartbeat).toHaveBeenLastCalledWith(
        expect.objectContaining({ heartbeatSeconds: 15 })
      );

      await advance(15000);
      expect(heartbeat).toHaveBeenCalledTimes(2);
    });

    it("sends the version on the page as the baseline, as LDS updates it", async () => {
      await render();
      await emitBaseline(T0);
      await advance(25000);
      expect(heartbeat).toHaveBeenLastCalledWith(
        expect.objectContaining({ baselineMillis: T0 })
      );

      await emitBaseline(T0 + 9000);
      await advance(25000);
      expect(heartbeat).toHaveBeenLastCalledWith(
        expect.objectContaining({ baselineMillis: T0 + 9000 })
      );
    });

    it("pauses while the tab is hidden and sends one as soon as it is visible again", async () => {
      await render();

      tabHidden = true;
      document.dispatchEvent(new CustomEvent("visibilitychange"));
      await advance(120000);
      expect(heartbeat).toHaveBeenCalledTimes(1);

      tabHidden = false;
      document.dispatchEvent(new CustomEvent("visibilitychange"));
      await flush();
      expect(heartbeat).toHaveBeenCalledTimes(2);

      await advance(25000);
      expect(heartbeat).toHaveBeenCalledTimes(3);
    });

    it("backs off after errors, hides avatars after three, and recovers", async () => {
      heartbeat.mockResolvedValue(snapshot({ viewers: [viewer(1)] }));
      const element = await render();
      expect(avatars(element)).toHaveLength(1);
      jest.spyOn(console, "error").mockImplementation(() => {});
      heartbeat.mockRejectedValue({ body: { message: "Server unavailable" } });

      await advance(25000); // first failure: next in 50s
      expect(heartbeat).toHaveBeenCalledTimes(2);
      await advance(49999);
      expect(heartbeat).toHaveBeenCalledTimes(2);
      await advance(1); // second failure: next in 100s
      expect(heartbeat).toHaveBeenCalledTimes(3);
      expect(avatars(element)).toHaveLength(1);
      await advance(100000); // third failure: avatars hidden, next in 120s
      expect(heartbeat).toHaveBeenCalledTimes(4);
      expect(avatars(element)).toHaveLength(0);

      heartbeat.mockResolvedValue(snapshot({ viewers: [viewer(1)] }));
      await advance(120000);
      expect(heartbeat).toHaveBeenCalledTimes(5);
      expect(avatars(element)).toHaveLength(1);
      await advance(25000);
      expect(heartbeat).toHaveBeenCalledTimes(6);
    });

    it("stops when the object has presence turned off", async () => {
      heartbeat.mockResolvedValue(
        snapshot({ enabled: false, viewers: [viewer(1)] })
      );
      const element = await render();

      await advance(300000);

      expect(heartbeat).toHaveBeenCalledTimes(1);
      expect(avatars(element)).toHaveLength(0);
    });

    it("leaves the record when removed from the page or when the page is hidden", async () => {
      const element = await render();

      window.dispatchEvent(new CustomEvent("pagehide"));
      expect(leave).toHaveBeenCalledWith({ recordId: RECORD_ID });

      document.body.removeChild(element);
      expect(leave).toHaveBeenCalledTimes(2);
      await advance(60000);
      expect(heartbeat).toHaveBeenCalledTimes(1);
    });

    it("starts over when the page is reused for another record", async () => {
      const element = await render();

      element.recordId = "006000000000002AAA";
      await flush();

      expect(leave).toHaveBeenCalledWith({ recordId: RECORD_ID });
      expect(heartbeat).toHaveBeenLastCalledWith(
        expect.objectContaining({
          recordId: "006000000000002AAA",
          baselineMillis: null
        })
      );
    });
  });

  describe("viewers", () => {
    it("shows other viewers with their names in an Also viewing card", async () => {
      heartbeat.mockResolvedValue(
        snapshot({ viewers: [viewer(1), viewer(2)] })
      );
      const element = await render();

      const card = element.shadowRoot.querySelector("lightning-card");
      expect(card.title).toBe("Also viewing");
      expect(card.querySelectorAll("lightning-avatar")).toHaveLength(2);
      const shown = [...avatars(element)];
      expect(shown.map((avatar) => avatar.alternativeText)).toEqual([
        "Viewer 1 is viewing",
        "Viewer 2 is viewing"
      ]);
      expect(shown[0].src).toBe("/photo/1");
      expect(shown[0].initials).toBe("V1");
      expect(element.shadowRoot.querySelector("li.stack-item").title).toBe(
        "Viewer 1 is viewing"
      );
    });

    it("collapses viewers beyond the maximum into +N", async () => {
      heartbeat.mockResolvedValue(
        snapshot({ viewers: [1, 2, 3, 4, 5, 6].map(viewer) })
      );
      const element = await render({ maxAvatars: 4 });

      expect(avatars(element)).toHaveLength(4);
      const overflow = element.shadowRoot.querySelector("li.overflow");
      expect(overflow.textContent).toBe("+2");
      expect(overflow.title).toBe("Also viewing: Viewer 5, Viewer 6");
    });

    it("renders nothing when no one else is here", async () => {
      const element = await render();

      expect(element.shadowRoot.querySelector("lightning-card")).toBeNull();
      expect(banner(element)).toBeNull();
      expect(element.shadowRoot.querySelector(".admin-status")).toBeNull();
      expect(
        element.shadowRoot.querySelector(".builder-placeholder")
      ).toBeNull();
    });

    it("can be turned off", async () => {
      heartbeat.mockResolvedValue(snapshot({ viewers: [viewer(1)] }));
      const element = await render({ showViewers: false });

      expect(avatars(element)).toHaveLength(0);
    });

    it("describes itself in Lightning App Builder, where it would otherwise be invisible", async () => {
      window.history.pushState({}, "", "/flexipageEditor/surface.app");
      try {
        const element = await render();
        expect(
          element.shadowRoot.querySelector(".builder-placeholder")
        ).not.toBeNull();
      } finally {
        window.history.pushState({}, "", "/");
      }
    });
  });

  describe("alerts", () => {
    it("opens the modal once per change, naming who changed what", async () => {
      await renderWithChange();

      expect(RecordPresenceModal.open).toHaveBeenCalledTimes(1);
      const options = RecordPresenceModal.open.mock.calls[0][0];
      expect(options.size).toBe("small");
      expect(options.autoRefreshSeconds).toBe(0);
      expect(options.summary.headline).toBe(
        "Maria Lopez saved changes 1 minute ago."
      );
      expect(options.summary.changes[0].detail).toBe("Proposal → Closed Won");

      closeModal("keep");
      await advance(25000);
      await advance(25000);
      expect(RecordPresenceModal.open).toHaveBeenCalledTimes(1);
    });

    it("opens again for a newer change", async () => {
      await renderWithChange();
      closeModal("keep");
      await flush();

      heartbeat.mockResolvedValue(changedAt(T0 + 60000, "Sam Lee"));
      await advance(25000);

      expect(RecordPresenceModal.open).toHaveBeenCalledTimes(2);
      expect(
        RecordPresenceModal.open.mock.calls[1][0].summary.headline
      ).toContain("Sam Lee");
    });

    it("shows a newer change in the open modal instead of opening another", async () => {
      await renderWithChange();
      const handle = { update: jest.fn(), close: jest.fn() };
      RecordPresenceModal.open.mock.calls[0][0].register(handle);

      heartbeat.mockResolvedValue(changedAt(T0 + 60000, "Sam Lee"));
      await advance(25000);

      expect(RecordPresenceModal.open).toHaveBeenCalledTimes(1);
      expect(handle.update).toHaveBeenCalledWith(
        expect.objectContaining({
          headline: expect.stringContaining("Sam Lee")
        })
      );
    });

    it("passes a newer change that arrives before the modal is ready", async () => {
      await renderWithChange();
      heartbeat.mockResolvedValue(changedAt(T0 + 60000, "Sam Lee"));
      await advance(25000);

      const handle = { update: jest.fn(), close: jest.fn() };
      RecordPresenceModal.open.mock.calls[0][0].register(handle);

      expect(RecordPresenceModal.open).toHaveBeenCalledTimes(1);
      expect(handle.update).toHaveBeenCalledWith(
        expect.objectContaining({
          headline: expect.stringContaining("Sam Lee")
        })
      );
    });

    it("refreshes the record through LDS when the user chooses Refresh now", async () => {
      const element = await renderWithChange();

      closeModal("refresh");
      await flush();

      expect(notifyRecordUpdateAvailable).toHaveBeenCalledWith([
        { recordId: RECORD_ID }
      ]);
      expect(banner(element)).toBeNull();
    });

    it("shows the banner after Keep working, until the user refreshes", async () => {
      const element = await renderWithChange();

      closeModal("keep");
      await flush();

      expect(banner(element).changedBy).toBe("Maria Lopez");
      expect(banner(element).changedAt.replace(/\s/g, " ")).toBe("11:00 AM");
      await advance(25000);
      expect(banner(element)).not.toBeNull();

      banner(element).dispatchEvent(new CustomEvent("refresh"));
      await flush();

      expect(notifyRecordUpdateAvailable).toHaveBeenCalledWith([
        { recordId: RECORD_ID }
      ]);
      expect(banner(element)).toBeNull();
    });

    it("shows the banner when the modal is closed with Escape or the close button", async () => {
      const element = await renderWithChange();

      closeModal(undefined);
      await flush();

      expect(banner(element)).not.toBeNull();
    });

    it("hides the banner when the page catches up with the change", async () => {
      const element = await renderWithChange();
      closeModal("keep");
      await flush();

      await emitBaseline(T0 + 5000);

      expect(banner(element)).toBeNull();
    });

    it("closes the modal when the page catches up with the change", async () => {
      const element = await renderWithChange();
      const handle = { update: jest.fn(), close: jest.fn() };
      RecordPresenceModal.open.mock.calls[0][0].register(handle);

      await emitBaseline(T0 + 5000);
      expect(handle.close).toHaveBeenCalledWith("current");
      closeModal("current");
      await flush();

      expect(banner(element)).toBeNull();
    });

    it("ignores a change the page already shows", async () => {
      await render();
      await emitBaseline(T0 + 5000);
      heartbeat.mockResolvedValue(changedAt(T0 + 5000));

      await advance(25000);

      expect(RecordPresenceModal.open).not.toHaveBeenCalled();
    });

    it("shows only the banner with the Banner only style", async () => {
      const element = await renderWithChange({ alertStyle: "Banner only" });

      expect(RecordPresenceModal.open).not.toHaveBeenCalled();
      expect(banner(element).changedBy).toBe("Maria Lopez");
    });

    it("passes the auto-refresh countdown, up to 60 seconds", async () => {
      await renderWithChange({ autoRefreshSeconds: 100 });

      expect(RecordPresenceModal.open.mock.calls[0][0].autoRefreshSeconds).toBe(
        60
      );
    });
  });
});
