// Server side of the recordPresence component. Each heartbeat records that the user is on a record, returns who else
// is, and says whether someone else changed the record in a way the user should know about since the version they're
// looking at. Every heartbeat first checks in user mode that the user can see the record; if they can't, it returns an
// empty snapshot and records nothing.
public with sharing class PresenceService {
  public static final String HIDDEN_PERMISSION = 'Record_Presence_Hidden';
  public static final String IGNORE_CHANGES_PERMISSION = 'Record_Presence_Ignore_Changes';
  public static final String ADMIN_PERMISSION = 'Record_Presence_Admin';

  @TestVisible
  private static final Integer DEFAULT_HEARTBEAT_SECONDS = 25;
  // Users drop off when they haven't been seen for about 2.4 heartbeats: 60 seconds at the default 25, which leaves
  // room for the client's +20% jitter and one late heartbeat
  @TestVisible
  private static final Long MIN_STALE_WINDOW_MILLIS = 60000;
  @TestVisible
  private static final Integer MAX_VIEWERS = 20;
  @TestVisible
  private static final Integer MAX_CHANGES = 25;
  // How long the sets of hidden and ignored users are cached
  private static final Integer PERMISSION_CACHE_SECONDS = 600;

  @TestVisible
  private static PresenceSelector selector = new PresenceSelector();
  @TestVisible
  private static PresenceCache cache = new PresenceCache();

  // Records the user on the record and returns its presence and change snapshot. baselineMillis is the
  // LastModifiedDate of the version the user is looking at (null until the client has loaded it: no change is
  // reported then). heartbeatSeconds is the client's heartbeat interval, which sets how long users stay listed
  // after their last heartbeat; null means the default.
  @AuraEnabled
  public static PresenceSnapshot heartbeat(
    Id recordId,
    Long baselineMillis,
    Integer heartbeatSeconds
  ) {
    try {
      return new Heartbeat(recordId, baselineMillis, heartbeatSeconds).run();
    } catch (Exception e) {
      throw auraException('Unable to check record presence: ', e);
    }
  }

  // Best effort: removes the user from the record's viewers when they leave the page. Users who stop sending
  // heartbeats drop off after the staleness window anyway.
  @AuraEnabled
  public static void leave(Id recordId) {
    if (recordId == null) {
      return;
    }
    try {
      PresenceStore.forRequest(cache).remove(recordId, UserInfo.getUserId());
    } catch (Exception e) {
      throw auraException('Unable to leave record presence: ', e);
    }
  }

  @TestVisible
  private static Long staleWindowMillis(Integer heartbeatSeconds) {
    Integer seconds = heartbeatSeconds == null
      ? DEFAULT_HEARTBEAT_SECONDS
      : Math.min(Math.max(heartbeatSeconds, 15), 120);
    return Math.max(MIN_STALE_WINDOW_MILLIS, seconds * 2400L);
  }

  private static AuraHandledException auraException(
    String prefix,
    Exception e
  ) {
    String message = prefix + e.getMessage();
    AuraHandledException auraEx = new AuraHandledException(message);
    auraEx.setMessage(message);
    return auraEx;
  }

  // One heartbeat. Inner classes don't inherit sharing, so it's declared with sharing: the User query only returns
  // viewers the user is allowed to see.
  private with sharing class Heartbeat {
    private final Id recordId;
    private final Long baselineMillis;
    private final Long windowMillis;
    private final Long nowMillis = Datetime.now().getTime();
    private final Id userId = UserInfo.getUserId();
    private final PresenceSnapshot snapshot = new PresenceSnapshot();
    private Schema.DescribeSObjectResult objectDescribe;
    private Map<String, Schema.SObjectField> fieldMap;
    private Record_Presence_Object__mdt config;
    // Watched fields that exist on the object, lowercase API name => API name; null until parsed
    private Map<String, String> watched;
    private final List<String> unknownWatched = new List<String>();
    private final Map<String, Set<Id>> usersByPermission = new Map<String, Set<Id>>();

    Heartbeat(Id recordId, Long baselineMillis, Integer heartbeatSeconds) {
      this.recordId = recordId;
      this.baselineMillis = baselineMillis;
      this.windowMillis = staleWindowMillis(heartbeatSeconds);
    }

    PresenceSnapshot run() {
      snapshot.serverTimeMillis = nowMillis;
      if (recordId == null) {
        return snapshot;
      }
      objectDescribe = recordId.getSObjectType().getDescribe();
      fieldMap = objectDescribe.fields.getMap();
      config = selector.getObjectConfig(objectDescribe.getName());
      if (config != null && !config.Enabled__c) {
        snapshot.enabled = false;
        return snapshot;
      }
      SObject record = queryRecord();
      if (record == null) {
        // The user can't see the record (or it was deleted): don't say who else is on it, and record nothing
        return snapshot;
      }
      addViewers();
      addChanges(record);
      if (FeatureManagement.checkPermission(ADMIN_PERMISSION)) {
        addAdminInfo();
      }
      return snapshot;
    }

    // The record's modification info in user mode, or null if the user can't see it
    private SObject queryRecord() {
      Boolean hasCurrency =
        UserInfo.isMultiCurrencyOrganization() &&
        fieldMap.containsKey('currencyisocode');
      String soql =
        'SELECT LastModifiedDate, LastModifiedById, LastModifiedBy.Name' +
        (hasCurrency ? ', CurrencyIsoCode' : '') +
        ' FROM ' +
        objectDescribe.getName() +
        ' WHERE Id = :recordId LIMIT 1';
      List<SObject> rows;
      try {
        rows = Database.queryWithBinds(
          soql,
          new Map<String, Object>{ 'recordId' => recordId },
          AccessLevel.USER_MODE
        );
      } catch (QueryException e) {
        // No access to the object or one of the fields
        return null;
      } catch (NoAccessException e) {
        return null;
      }
      if (rows.isEmpty()) {
        return null;
      }
      if (hasCurrency) {
        snapshot.currencyIsoCode = (String) rows[0].get('CurrencyIsoCode');
      }
      return rows[0];
    }

    private void addViewers() {
      PresenceStore store = PresenceStore.forRequest(cache);
      snapshot.storageMode = store.mode();
      // Hidden users are never shown, so their presence isn't recorded either
      Boolean recordUser = !FeatureManagement.checkPermission(
        HIDDEN_PERMISSION
      );
      Map<Id, Long> seen = store.touch(
        recordId,
        userId,
        nowMillis,
        nowMillis - windowMillis,
        recordUser
      );
      seen.remove(userId);
      if (seen.isEmpty()) {
        return;
      }
      for (Id hiddenUserId : usersWithPermission(HIDDEN_PERMISSION)) {
        seen.remove(hiddenUserId);
      }
      List<Id> viewerIds = new List<Id>();
      for (Id seenUserId : PresenceStore.newestFirst(seen)) {
        if (viewerIds.size() == MAX_VIEWERS) {
          break;
        }
        viewerIds.add(seenUserId);
      }
      Map<Id, User> users = new Map<Id, User>(
        [
          SELECT Id, Name, SmallPhotoUrl
          FROM User
          WHERE Id IN :viewerIds AND IsActive = TRUE
        ]
      );
      for (Id viewerId : viewerIds) {
        User viewerUser = users.get(viewerId);
        if (viewerUser == null) {
          // Deactivated, or not visible to this user
          continue;
        }
        PresenceSnapshot.Viewer viewer = new PresenceSnapshot.Viewer();
        viewer.userId = viewerId;
        viewer.name = viewerUser.Name;
        viewer.smallPhotoUrl = viewerUser.SmallPhotoUrl;
        viewer.lastSeenMillis = seen.get(viewerId);
        snapshot.viewers.add(viewer);
      }
    }

    private void addChanges(SObject record) {
      snapshot.lastModifiedMillis = ((Datetime) record.get('LastModifiedDate'))
        .getTime();
      snapshot.lastModifiedById = (Id) record.get('LastModifiedById');
      SObject modifiedBy = record.getSObject('LastModifiedBy');
      snapshot.lastModifiedByName = modifiedBy == null
        ? null
        : (String) modifiedBy.get('Name');
      if (
        baselineMillis == null ||
        snapshot.lastModifiedMillis <= baselineMillis
      ) {
        return;
      }
      if (watchedFields().isEmpty()) {
        // Any change counts, unless the last one was the user's own or an ignored user's
        Id modifiedById = snapshot.lastModifiedById;
        if (
          modifiedById == userId ||
          usersWithPermission(IGNORE_CHANGES_PERMISSION).contains(modifiedById)
        ) {
          return;
        }
        markChanged(snapshot.lastModifiedMillis, snapshot.lastModifiedByName);
        // What changed, if the object tracks history. Only shown to the user; it doesn't decide the alert.
        addHistory(false);
      } else {
        // Only changes to watched fields count, and only ones history recorded
        addHistory(true);
        if (!snapshot.changes.isEmpty()) {
          markChanged(
            snapshot.changes[0].changedMillis,
            snapshot.changes[0].changedByName
          );
        }
      }
    }

    private void markChanged(Long changedMillis, String changedByName) {
      snapshot.meaningfulChange = true;
      snapshot.latestChangeMillis = changedMillis;
      snapshot.latestChangeByName = changedByName;
    }

    // Adds the field changes made after the baseline by other users who aren't ignored, on fields the user can read
    // (and only watched fields, if watchedOnly), newest first.
    private void addHistory(Boolean watchedOnly) {
      PresenceSelector.HistoryObject history = selector.getHistoryObject(
        objectDescribe.getSObjectType()
      );
      if (history == null) {
        return;
      }
      List<PresenceSelector.HistoryEntry> entries = selector.getHistory(
        history,
        recordId,
        Datetime.newInstance(baselineMillis),
        watchedOnly ? historyFieldNames(watched.keySet()) : null
      );
      Set<Id> ignoredUsers = usersWithPermission(IGNORE_CHANGES_PERMISSION);

      // Keep the changes this user may see
      List<PresenceSelector.HistoryEntry> kept = new List<PresenceSelector.HistoryEntry>();
      List<Schema.DescribeFieldResult> keptFields = new List<Schema.DescribeFieldResult>();
      for (PresenceSelector.HistoryEntry entry : entries) {
        if (
          entry.createdById == userId ||
          ignoredUsers.contains(entry.createdById)
        ) {
          continue;
        }
        Schema.DescribeFieldResult field = describeHistoryField(entry.field);
        if (field == null || !field.isAccessible()) {
          continue;
        }
        if (
          watchedOnly && !watched.containsKey(field.getName().toLowerCase())
        ) {
          continue;
        }
        kept.add(entry);
        keptFields.add(field);
      }

      // A lookup change is recorded twice, once with IDs and once with names; show the names
      Set<String> namedChanges = new Set<String>();
      for (Integer i = 0; i < kept.size(); i++) {
        if (!isIdEntry(kept[i], keptFields[i])) {
          namedChanges.add(changeKey(kept[i]));
        }
      }
      for (Integer i = 0; i < kept.size(); i++) {
        Boolean idEntry = isIdEntry(kept[i], keptFields[i]);
        if (idEntry && namedChanges.contains(changeKey(kept[i]))) {
          continue;
        }
        snapshot.totalChanges++;
        if (snapshot.changes.size() < MAX_CHANGES) {
          snapshot.changes.add(toChange(kept[i], keptFields[i], idEntry));
        }
      }
    }

    // The Field values history uses for these fields: the API name, plus the name without Id for standard lookups
    // (Owner for OwnerId) and TextName for Name
    private Set<String> historyFieldNames(Set<String> fieldNames) {
      Set<String> names = new Set<String>();
      for (String name : fieldNames) {
        names.add(name);
        if (!name.contains('__') && name.endsWith('id') && name.length() > 2) {
          names.add(name.removeEnd('id'));
        }
        if (name == 'name') {
          names.add('textname');
        }
      }
      return names;
    }

    // The field a history row's Field value refers to, or null for non-field rows such as 'created' or 'locked'
    private Schema.DescribeFieldResult describeHistoryField(
      String recordedField
    ) {
      if (String.isBlank(recordedField)) {
        return null;
      }
      String key = recordedField.toLowerCase();
      if (key == 'textname') {
        key = 'name';
      }
      Schema.SObjectField field = fieldMap.get(key);
      if (field == null && !key.contains('__')) {
        field = fieldMap.get(key + 'id');
      }
      return field == null ? null : field.getDescribe();
    }

    // Whether the row is the ID half of a lookup change
    private Boolean isIdEntry(
      PresenceSelector.HistoryEntry entry,
      Schema.DescribeFieldResult field
    ) {
      if (entry.dataType != null) {
        return entry.dataType == 'EntityId';
      }
      return field.getType() == Schema.DisplayType.REFERENCE &&
        (isId(entry.oldValue) || isId(entry.newValue));
    }

    private Boolean isId(Object value) {
      return value instanceof Id ||
        (value instanceof String &&
        Pattern.matches('[a-zA-Z0-9]{15}([a-zA-Z0-9]{3})?', (String) value));
    }

    private String changeKey(PresenceSelector.HistoryEntry entry) {
      return entry.field.toLowerCase() +
        '|' +
        entry.createdDate.getTime() +
        '|' +
        entry.createdById;
    }

    private PresenceSnapshot.Change toChange(
      PresenceSelector.HistoryEntry entry,
      Schema.DescribeFieldResult field,
      Boolean idEntry
    ) {
      PresenceSnapshot.Change change = new PresenceSnapshot.Change();
      change.fieldLabel = changeLabel(field);
      change.fieldType = field.getType().name();
      change.changedByName = entry.createdByName;
      change.changedMillis = entry.createdDate.getTime();
      // Long text areas are recorded without values, and IDs alone mean nothing to the user
      change.valuesRecorded =
        !idEntry && (entry.oldValue != null || entry.newValue != null);
      if (change.valuesRecorded) {
        change.oldValue = formatValue(entry.oldValue, field);
        change.newValue = formatValue(entry.newValue, field);
      }
      return change;
    }

    // Lookups are labeled like "Owner ID" or "Parent Account ID", but history shows names: drop the "ID"
    private String changeLabel(Schema.DescribeFieldResult field) {
      String label = field.getLabel();
      if (
        field.getType() == Schema.DisplayType.REFERENCE && label.endsWith(' ID')
      ) {
        return label.removeEnd(' ID');
      }
      return label;
    }

    // A value as text the client can format for the user's locale
    private String formatValue(Object value, Schema.DescribeFieldResult field) {
      if (value == null) {
        return null;
      }
      switch on field.getType() {
        when DATETIME {
          return value instanceof Datetime
            ? String.valueOf(((Datetime) value).getTime())
            : String.valueOf(value);
        }
        when DATE {
          return String.valueOf(value).left(10);
        }
        when CURRENCY, DOUBLE, PERCENT, INTEGER, LONG {
          return value instanceof Decimal
            ? ((Decimal) value).toPlainString()
            : String.valueOf(value);
        }
        when PICKLIST, MULTIPICKLIST {
          return picklistLabels(field, String.valueOf(value));
        }
        when else {
          return String.valueOf(value);
        }
      }
    }

    // History stores picklist API values; show their labels
    private String picklistLabels(
      Schema.DescribeFieldResult field,
      String value
    ) {
      Map<String, String> labels = new Map<String, String>();
      for (Schema.PicklistEntry entry : field.getPicklistValues()) {
        labels.put(entry.getValue(), entry.getLabel());
      }
      List<String> shown = new List<String>();
      for (String part : value.split(';')) {
        shown.add(labels.containsKey(part) ? labels.get(part) : part);
      }
      return String.join(shown, '; ');
    }

    // Parses Watched_Fields__c (commas, semicolons or whitespace between names). Names that aren't fields on the
    // object are left out, and listed for admins; if none are valid, any change counts.
    private Map<String, String> watchedFields() {
      if (watched == null) {
        watched = new Map<String, String>();
        if (config != null && String.isNotBlank(config.Watched_Fields__c)) {
          for (String name : config.Watched_Fields__c.split('[,;\\s]+')) {
            if (String.isBlank(name)) {
              continue;
            }
            Schema.SObjectField field = fieldMap.get(name.trim().toLowerCase());
            if (field == null) {
              unknownWatched.add(name.trim());
            } else {
              String apiName = field.getDescribe().getName();
              watched.put(apiName.toLowerCase(), apiName);
            }
          }
        }
      }
      return watched;
    }

    private void addAdminInfo() {
      PresenceSnapshot.AdminInfo info = new PresenceSnapshot.AdminInfo();
      info.objectApiName = objectDescribe.getName();
      PresenceSelector.HistoryObject history = selector.getHistoryObject(
        objectDescribe.getSObjectType()
      );
      info.historyObject = history?.name;
      info.watchedFields = watchedFields().values();
      info.unknownWatchedFields = unknownWatched;
      if (!watched.isEmpty()) {
        Set<String> tracked = history == null
          ? new Set<String>()
          : selector.getHistoryTrackedFields(info.objectApiName);
        for (String key : watched.keySet()) {
          if (!tracked.contains(key)) {
            info.untrackedWatchedFields.add(watched.get(key));
          }
        }
      }
      snapshot.adminInfo = info;
    }

    // Users with the custom permission, cached for PERMISSION_CACHE_SECONDS when the cache is available
    private Set<Id> usersWithPermission(String permissionName) {
      if (!usersByPermission.containsKey(permissionName)) {
        // Cache keys must be alphanumeric
        String cacheKey = 'perm' + permissionName.remove('_');
        Object cached = cache.get(cacheKey);
        Set<Id> userIds;
        if (cached instanceof Set<Id>) {
          userIds = (Set<Id>) cached;
        } else {
          userIds = selector.getUserIdsWithPermission(permissionName);
          cache.put(cacheKey, userIds, PERMISSION_CACHE_SECONDS);
        }
        usersByPermission.put(permissionName, userIds);
      }
      return usersByPermission.get(permissionName);
    }
  }
}
