import { LightningElement, api, wire } from "lwc";
import {
  getRecord,
  getFieldValue,
  notifyRecordUpdateAvailable
} from "lightning/uiRecordApi";
import heartbeat from "@salesforce/apex/PresenceService.heartbeat";
import leave from "@salesforce/apex/PresenceService.leave";
import hasAdminPermission from "@salesforce/customPermission/Record_Presence_Admin";
import locale from "@salesforce/i18n/locale";
import timeZone from "@salesforce/i18n/timeZone";
import userCurrency from "@salesforce/i18n/currency";
import RecordPresenceModal from "c/recordPresenceModal";
import {
  DEFAULT_HEARTBEAT_SECONDS,
  MAX_HEARTBEAT_SECONDS,
  MIN_HEARTBEAT_SECONDS,
  clampInteger,
  formatTime,
  initials,
  isNewChange,
  nextDelaySeconds,
  reduceError,
  toModalSummary
} from "c/presenceUtils";

// After this many failed heartbeats in a row, avatars are hidden until one succeeds
const FAILURES_BEFORE_HIDING = 3;
const BANNER_ONLY = "Banner only";
// What the modal closes with when the page closes it because the user already has the latest version
const CLOSED_AS_CURRENT = "current";

// Shows who else is viewing the record, and interrupts the user when someone else saves it so they don't keep working
// on an outdated version. Sends a heartbeat to PresenceService every heartbeatSeconds while the tab is visible.
export default class RecordPresence extends LightningElement {
  @api objectApiName;
  @api heartbeatSeconds = DEFAULT_HEARTBEAT_SECONDS;
  @api maxAvatars = 4;
  // 'Modal' or 'Banner only'
  @api alertStyle = "Modal";
  // Seconds the modal counts down before refreshing by itself; 0 = off
  @api autoRefreshSeconds = 0;

  viewers = [];
  // False when Record_Presence_Object__mdt turns the component off for this object
  enabled = true;
  // LastModifiedDate of the version on the page, from Lightning Data Service
  baselineMillis = null;
  // The change this tab last alerted on, so each change alerts once
  lastAlertedChangeMillis = null;
  // The newest change the user hasn't refreshed for: { byName, changedMillis, changes, totalChanges }
  stale = null;
  bannerVisible = false;
  failures = 0;
  lastError = null;
  hasHeartbeat = false;
  storageMode = null;
  adminInfo = null;
  detailsOpen = false;
  currencyCode = userCurrency;
  // Server time minus this browser's time, so "40 seconds ago" is right when the browser's clock is off
  clockOffsetMillis = 0;

  _recordId;
  connected = false;
  timerId = null;
  inFlight = false;
  modalOpen = false;
  // { update, close } of the open modal, once it has registered
  modalHandle = null;
  pendingSummary = null;
  _showViewers = true;

  // Defaults to true, like its App Builder property. (A public Boolean field can't default to true.)
  @api
  get showViewers() {
    return this._showViewers;
  }
  set showViewers(value) {
    this._showViewers = value;
  }

  @api
  get recordId() {
    return this._recordId;
  }
  set recordId(value) {
    if (value === this._recordId) {
      return;
    }
    const previous = this._recordId;
    this._recordId = value;
    // The page was reused for another record
    if (this.connected) {
      if (previous) {
        this.sendLeave(previous);
      }
      this.reset();
      this.beat();
    }
  }

  get baselineFields() {
    return this.objectApiName
      ? [`${this.objectApiName}.LastModifiedDate`]
      : undefined;
  }

  // The version the user is looking at. LDS updates it when they save or the record reloads.
  @wire(getRecord, { recordId: "$recordId", optionalFields: "$baselineFields" })
  wiredRecord({ data }) {
    if (!data || !this.baselineFields) {
      return;
    }
    const value =
      getFieldValue(data, this.baselineFields[0]) || data.lastModifiedDate;
    const millis = Date.parse(value);
    if (!Number.isNaN(millis)) {
      this.updateBaseline(millis);
    }
  }

  connectedCallback() {
    this.connected = true;
    document.addEventListener("visibilitychange", this.handleVisibilityChange);
    window.addEventListener("pagehide", this.handlePageHide);
    this.beat();
  }

  disconnectedCallback() {
    this.connected = false;
    this.clearTimer();
    document.removeEventListener(
      "visibilitychange",
      this.handleVisibilityChange
    );
    window.removeEventListener("pagehide", this.handlePageHide);
    this.sendLeave(this.recordId);
  }

  // No heartbeats from hidden tabs; one straight away when the tab is shown again
  handleVisibilityChange = () => {
    if (document.hidden) {
      this.clearTimer();
    } else {
      this.beat();
    }
  };

  handlePageHide = () => {
    this.sendLeave(this.recordId);
  };

  // ---- Heartbeat loop ----

  beat() {
    this.clearTimer();
    if (
      !this.connected ||
      !this.recordId ||
      !this.enabled ||
      document.hidden ||
      this.inFlight
    ) {
      return;
    }
    const recordId = this.recordId;
    this.inFlight = true;
    heartbeat({
      recordId,
      baselineMillis: this.baselineMillis,
      heartbeatSeconds: this.intervalSeconds
    })
      .then((snapshot) => {
        this.failures = 0;
        this.lastError = null;
        if (recordId === this.recordId) {
          this.applySnapshot(snapshot);
        }
      })
      .catch((error) => {
        // No toast for users: the admin status line shows the error
        this.failures += 1;
        this.lastError = reduceError(error);
        console.error("Record presence heartbeat failed", error);
      })
      .finally(() => {
        this.inFlight = false;
        if (recordId !== this.recordId) {
          this.beat();
        } else {
          this.scheduleNext();
        }
      });
  }

  scheduleNext() {
    this.clearTimer();
    if (!this.connected || !this.enabled || document.hidden) {
      return;
    }
    const seconds = nextDelaySeconds(this.intervalSeconds, this.failures);
    // eslint-disable-next-line @lwc/lwc/no-async-operation
    this.timerId = setTimeout(() => this.beat(), seconds * 1000);
  }

  clearTimer() {
    clearTimeout(this.timerId);
    this.timerId = null;
  }

  // Best effort: correctness never depends on it, since users drop off after the staleness window anyway
  sendLeave(recordId) {
    if (recordId) {
      leave({ recordId }).catch(() => {});
    }
  }

  reset() {
    this.viewers = [];
    this.enabled = true;
    this.baselineMillis = null;
    this.lastAlertedChangeMillis = null;
    this.failures = 0;
    this.hasHeartbeat = false;
    this.clearStale();
  }

  applySnapshot(snapshot) {
    this.hasHeartbeat = true;
    this.enabled = snapshot.enabled !== false;
    this.viewers = snapshot.viewers || [];
    this.storageMode = snapshot.storageMode;
    this.adminInfo = snapshot.adminInfo;
    this.currencyCode = snapshot.currencyIsoCode || userCurrency;
    if (snapshot.serverTimeMillis) {
      this.clockOffsetMillis = snapshot.serverTimeMillis - Date.now();
    }
    if (
      isNewChange(snapshot, this.lastAlertedChangeMillis, this.baselineMillis)
    ) {
      this.lastAlertedChangeMillis = snapshot.latestChangeMillis;
      this.stale = {
        byName: snapshot.latestChangeByName || snapshot.lastModifiedByName,
        changedMillis: snapshot.latestChangeMillis,
        changes: snapshot.changes || [],
        totalChanges: snapshot.totalChanges || 0
      };
      this.alert();
    }
  }

  updateBaseline(millis) {
    this.baselineMillis = millis;
    // The page shows the changed version now (the user refreshed, or saved after reloading): nothing to warn about
    if (this.stale && millis >= this.stale.changedMillis) {
      this.clearStale();
    }
  }

  clearStale() {
    this.stale = null;
    this.bannerVisible = false;
    if (this.modalHandle) {
      this.modalHandle.close(CLOSED_AS_CURRENT);
    }
  }

  // ---- Alerts ----

  alert() {
    if (this.alertStyle === BANNER_ONLY) {
      this.bannerVisible = true;
      return;
    }
    const summary = toModalSummary(this.stale, {
      nowMillis: Date.now() + this.clockOffsetMillis,
      locale,
      timeZone,
      currency: this.currencyCode
    });
    // Never two modals: show the newer change in the open one
    if (this.modalOpen) {
      if (this.modalHandle) {
        this.modalHandle.update(summary);
      } else {
        this.pendingSummary = summary;
      }
      return;
    }
    this.openModal(summary);
  }

  openModal(summary) {
    this.modalOpen = true;
    RecordPresenceModal.open({
      size: "small",
      label: "This record has been updated",
      summary,
      autoRefreshSeconds: this.autoRefreshCountdown,
      register: (handle) => {
        this.modalHandle = handle;
        if (this.pendingSummary) {
          handle.update(this.pendingSummary);
          this.pendingSummary = null;
        }
      }
    }).then((result) => {
      this.modalOpen = false;
      this.modalHandle = null;
      this.pendingSummary = null;
      if (result === "refresh") {
        this.refresh();
      } else if (result !== CLOSED_AS_CURRENT && this.stale) {
        // "Keep working on this version", or closed with Escape or the close button
        this.bannerVisible = true;
      }
    });
  }

  // Reloads the record's data on the page through Lightning Data Service, without reloading the browser page
  refresh() {
    const recordId = this.recordId;
    this.stale = null;
    this.bannerVisible = false;
    return notifyRecordUpdateAvailable([{ recordId }]).catch((error) => {
      console.error("Record presence refresh failed", error);
    });
  }

  handleBannerRefresh() {
    this.refresh();
  }

  // ---- Viewers ----

  get intervalSeconds() {
    return clampInteger(
      this.heartbeatSeconds,
      MIN_HEARTBEAT_SECONDS,
      MAX_HEARTBEAT_SECONDS,
      DEFAULT_HEARTBEAT_SECONDS
    );
  }

  get autoRefreshCountdown() {
    return clampInteger(this.autoRefreshSeconds, 0, 60, 0);
  }

  get avatarLimit() {
    return clampInteger(this.maxAvatars, 1, 20, 4);
  }

  get shownViewers() {
    if (
      !this.showViewers ||
      !this.enabled ||
      this.failures >= FAILURES_BEFORE_HIDING
    ) {
      return [];
    }
    return this.viewers;
  }

  get hasViewers() {
    return this.shownViewers.length > 0;
  }

  get visibleAvatars() {
    return this.shownViewers.slice(0, this.avatarLimit).map((viewer) => ({
      key: viewer.userId,
      name: viewer.name,
      src: viewer.smallPhotoUrl,
      initials: initials(viewer.name),
      title: `${viewer.name} is viewing`
    }));
  }

  get overflowViewers() {
    return this.shownViewers.slice(this.avatarLimit);
  }

  get hasOverflow() {
    return this.overflowViewers.length > 0;
  }

  get overflowText() {
    return `+${this.overflowViewers.length}`;
  }

  get overflowTitle() {
    return `Also viewing: ${this.overflowViewers.map((viewer) => viewer.name).join(", ")}`;
  }

  get viewersLabel() {
    return `Also viewing this record: ${this.shownViewers.map((viewer) => viewer.name).join(", ")}`;
  }

  // ---- Banner ----

  get showBanner() {
    return this.bannerVisible && !!this.stale && this.enabled;
  }

  get bannerChangedBy() {
    return this.stale ? this.stale.byName : "";
  }

  get bannerChangedAt() {
    return this.stale
      ? formatTime(
          this.stale.changedMillis,
          Date.now() + this.clockOffsetMillis,
          locale,
          timeZone
        )
      : "";
  }

  // ---- Admin view ----

  get isAdmin() {
    return hasAdminPermission === true;
  }

  // The component shows nothing to users when no one else is here, which makes it hard to find in Lightning App
  // Builder; a short description is shown there instead
  get inAppBuilder() {
    try {
      return /flexipageEditor|visualEditor/i.test(window.location.pathname);
    } catch {
      return false;
    }
  }

  get showBuilderPlaceholder() {
    return !this.isAdmin && this.inAppBuilder;
  }

  get hasWarning() {
    return (
      this.failures > 0 ||
      this.untrackedWatchedFields.length > 0 ||
      this.unknownWatchedFields.length > 0
    );
  }

  get adminIcon() {
    return this.hasWarning ? "utility:warning" : "utility:info";
  }

  get adminStatus() {
    if (this.failures > 0) {
      return `Record presence: the last heartbeat failed (${this.lastError}). Retrying in up to ${Math.round(
        nextDelaySeconds(this.intervalSeconds, this.failures, 1)
      )}s.`;
    }
    if (!this.recordId) {
      return "Record presence: shows who else is viewing the record, and alerts users when someone else changes it.";
    }
    if (!this.hasHeartbeat) {
      return "Record presence: connecting…";
    }
    if (!this.enabled) {
      return `Record presence is turned off for ${this.objectApiName} in its Record Presence Object settings.`;
    }
    const parts = [
      `Record presence: ${this.storageLabel}`,
      this.watchedSummary,
      `heartbeat every ${this.intervalSeconds}s`
    ];
    const problems =
      this.untrackedWatchedFields.length + this.unknownWatchedFields.length;
    if (problems > 0) {
      parts.push(
        `${problems} watched ${problems === 1 ? "field needs" : "fields need"} attention`
      );
    }
    return parts.join(" · ");
  }

  get storageLabel() {
    if (this.storageMode === "CACHE") {
      return "Platform Cache";
    }
    if (this.storageMode === "OBJECT") {
      return "Presence object (no cache capacity)";
    }
    return "no access to this record";
  }

  get watchedFields() {
    return this.adminInfo ? this.adminInfo.watchedFields || [] : [];
  }

  get untrackedWatchedFields() {
    return this.adminInfo ? this.adminInfo.untrackedWatchedFields || [] : [];
  }

  get unknownWatchedFields() {
    return this.adminInfo ? this.adminInfo.unknownWatchedFields || [] : [];
  }

  get watchedSummary() {
    const count = this.watchedFields.length;
    if (count === 0) {
      return "any change alerts";
    }
    return `${count} watched ${count === 1 ? "field" : "fields"}`;
  }

  get historyLabel() {
    if (!this.adminInfo) {
      return "";
    }
    return (
      this.adminInfo.historyObject ||
      "None: field history tracking isn't turned on for this object"
    );
  }

  // Each watched field and whether changes to it can be detected
  get watchedFieldRows() {
    const untracked = new Set(this.untrackedWatchedFields);
    const rows = this.watchedFields.map((field) => ({
      key: field,
      name: field,
      status: untracked.has(field)
        ? "Not history-tracked: changes can't be detected"
        : "History-tracked",
      className: untracked.has(field) ? "slds-text-color_error" : ""
    }));
    this.unknownWatchedFields.forEach((field) => {
      rows.push({
        key: `unknown-${field}`,
        name: field,
        status: `Not a field on ${this.objectApiName}`,
        className: "slds-text-color_error"
      });
    });
    return rows;
  }

  get hasWatchedFieldRows() {
    return this.watchedFieldRows.length > 0;
  }

  get detailsExpanded() {
    return String(this.detailsOpen);
  }

  toggleDetails() {
    this.detailsOpen = !this.detailsOpen;
  }

  closeDetails() {
    this.detailsOpen = false;
  }

  handleDetailsKeyDown(event) {
    if (event.key === "Escape") {
      event.stopPropagation();
      this.closeDetails();
    }
  }
}
