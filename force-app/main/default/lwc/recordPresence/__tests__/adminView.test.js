import { createElement } from "lwc";
import RecordPresence from "c/recordPresence";
import heartbeat from "@salesforce/apex/PresenceService.heartbeat";
import leave from "@salesforce/apex/PresenceService.leave";

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
// Users with the Record_Presence_Admin custom permission
jest.mock(
  "@salesforce/customPermission/Record_Presence_Admin",
  () => ({ default: true }),
  { virtual: true }
);

const ADMIN_INFO = {
  objectApiName: "Opportunity",
  historyObject: "OpportunityFieldHistory",
  watchedFields: ["StageName", "Amount"],
  untrackedWatchedFields: ["Amount"],
  unknownWatchedFields: ["Stge"]
};

async function flush() {
  for (let i = 0; i < 10; i++) {
    // eslint-disable-next-line no-await-in-loop
    await Promise.resolve();
  }
}

describe("c-record-presence admin view", () => {
  beforeEach(() => {
    leave.mockResolvedValue();
    // jsdom has no layout: report the record page as on screen
    jest.spyOn(Element.prototype, "getClientRects").mockReturnValue([{}]);
  });

  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
    jest.restoreAllMocks();
  });

  async function render(props = {}) {
    const element = createElement("c-record-presence", { is: RecordPresence });
    Object.assign(element, {
      recordId: "006000000000001AAA",
      objectApiName: "Opportunity",
      ...props
    });
    document.body.appendChild(element);
    await flush();
    return element;
  }

  const status = (element) =>
    element.shadowRoot.querySelector(".admin-status p").textContent;

  it("shows the storage mode, watched fields and heartbeat interval", async () => {
    heartbeat.mockResolvedValue({
      enabled: true,
      viewers: [],
      storageMode: "CACHE",
      adminInfo: {
        ...ADMIN_INFO,
        unknownWatchedFields: [],
        untrackedWatchedFields: []
      }
    });

    const element = await render();

    expect(status(element)).toContain(
      "Record presence: Platform Cache · 2 watched fields · heartbeat every 25s"
    );
    expect(
      element.shadowRoot.querySelector(".admin-status lightning-icon").iconName
    ).toBe("utility:info");
  });

  it("flags watched fields that changes cannot be detected on", async () => {
    heartbeat.mockResolvedValue({
      enabled: true,
      viewers: [],
      storageMode: "OBJECT",
      adminInfo: ADMIN_INFO
    });
    const element = await render();

    expect(status(element)).toContain(
      "Presence object (no cache capacity) · 2 watched fields · heartbeat every 25s · 2 watched fields need attention"
    );
    expect(
      element.shadowRoot.querySelector(".admin-status lightning-icon").iconName
    ).toBe("utility:warning");

    element.shadowRoot.querySelector("button.details-toggle").click();
    await flush();

    const details = element.shadowRoot.querySelector(".details-popover");
    expect(details.querySelector(".storage").textContent).toBe(
      "Presence object (no cache capacity)"
    );
    expect(details.textContent).toContain("Every 25 seconds (±20%)");
    expect(details.textContent).toContain("OpportunityFieldHistory");
    const rows = [...details.querySelectorAll(".watched-fields li")].map(
      (row) => row.textContent
    );
    expect(rows).toEqual([
      "StageNameHistory-tracked",
      "AmountNot history-tracked: changes can't be detected",
      "StgeNot a field on Opportunity"
    ]);
  });

  it("says when any change alerts and the object has no field history", async () => {
    heartbeat.mockResolvedValue({
      enabled: true,
      viewers: [],
      storageMode: "CACHE",
      adminInfo: {
        objectApiName: "Opportunity",
        historyObject: null,
        watchedFields: [],
        untrackedWatchedFields: [],
        unknownWatchedFields: []
      }
    });
    const element = await render();

    expect(status(element)).toContain("any change alerts");
    element.shadowRoot.querySelector("button.details-toggle").click();
    await flush();

    const details = element.shadowRoot.querySelector(".details-popover");
    expect(details.textContent).toContain(
      "None: field history tracking isn't turned on for this object"
    );
    expect(details.textContent).toContain(
      "None: any change by another user alerts."
    );
  });

  it("closes the details with Escape or the close button", async () => {
    heartbeat.mockResolvedValue({
      enabled: true,
      viewers: [],
      storageMode: "CACHE",
      adminInfo: ADMIN_INFO
    });
    const element = await render();
    const toggle = element.shadowRoot.querySelector("button.details-toggle");

    toggle.click();
    await flush();
    expect(toggle.getAttribute("aria-expanded")).toBe("true");
    element.shadowRoot
      .querySelector(".details-popover")
      .dispatchEvent(new KeyboardEvent("keydown", { key: "Escape" }));
    await flush();
    expect(element.shadowRoot.querySelector(".details-popover")).toBeNull();

    toggle.click();
    await flush();
    element.shadowRoot.querySelector(".slds-popover__close").click();
    await flush();
    expect(element.shadowRoot.querySelector(".details-popover")).toBeNull();
  });

  it("shows heartbeat errors instead of a toast", async () => {
    jest.spyOn(console, "error").mockImplementation(() => {});
    heartbeat.mockRejectedValue({
      body: { message: "Unable to check record presence: boom" }
    });

    const element = await render();

    expect(status(element)).toContain(
      "the last heartbeat failed (Unable to check record presence: boom). Retrying in up to 50s."
    );
  });

  it("says when presence is turned off for the object", async () => {
    heartbeat.mockResolvedValue({ enabled: false, viewers: [] });

    const element = await render();

    expect(status(element)).toContain(
      "Record presence is turned off for Opportunity in its Record Presence Object settings."
    );
  });

  it("describes the component before there is a record, as in Lightning App Builder", async () => {
    const element = await render({ recordId: undefined });

    expect(heartbeat).not.toHaveBeenCalled();
    expect(status(element)).toContain("shows who else is viewing the record");
  });

  it("says it is connecting until the first heartbeat returns", async () => {
    heartbeat.mockReturnValue(new Promise(() => {}));

    const element = await render();

    expect(status(element)).toContain("Record presence: connecting…");
  });
});
