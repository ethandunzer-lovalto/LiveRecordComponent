import { createElement } from "lwc";
import RecordPresenceBanner from "c/recordPresenceBanner";

describe("c-record-presence-banner", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
  });

  function render(props) {
    const element = createElement("c-record-presence-banner", {
      is: RecordPresenceBanner
    });
    Object.assign(element, props);
    document.body.appendChild(element);
    return element;
  }

  it("says who last changed the record and when", () => {
    const element = render({ changedBy: "Maria Lopez", changedAt: "2:14 PM" });

    const banner = element.shadowRoot.querySelector(".slds-alert_warning");
    expect(banner.textContent).toContain(
      "You're viewing an outdated version. Last changed by Maria Lopez at 2:14 PM."
    );
  });

  it("asks the page to refresh", () => {
    const element = render({ changedBy: "Maria Lopez", changedAt: "2:14 PM" });
    const handler = jest.fn();
    element.addEventListener("refresh", handler);

    element.shadowRoot.querySelector("button.banner-link").click();

    expect(handler).toHaveBeenCalledTimes(1);
  });
});
