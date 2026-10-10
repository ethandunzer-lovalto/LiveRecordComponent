import { LightningElement, api } from "lwc";

// The sticky warning shown after the user chooses to keep working on an outdated version. Fires 'refresh' when they
// ask to load the latest version.
export default class RecordPresenceBanner extends LightningElement {
  @api changedBy;
  // Already formatted for the user, like "2:14 PM"
  @api changedAt;

  get message() {
    return `You're viewing an outdated version. Last changed by ${this.changedBy || "someone else"} at ${this.changedAt}.`;
  }

  handleRefresh() {
    this.dispatchEvent(new CustomEvent("refresh"));
  }
}
