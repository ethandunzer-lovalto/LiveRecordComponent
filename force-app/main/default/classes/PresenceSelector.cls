// Lookups PresenceService can't exercise with real data in Apex tests: field history (not created in test context),
// custom permission assignments, Custom Metadata and history tracking settings. Tests replace the instance PresenceService
// uses with a subclass that returns canned data.
public inherited sharing virtual class PresenceSelector {
  // Enough to tell what changed while someone was on a record; older rows are rarely needed
  @TestVisible
  private static final Integer MAX_HISTORY_ROWS = 200;
  // Hidden and ignored users are meant to be a few integration users and the like
  private static final Integer MAX_PERMISSION_USERS = 5000;

  // History objects by object name for this transaction; null values mean the object has no field history
  private static Map<String, HistoryObject> historyObjects = new Map<String, HistoryObject>();

  // A field history object and its field that points at the parent record, e.g. OpportunityFieldHistory.OpportunityId
  public class HistoryObject {
    public String name;
    public String parentField;
    // Whether rows have a DataType, which marks the ID half of a lookup change (EntityId)
    public Boolean hasDataType;

    public HistoryObject(String name, String parentField, Boolean hasDataType) {
      this.name = name;
      this.parentField = parentField;
      this.hasDataType = hasDataType;
    }
  }

  // One field history row as recorded
  public class HistoryEntry {
    // The Field column: the field's API name, except some standard fields (Owner for OwnerId, TextName for Account Name)
    public String field;
    public Object oldValue;
    public Object newValue;
    public String dataType;
    public Id createdById;
    public String createdByName;
    public Datetime createdDate;
  }

  // The object's field history object, or null if it has none (tracking was never turned on). History objects aren't
  // named consistently, so this tries <Object>History, then <Object>FieldHistory, and checks each is field history:
  // Opportunity's OpportunityHistory is a stage snapshot, and its field history is OpportunityFieldHistory.
  public virtual HistoryObject getHistoryObject(Schema.SObjectType objectType) {
    String objectName = objectType.getDescribe().getName();
    if (!historyObjects.containsKey(objectName)) {
      historyObjects.put(
        objectName,
        resolveHistoryObject(objectType, historyObjectCandidates(objectName))
      );
    }
    return historyObjects.get(objectName);
  }

  @TestVisible
  private static List<String> historyObjectCandidates(String objectName) {
    if (objectName.endsWithIgnoreCase('__c')) {
      return new List<String>{
        objectName.left(objectName.length() - 3) + '__History'
      };
    }
    return new List<String>{
      objectName + 'History',
      objectName + 'FieldHistory'
    };
  }

  @TestVisible
  private static HistoryObject resolveHistoryObject(
    Schema.SObjectType parentType,
    List<String> candidates
  ) {
    for (String candidate : candidates) {
      Schema.DescribeSObjectResult describe;
      try {
        describe = Schema.describeSObjects(new List<String>{ candidate })[0];
      } catch (Exception e) {
        // No such object
        continue;
      }
      Map<String, Schema.SObjectField> fields = describe.fields.getMap();
      if (
        !fields.containsKey('field') ||
        !fields.containsKey('oldvalue') ||
        !fields.containsKey('newvalue')
      ) {
        continue;
      }
      for (Schema.SObjectField field : fields.values()) {
        Schema.DescribeFieldResult fieldDescribe = field.getDescribe();
        if (
          fieldDescribe.getType() == Schema.DisplayType.REFERENCE &&
          fieldDescribe.getReferenceTo().contains(parentType) &&
          fieldDescribe.getName() != 'CreatedById'
        ) {
          return new HistoryObject(
            describe.getName(),
            fieldDescribe.getName(),
            fields.containsKey('datatype')
          );
        }
      }
    }
    return null;
  }

  // History rows for the record created after `after`, newest first. fieldNames (as recorded in the Field column)
  // limits the rows to those fields; null returns rows for all fields. Runs in user mode; the caller checks field-level
  // security on each changed field.
  public virtual List<HistoryEntry> getHistory(
    HistoryObject history,
    Id recordId,
    Datetime after,
    Set<String> fieldNames
  ) {
    Map<String, Object> binds = new Map<String, Object>{
      'recordId' => recordId,
      'after' => after
    };
    String soql =
      'SELECT Field, OldValue, NewValue, CreatedById, CreatedBy.Name, CreatedDate' +
      (history.hasDataType ? ', DataType' : '') +
      ' FROM ' +
      history.name +
      ' WHERE ' +
      history.parentField +
      ' = :recordId AND CreatedDate > :after';
    if (fieldNames != null) {
      soql += ' AND Field IN :fieldNames';
      binds.put('fieldNames', fieldNames);
    }
    soql += ' ORDER BY CreatedDate DESC, Id DESC LIMIT ' + MAX_HISTORY_ROWS;

    List<HistoryEntry> entries = new List<HistoryEntry>();
    for (
      SObject row : Database.queryWithBinds(soql, binds, AccessLevel.USER_MODE)
    ) {
      HistoryEntry entry = new HistoryEntry();
      entry.field = (String) row.get('Field');
      entry.oldValue = row.get('OldValue');
      entry.newValue = row.get('NewValue');
      entry.dataType = history.hasDataType
        ? (String) row.get('DataType')
        : null;
      entry.createdById = (Id) row.get('CreatedById');
      SObject createdBy = row.getSObject('CreatedBy');
      entry.createdByName = createdBy == null
        ? null
        : (String) createdBy.get('Name');
      entry.createdDate = (Datetime) row.get('CreatedDate');
      entries.add(entry);
    }
    return entries;
  }

  // Active users with the custom permission through a permission set, a permission set group or their profile. Apex
  // can only check custom permissions for the running user, so this walks the assignments. Muting in permission set
  // groups isn't taken into account.
  public virtual Set<Id> getUserIdsWithPermission(String permissionName) {
    Set<Id> userIds = new Set<Id>();
    // Permission sets, including the ones behind profiles and permission set groups, that grant the permission
    Set<Id> permissionSetIds = new Set<Id>();
    for (SetupEntityAccess access : [
      SELECT ParentId
      FROM SetupEntityAccess
      WHERE
        SetupEntityId IN (
          SELECT Id
          FROM CustomPermission
          WHERE DeveloperName = :permissionName AND NamespacePrefix = NULL
        )
      WITH SYSTEM_MODE
    ]) {
      permissionSetIds.add(access.ParentId);
    }
    if (permissionSetIds.isEmpty()) {
      return userIds;
    }
    // Groups that include one of those permission sets. A group's own permission set has the permission too, once
    // the group has been recalculated; this covers groups that haven't been.
    Set<Id> groupIds = new Set<Id>();
    for (PermissionSetGroupComponent component : [
      SELECT PermissionSetGroupId
      FROM PermissionSetGroupComponent
      WHERE PermissionSetId IN :permissionSetIds
      WITH SYSTEM_MODE
    ]) {
      groupIds.add(component.PermissionSetGroupId);
    }
    for (PermissionSetAssignment assignment : [
      SELECT AssigneeId
      FROM PermissionSetAssignment
      WHERE
        (PermissionSetId IN :permissionSetIds
        OR PermissionSetGroupId IN :groupIds)
        AND Assignee.IsActive = TRUE
      WITH SYSTEM_MODE
      LIMIT :MAX_PERMISSION_USERS
    ]) {
      userIds.add(assignment.AssigneeId);
    }
    return userIds;
  }

  // The object's Record_Presence_Object__mdt record, or null. Queried rather than read with getAll(), which cuts long
  // text area values off at 255 characters.
  public virtual Record_Presence_Object__mdt getObjectConfig(
    String objectApiName
  ) {
    List<Record_Presence_Object__mdt> configs = [
      SELECT Object_API_Name__c, Watched_Fields__c, Enabled__c
      FROM Record_Presence_Object__mdt
      WHERE Object_API_Name__c = :objectApiName
      WITH SYSTEM_MODE
      LIMIT 1
    ];
    return configs.isEmpty() ? null : configs[0];
  }

  // API names (lowercase) of the object's fields that have field history tracking turned on
  public virtual Set<String> getHistoryTrackedFields(String objectApiName) {
    Set<String> tracked = new Set<String>();
    for (FieldDefinition field : [
      SELECT QualifiedApiName
      FROM FieldDefinition
      WHERE
        EntityDefinition.QualifiedApiName = :objectApiName
        AND IsFieldHistoryTracked = TRUE
      WITH SYSTEM_MODE
    ]) {
      tracked.add(field.QualifiedApiName.toLowerCase());
    }
    return tracked;
  }
}
