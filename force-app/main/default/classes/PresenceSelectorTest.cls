@IsTest
private class PresenceSelectorTest {
  @IsTest
  static void resolvesStandardHistoryObjects() {
    PresenceSelector selector = new PresenceSelector();

    assertHistoryObject(
      selector.getHistoryObject(Account.SObjectType),
      'AccountHistory',
      'AccountId'
    );
    assertHistoryObject(
      selector.getHistoryObject(Case.SObjectType),
      'CaseHistory',
      'CaseId'
    );
    assertHistoryObject(
      selector.getHistoryObject(Contact.SObjectType),
      'ContactHistory',
      'ContactId'
    );
    assertHistoryObject(
      selector.getHistoryObject(Lead.SObjectType),
      'LeadHistory',
      'LeadId'
    );
    // OpportunityHistory is a stage snapshot, not field history
    assertHistoryObject(
      selector.getHistoryObject(Opportunity.SObjectType),
      'OpportunityFieldHistory',
      'OpportunityId'
    );
  }

  @IsTest
  static void rejectsHistoryObjectsThatArentFieldHistory() {
    Assert.isNull(
      PresenceSelector.resolveHistoryObject(
        Opportunity.SObjectType,
        new List<String>{ 'OpportunityHistory' }
      )
    );
    Assert.isNull(
      PresenceSelector.resolveHistoryObject(
        Account.SObjectType,
        new List<String>{ 'NoSuchObjectHistory' }
      )
    );
  }

  @IsTest
  static void namesCustomHistoryObjectsAfterTheObject() {
    Assert.areEqual(
      new List<String>{ 'Project__History' },
      PresenceSelector.historyObjectCandidates('Project__c')
    );
    Assert.areEqual(
      new List<String>{ 'ns__Project__History' },
      PresenceSelector.historyObjectCandidates('ns__Project__c')
    );
    Assert.areEqual(
      new List<String>{ 'CaseHistory', 'CaseFieldHistory' },
      PresenceSelector.historyObjectCandidates('Case')
    );
  }

  @IsTest
  static void customObjectsWithoutHistoryTrackingHaveNoHistoryObject() {
    // Presence__c never has history tracking turned on
    Assert.isNull(
      new PresenceSelector().getHistoryObject(Presence__c.SObjectType)
    );
  }

  @IsTest
  static void queriesHistoryForTheRecord() {
    Account acct = new Account(Name = 'History');
    insert acct;
    PresenceSelector selector = new PresenceSelector();
    PresenceSelector.HistoryObject history = selector.getHistoryObject(
      Account.SObjectType
    );
    Datetime since = Datetime.now().addHours(-1);

    // History rows aren't created in Apex tests; this checks the queries are valid
    Assert.areEqual(
      0,
      selector.getHistory(history, acct.Id, since, null).size()
    );
    Assert.areEqual(
      0,
      selector.getHistory(
          history,
          acct.Id,
          since,
          new Set<String>{ 'industry', 'owner' }
        )
        .size()
    );
  }

  @IsTest
  static void findsUsersWithACustomPermission() {
    User direct = newUser('direct');
    User throughGroup = newUser('group');
    User without = newUser('without');
    System.runAs(new User(Id = UserInfo.getUserId())) {
      insert new List<User>{ direct, throughGroup, without };
      PermissionSet integration = [
        SELECT Id
        FROM PermissionSet
        WHERE Name = 'Record_Presence_Integration_User'
      ];
      insert new PermissionSetAssignment(
        AssigneeId = direct.Id,
        PermissionSetId = integration.Id
      );

      PermissionSetGroup permissionGroup = new PermissionSetGroup(
        DeveloperName = 'Presence_Test_Group',
        MasterLabel = 'Presence Test Group'
      );
      insert permissionGroup;
      insert new PermissionSetGroupComponent(
        PermissionSetGroupId = permissionGroup.Id,
        PermissionSetId = integration.Id
      );
      Test.calculatePermissionSetGroup(permissionGroup.Id);
      insert new PermissionSetAssignment(
        AssigneeId = throughGroup.Id,
        PermissionSetGroupId = permissionGroup.Id
      );
    }
    PresenceSelector selector = new PresenceSelector();

    Set<Id> ignored = selector.getUserIdsWithPermission(
      'Record_Presence_Ignore_Changes'
    );
    Set<Id> hidden = selector.getUserIdsWithPermission(
      'Record_Presence_Hidden'
    );

    Assert.isTrue(ignored.contains(direct.Id));
    Assert.isTrue(
      ignored.contains(throughGroup.Id),
      'Assigned through a permission set group'
    );
    Assert.isFalse(ignored.contains(without.Id));
    Assert.isTrue(hidden.contains(direct.Id));
    Assert.isFalse(
      selector.getUserIdsWithPermission('Record_Presence_Admin')
        .contains(direct.Id)
    );
    Assert.areEqual(
      0,
      selector.getUserIdsWithPermission('No_Such_Permission').size()
    );
  }

  @IsTest
  static void returnsNoSettingsForUnconfiguredObjects() {
    Assert.isNull(new PresenceSelector().getObjectConfig('No_Such_Object__c'));
  }

  @IsTest
  static void listsHistoryTrackedFields() {
    Set<String> tracked = new PresenceSelector()
      .getHistoryTrackedFields('Account');

    for (String fieldName : tracked) {
      Assert.areEqual(fieldName.toLowerCase(), fieldName);
    }
    Assert.areEqual(
      0,
      new PresenceSelector().getHistoryTrackedFields('Presence__c').size()
    );
  }

  private static void assertHistoryObject(
    PresenceSelector.HistoryObject history,
    String name,
    String parentField
  ) {
    Assert.isNotNull(history, name + ' not found');
    Assert.areEqual(name, history.name);
    Assert.areEqual(parentField, history.parentField);
    Assert.isTrue(history.hasDataType);
  }

  private static User newUser(String alias) {
    String unique =
      alias + String.valueOf(Crypto.getRandomInteger()).remove('-');
    return new User(
      Alias = alias.left(8),
      Email = unique + '@example.com',
      EmailEncodingKey = 'UTF-8',
      LastName = 'Presence ' + alias,
      LanguageLocaleKey = 'en_US',
      LocaleSidKey = 'en_US',
      ProfileId = [SELECT Id FROM Profile WHERE Name = 'Standard User']
      .Id,
      TimeZoneSidKey = 'America/Los_Angeles',
      Username = unique + '@presence.test'
    );
  }
}
