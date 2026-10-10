import { api } from "lwc";
import LightningModal from "lightning/modal";

// Tells the user someone else saved the record they're looking at. Closes with 'refresh' or 'keep' (undefined when
// closed with Escape or the close button), or with what the page passes to close() through register.
export default class RecordPresenceModal extends LightningModal {
  // From presenceUtils.toModalSummary: { headline, changes, hasChanges, moreText }
  @api summary;
  // Seconds before the record refreshes by itself; 0 = off
  @api autoRefreshSeconds = 0;
  // Called once with { update(summary), close(result) }, so the page can show a newer change in this modal instead of
  // opening another, or close it when the user has the latest version anyway
  @api register;

  current;
  remaining = 0;
  countdownId = null;
  focused = false;
  userInteracted = false;

  connectedCallback() {
    this.current = this.summary;
    this.startCountdown();
    // Any click or key press means the user is deciding for themselves, so it stops the countdown
    this.template.addEventListener("click", this.cancelCountdown);
    this.template.addEventListener("keydown", this.cancelCountdown);
    this.template.addEventListener("pointerdown", this.markInteracted);
    this.template.addEventListener("keydown", this.markInteracted);
    this.template.addEventListener("focusin", this.keepFocusOnRefresh);
    if (typeof this.register === "function") {
      this.register({
        update: (summary) => this.show(summary),
        close: (result) => this.close(result)
      });
    }
  }

  disconnectedCallback() {
    this.stopCountdown();
  }

  // "Refresh now" gets focus when the modal opens, so Enter refreshes
  renderedCallback() {
    if (!this.focused && this.refreshButton) {
      this.focused = true;
      this.refreshButton.focus();
    }
  }

  get refreshButton() {
    return this.template.querySelector('[data-id="refresh"]');
  }

  markInteracted = () => {
    this.userInteracted = true;
  };

  // LightningModal moves focus to its heading once it has opened. Until the user clicks or presses a key, focus that
  // lands anywhere else goes back to "Refresh now".
  keepFocusOnRefresh = (event) => {
    const refreshButton = this.refreshButton;
    if (
      !this.userInteracted &&
      refreshButton &&
      event.target !== refreshButton
    ) {
      refreshButton.focus();
    }
  };

  // A newer change: show it, and give the user the full countdown again
  show(summary) {
    this.current = summary;
    this.startCountdown();
  }

  startCountdown() {
    this.stopCountdown();
    this.remaining =
      Number(this.autoRefreshSeconds) > 0
        ? Math.floor(Number(this.autoRefreshSeconds))
        : 0;
    if (this.remaining > 0) {
      // eslint-disable-next-line @lwc/lwc/no-async-operation
      this.countdownId = setInterval(() => this.tick(), 1000);
    }
  }

  tick() {
    this.remaining -= 1;
    if (this.remaining <= 0) {
      this.stopCountdown();
      this.close("refresh");
    }
  }

  stopCountdown() {
    clearInterval(this.countdownId);
    this.countdownId = null;
  }

  cancelCountdown = () => {
    if (this.countdownId) {
      this.stopCountdown();
      this.remaining = 0;
    }
  };

  get headline() {
    return this.current ? this.current.headline : "";
  }

  get changes() {
    return this.current && this.current.hasChanges ? this.current.changes : [];
  }

  get hasChanges() {
    return this.changes.length > 0;
  }

  get moreText() {
    return this.current ? this.current.moreText : "";
  }

  get countingDown() {
    return this.remaining > 0;
  }

  get countdownText() {
    return `Refreshing in ${this.remaining}s…`;
  }

  handleRefresh() {
    this.close("refresh");
  }

  handleKeep() {
    this.close("keep");
  }
}
