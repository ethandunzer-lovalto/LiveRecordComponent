import { createElement } from "lwc";
import RecordPresenceModal from "c/recordPresenceModal";

const SUMMARY = {
  headline: "Maria Lopez saved changes 40 seconds ago.",
  hasChanges: true,
  changes: [
    {
      key: "1",
      fieldLabel: "Stage",
      detail: "Proposal → Closed Won",
      changedByName: null
    },
    {
      key: "2",
      fieldLabel: "Amount",
      detail: "$40,000 → $52,000",
      changedByName: null
    }
  ],
  moreText: "+2 more changes"
};

describe("c-record-presence-modal", () => {
  let closes;

  beforeEach(() => {
    jest.useFakeTimers();
    closes = [];
  });

  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.useRealTimers();
    jest.restoreAllMocks();
  });

  function render(props) {
    const element = createElement("c-record-presence-modal", {
      is: RecordPresenceModal
    });
    Object.assign(element, { summary: SUMMARY, ...props });
    element.addEventListener("modalclose", (event) =>
      closes.push(event.detail)
    );
    document.body.appendChild(element);
    return element;
  }

  const text = (element, selector) =>
    element.shadowRoot.querySelector(selector)?.textContent;
  const button = (element, id) =>
    element.shadowRoot.querySelector(`lightning-button[data-id="${id}"]`);

  it("shows who changed the record and what changed", () => {
    const element = render();

    expect(
      element.shadowRoot.querySelector("lightning-modal-header").label
    ).toBe("This record has been updated");
    expect(text(element, ".headline")).toBe(
      "Maria Lopez saved changes 40 seconds ago. The version you're looking at is out of date."
    );
    const changes = [...element.shadowRoot.querySelectorAll("li.change")].map(
      (item) => item.textContent
    );
    expect(changes).toEqual([
      "Stage:Proposal → Closed Won",
      "Amount:$40,000 → $52,000"
    ]);
    expect(text(element, "li.more")).toBe("+2 more changes");
  });

  it("leaves out the change list without history", () => {
    const element = render({
      summary: {
        headline: "Maria Lopez saved changes 5 seconds ago.",
        hasChanges: false,
        changes: [],
        moreText: ""
      }
    });

    expect(element.shadowRoot.querySelector("ul.changes")).toBeNull();
  });

  it("names who made each change when there are several people", () => {
    const element = render({
      summary: {
        ...SUMMARY,
        changes: [
          {
            key: "1",
            fieldLabel: "Stage",
            detail: "Proposal → Closed Won",
            changedByName: "Sam Lee"
          }
        ]
      }
    });

    expect(text(element, ".author")).toBe("(Sam Lee)");
  });

  it("focuses Refresh now when it opens", () => {
    const focus = jest.spyOn(HTMLElement.prototype, "focus");

    const element = render();

    expect(focus.mock.contexts).toContain(button(element, "refresh"));
    expect(button(element, "refresh").variant).toBe("brand");
  });

  it("takes focus back from the heading LightningModal focuses after opening", () => {
    const element = render();
    const focus = jest.spyOn(HTMLElement.prototype, "focus");

    element.shadowRoot
      .querySelector("lightning-modal-header")
      .dispatchEvent(
        new CustomEvent("focusin", { bubbles: true, composed: true })
      );

    expect(focus.mock.contexts).toEqual([button(element, "refresh")]);
  });

  it("lets the user move focus once they click or press a key", () => {
    const element = render();
    const focus = jest.spyOn(HTMLElement.prototype, "focus");

    button(element, "keep").dispatchEvent(
      new CustomEvent("keydown", { bubbles: true, composed: true })
    );
    button(element, "keep").dispatchEvent(
      new CustomEvent("focusin", { bubbles: true, composed: true })
    );

    expect(focus).not.toHaveBeenCalled();
  });

  it("closes with refresh or keep", () => {
    const element = render();

    button(element, "refresh").click();
    button(element, "keep").click();

    expect(closes).toEqual(["refresh", "keep"]);
  });

  it("has no countdown unless auto-refresh is on", async () => {
    const element = render();
    await Promise.resolve();

    expect(element.shadowRoot.querySelector(".countdown")).toBeNull();
    jest.advanceTimersByTime(120000);
    expect(closes).toEqual([]);
  });

  it("counts down and refreshes at zero", async () => {
    const element = render({ autoRefreshSeconds: 3 });
    await Promise.resolve();
    expect(text(element, ".countdown")).toBe("Refreshing in 3s…");

    jest.advanceTimersByTime(1000);
    await Promise.resolve();
    expect(text(element, ".countdown")).toBe("Refreshing in 2s…");

    jest.advanceTimersByTime(2000);
    expect(closes).toEqual(["refresh"]);
  });

  it("stops the countdown when the user clicks in the modal", async () => {
    const element = render({ autoRefreshSeconds: 3 });

    element.shadowRoot.querySelector(".headline").click();
    jest.advanceTimersByTime(10000);
    await Promise.resolve();

    expect(closes).toEqual([]);
    expect(element.shadowRoot.querySelector(".countdown")).toBeNull();
  });

  it("stops the countdown when the user presses a key, such as Tab to a button", () => {
    const element = render({ autoRefreshSeconds: 3 });

    button(element, "keep").dispatchEvent(
      new KeyboardEvent("keydown", {
        key: "Tab",
        bubbles: true,
        composed: true
      })
    );
    jest.advanceTimersByTime(10000);

    expect(closes).toEqual([]);
  });

  it("lets the page show a newer change, which restarts the countdown", async () => {
    let handle;
    const element = render({
      autoRefreshSeconds: 3,
      register: (registered) => (handle = registered)
    });
    jest.advanceTimersByTime(2000);

    handle.update({
      ...SUMMARY,
      headline: "Sam Lee saved changes 1 second ago."
    });
    await Promise.resolve();

    expect(text(element, ".headline")).toContain(
      "Sam Lee saved changes 1 second ago."
    );
    expect(text(element, ".countdown")).toBe("Refreshing in 3s…");
    jest.advanceTimersByTime(2000);
    expect(closes).toEqual([]);
    jest.advanceTimersByTime(1000);
    expect(closes).toEqual(["refresh"]);
  });

  it("lets the page close it", () => {
    let handle;
    render({ register: (registered) => (handle = registered) });

    handle.close("current");

    expect(closes).toEqual(["current"]);
  });
});
