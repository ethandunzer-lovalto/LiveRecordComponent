# Live Record Component

## Overview

**Record Presence** is a Lightning Web Component for record pages. It shows who else is viewing the same record, and when someone else saves the record it interrupts the user with a prompt to refresh, so they don't keep working on an outdated version.

Standard Lightning record pages don't say that anyone else is on the record, and don't warn that it changed until the user tries to save. Salesforce blocks that save, but by then the user may have spent minutes on stale data, or made a call, sent an email or approved something based on what was on screen.

Key features:

- **Presence avatars**: an **Also viewing** card with an avatar stack of the other users on the record in the last minute or so, with their names on hover. Beyond the configured maximum they collapse into `+N`. The card only appears when someone else is there; otherwise the component takes no space.
- **Stale record alert**: within one heartbeat (about 25 seconds) of another user's save, a modal says who changed the record and when. **Refresh now** has focus and reloads the record's data on the page without reloading the browser page. Each change alerts once; a newer change alerts again, and a change that arrives while the modal is open updates it instead of opening a second one.
- **What changed**: when the object has field history tracking, the modal lists the changes, such as `Stage: Proposal → Closed Won`, with the user's locale and time zone, picklist labels and currency formats. Fields the user can't read are left out.
- **Sticky banner**: if the user chooses **Keep working on this version**, an amber banner stays in the component's place until they refresh or the page catches up (for example, after they save).
- **Watched fields** (optional): alert only when chosen fields change, such as `StageName, Amount, OwnerId`.
- **Ignored users**: changes by integration and automation users never alert.
- **Auto-refresh countdown** (optional, off by default): the modal refreshes the record by itself after a few seconds unless the user interacts with it.
- **Admin view**: admins see a status line (storage mode, watched fields, heartbeat interval) with a **Details** popover that flags watched fields changes can't be detected on.

Presence is ephemeral: it lives in Platform Cache, or in a fallback object whose rows are hard-deleted within the hour, and is never kept as a record of who viewed what.

## Installation

The **Live Record Component** unlocked package has no namespace, so the API names are the same as in this repo. It can't be installed into an org that has its own namespace.

Version **1.0.0** is a beta until it's promoted, so for now it can't be installed in production orgs:

- Sandbox: https://test.salesforce.com/packaging/installPackage.apexp?p0=04tbm000000nqzxAAA
- Or with the Salesforce CLI:

  ```sh
  sf package install --package 04tbm000000nqzxAAA --target-org <your org> --wait 20
  ```

Choose **Install for Admins Only**; access for everyone else comes from the permission sets.

After installing:

1. **Allocate Platform Cache.** Setup > Platform Cache > **RecordPresence** > Edit, and give its **Organization** cache at least **1 MB** (Session cache isn't used). Without capacity, presence falls back to the `Presence` object, which works but writes a row per user per record on every heartbeat. Check the allocation again after upgrading the package.
2. **Schedule the purge job** (needed for the fallback object; harmless otherwise). In the Developer Console's Execute Anonymous window, or with the CLI:

   ```sh
   echo "PresencePurgeJob.scheduleHourly();" | sf apex run --target-org <your org>
   ```

   It runs at the start of every hour and hard-deletes presence rows not refreshed for an hour.

3. **Assign the permission sets** described under [Permissions](#permissions).
4. **Optional:** add [Record Presence Object](#watched-fields-and-per-object-settings) records to watch specific fields or turn the component off for an object.
5. **Add the component** to record pages in Lightning App Builder: drag **Record Presence** (Custom section) onto the page, near the top so the avatars and banner are seen, and set its properties.

## Component properties

| Property                         | Default | Description                                                                                                                                                                                                                                                                                                                                            |
| -------------------------------- | ------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Heartbeat Interval (seconds)     | 25      | How often each open record tab checks in, from 15 to 120. Alerts arrive within about one interval of a change. Users drop off the avatars about 60 seconds after their last heartbeat (2.4 heartbeats for intervals above 25).                                                                                                                         |
| Show Viewers                     | On      | Show the avatars of other users on the record. Turn off to use only the alerts.                                                                                                                                                                                                                                                                        |
| Maximum Avatars                  | 4       | Avatars shown before the rest collapse into `+N`.                                                                                                                                                                                                                                                                                                      |
| Alert Style                      | Modal   | `Modal` asks the user to refresh. `Banner only` skips the modal and shows the banner straight away.                                                                                                                                                                                                                                                    |
| Auto-Refresh Countdown (seconds) | 0 (off) | Above 0, the modal refreshes the record by itself after this many seconds unless the user clicks or presses a key in it. **The record reloads even while the user is editing it.** The standard record detail and Edit modal keep unsaved edits, but other components on the page can lose unsaved input; see [Known limitations](#known-limitations). |

The component is for desktop record pages (Lightning Experience). The Salesforce mobile app and Experience Cloud aren't supported yet.

## Permissions

| Permission set                       | Gives                                                                                                                                                                     |
| ------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Record Presence User**             | Access to the `PresenceService` Apex class. Required for everyone who sees the component; without it, the component shows nothing.                                        |
| **Record Presence Admin**            | The admin status line and details (custom permission `Record_Presence_Admin`), plus the access in Record Presence User.                                                   |
| **Record Presence Integration User** | For integration and automation users: their changes never alert anyone (`Record_Presence_Ignore_Changes`), and they're never shown as viewers (`Record_Presence_Hidden`). |

The custom permissions can also be given through permission set groups or profiles. Changes to who has `Record_Presence_Hidden` or `Record_Presence_Ignore_Changes` take up to 10 minutes to apply, since the lists are cached.

Users never get access to the `Presence` object itself: the component's Apex reads and writes it in system mode, and only after checking in user mode that the user can see the record.

## Watched fields and per-object settings

By default, any change by another user alerts on every object the component is placed on. To change that for an object, add a **Record Presence Object** custom metadata record (Setup > Custom Metadata Types > Record Presence Object > Manage Records):

| Field           | Description                                                                                                                                        |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------------------------- |
| Object API Name | The object, for example `Opportunity` or `Project__c`.                                                                                             |
| Watched Fields  | Comma-separated field API names, for example `StageName, Amount, OwnerId`. Only changes to these fields alert. Leave blank to alert on any change. |
| Enabled         | Uncheck to turn the component off on this object's record pages; it then shows nothing and sends no heartbeats.                                    |

Watched fields only work when **field history tracking** is turned on for them (Object Manager > the object > Fields & Relationships > Set History Tracking): changes are found in the object's field history. The admin view's **Details** popover flags watched fields that aren't tracked, and names that aren't fields on the object. If none of the names are valid fields, any change alerts.

Without watched fields, history tracking is still used, when it's on, to show what changed in the modal.

## How it works

- **Heartbeats.** The component calls `PresenceService.heartbeat` when the page opens and then every heartbeat interval, with ±20% jitter so tabs don't all fire at once. Each call records that the user is on the record, returns the other users seen recently, and reports whether someone else changed the record since the version the page shows (its `LastModifiedDate`, from Lightning Data Service). Heartbeats pause while the browser tab is hidden and resume as soon as it's visible again. After an error, the interval doubles (25, 50, 100 seconds, at most 120), and after three errors in a row the avatars are hidden until a heartbeat succeeds; users never see an error, but admins see it in the status line.
- **Change detection.** A change alerts when it's newer than the page's version and wasn't made by the user (in any tab) or by an ignored user. With watched fields, it must also be a change to a watched field, recorded in field history, on a field the user can read. Refreshing reloads the record through Lightning Data Service (`notifyRecordUpdateAvailable`), which moves the page's version forward.
- **Storage.** Presence is kept in the **RecordPresence** Org cache partition, one entry per record holding each user's last-seen time, with a 5-minute time to live. When the partition has no capacity, it's kept in the `Presence` object instead, one row per user per record, and `PresencePurgeJob` hard-deletes rows an hour after their last heartbeat.
- **Leaving.** When a user navigates elsewhere in Lightning, the record page usually stays alive in the background, hidden. The component notices within 2 seconds, stops its heartbeats and removes the user. It also removes them when the component is destroyed, such as when a console subtab is closed (not yet checked in a console app). Closing the browser tab or window gives it no time to tell the server, so the user drops off after the staleness window instead, about 60 seconds. Other viewers see a departure on their own next heartbeat, up to about 30 seconds later.
- **Security.** Every heartbeat first queries the record in user mode. If the user can't see it, the heartbeat returns nothing at all, not even who else is on it, and records nothing. Viewers are listed only if the user can see them under user sharing, and field history values only for fields the user can read.
- **Load.** One Apex call per open record tab per heartbeat: about 2.4 calls a minute at the default interval, fewer while tabs are hidden. Apex calls from Lightning components don't count against the org's API request limits.

## Known limitations

- The component can't tell whether the user is editing the record, so it can't show "Maria is editing", and it can't know whether refreshing would lose unsaved work. That's why refreshing is the user's choice unless the auto-refresh countdown is turned on. What refreshing did to work in progress, checked in Lightning Experience:
  - **Inline edit** on the record detail: unsaved field values are kept, and the fields the user hasn't touched update to the new version.
  - **The standard Edit modal**: the alert opens on top of it, with **Refresh now** focused. Refreshing keeps the Edit modal open with the user's unsaved values, and updates the fields they haven't touched. With **Keep working on this version**, the Edit modal keeps the values it loaded.
  - **Other components** on the page reload their record data too; ones that keep their own unsaved input may lose it.
- Alerts arrive on the next heartbeat, up to about one interval after the change, not instantly.
- Watched fields only work for fields with field history tracking. Without it, only "the record changed" can be detected.
- Without watched fields, only the record's last modifier is checked. If a person changes the record and then an ignored integration user changes it, the person's change doesn't alert. Watching fields with history tracking avoids this.
- Presence only covers users who have the record open, on screen, in a visible browser tab, on a page that includes the component. A user with the record open in two tabs who closes or leaves one may disappear from the avatars until their other tab's next heartbeat.
- A user who closes the browser tab or window stays listed until the staleness window passes: up to about 90 seconds for others, counting their next heartbeat.
- In console apps, each subtab sends its own heartbeats. A user is listed once however many tabs they have open. (Not yet checked in a console app.)

## Development

```sh
npm install
npm run lint                 # ESLint for the components
npm test                     # Jest tests for the components
sf project deploy start --target-org <dev org>
sf apex run test --target-org <dev org> --class-names PresenceServiceTest --class-names PresenceStoreTest --class-names PresenceSelectorTest --class-names PresencePurgeJobTest --code-coverage --wait 20
```

Deploying from source sets the RecordPresence partition's capacity to what its metadata file says, which is 0. Allocate capacity again in Setup to test the cache path.

The Apex tests replace field history, permission assignments and Custom Metadata with canned data through `PresenceSelector`, since field history isn't created in Apex tests, and Platform Cache with an in-memory map through `PresenceCache`.

## Releasing a new package version

The unlocked package, **Live Record Component** (`0Hobm0000007FLhCAM`, no namespace), is owned by the Dev Hub and built from `force-app`.

1. Set `versionNumber` and `versionName` in `sfdx-project.json` to the new version, for example `1.1.0.NEXT` and `1.1.0`.
2. Build the version. This builds the package in a temporary org from `config/project-scratch-def.json`, runs the Apex tests, and adds the new `04t` ID to `packageAliases` in `sfdx-project.json`; commit that change:
   ```sh
   sf package version create --package "Live Record Component" --installation-key-bypass --code-coverage --wait 30 --target-dev-hub <Dev Hub>
   ```
3. The new version is a beta, which only installs in scratch orgs and sandboxes. Install it into a new scratch org, and into one that has the previous released version, to check a fresh install and an upgrade.
4. Promote it, so it can be installed in production orgs:
   ```sh
   sf package version promote --package "Live Record Component@1.1.0-1" --target-dev-hub <Dev Hub>
   ```
5. Update the install command above, and publish a GitHub release with the release notes.
