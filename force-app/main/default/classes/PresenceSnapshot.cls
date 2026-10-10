// What a heartbeat returns to the recordPresence component: who else is on the record, and whether it has changed in a
// way the user should know about since the version they're looking at.
public inherited sharing class PresenceSnapshot {
  // False when the object's Record_Presence_Object__mdt record turns the component off
  @AuraEnabled
  public Boolean enabled = true;
  // Other users seen on the record within the staleness window, most recent first: never the current user or hidden users
  @AuraEnabled
  public List<Viewer> viewers = new List<Viewer>();
  @AuraEnabled
  public Long lastModifiedMillis;
  @AuraEnabled
  public Id lastModifiedById;
  @AuraEnabled
  public String lastModifiedByName;
  // Whether someone else (not an ignored user) changed the record, or one of its watched fields, after the client's baseline
  @AuraEnabled
  public Boolean meaningfulChange = false;
  // When the newest meaningful change was made, and by whom. The client alerts once per value of latestChangeMillis.
  @AuraEnabled
  public Long latestChangeMillis;
  @AuraEnabled
  public String latestChangeByName;
  // Readable field changes after the baseline, newest first and at most PresenceService.MAX_CHANGES, and how many there were
  @AuraEnabled
  public List<Change> changes = new List<Change>();
  @AuraEnabled
  public Integer totalChanges = 0;
  // PresenceStore.MODE_CACHE or MODE_OBJECT; null when the user can't see the record and nothing was read or written
  @AuraEnabled
  public String storageMode;
  // The server's clock, so the client can show "40 seconds ago" correctly when its own clock is off
  @AuraEnabled
  public Long serverTimeMillis;
  // The record's currency in multi-currency orgs, for formatting currency changes
  @AuraEnabled
  public String currencyIsoCode;
  // Only for users with the Record_Presence_Admin custom permission
  @AuraEnabled
  public AdminInfo adminInfo;

  public class Viewer {
    @AuraEnabled
    public Id userId;
    @AuraEnabled
    public String name;
    @AuraEnabled
    public String smallPhotoUrl;
    @AuraEnabled
    public Long lastSeenMillis;
  }

  public class Change {
    @AuraEnabled
    public String fieldLabel;
    // The field's Schema.DisplayType name (CURRENCY, DATE, PICKLIST...), so the client can format the values
    @AuraEnabled
    public String fieldType;
    // False when history doesn't record the values, as for long text areas: the client shows "changed"
    @AuraEnabled
    public Boolean valuesRecorded = true;
    // Numbers as plain decimals, dates as yyyy-MM-dd, date/times as epoch millis, picklist values as their labels
    @AuraEnabled
    public String oldValue;
    @AuraEnabled
    public String newValue;
    @AuraEnabled
    public String changedByName;
    @AuraEnabled
    public Long changedMillis;
  }

  public class AdminInfo {
    @AuraEnabled
    public String objectApiName;
    // The object's field history object, or null if history tracking has never been turned on for it
    @AuraEnabled
    public String historyObject;
    // Watched fields from Record_Presence_Object__mdt that exist on the object (API names)
    @AuraEnabled
    public List<String> watchedFields = new List<String>();
    // Watched fields without field history tracking: changes to them can't be detected
    @AuraEnabled
    public List<String> untrackedWatchedFields = new List<String>();
    // Names in Watched_Fields__c that aren't fields on the object, usually typos
    @AuraEnabled
    public List<String> unknownWatchedFields = new List<String>();
  }
}
